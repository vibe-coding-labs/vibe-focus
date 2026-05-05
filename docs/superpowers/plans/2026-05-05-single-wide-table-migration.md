# 单宽表迁移：合并 session_bindings + window_states → windows

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 将 SQLite 中两张独立表（`session_bindings` + `window_states`）合并为一张以 `(pid, tty)` 为主键的宽表 `windows`，消除跨表关联失败导致的 UserPromptSubmit 恢复窗口失败问题。

**Architecture:** 每个终端窗口对应一行记录，由 `(pid, tty)` 唯一标识。SessionStart 写入/更新行（窗口身份 + session 信息）；toggle/hook 移动窗口时更新同一行的 toggle state 字段（原始位置、目标位置等）；UserPromptSubmit 直接通过 binding 的 `(pid, tty)` 在同一行找到 toggle state，无需跨表查找。

**Tech Stack:** Swift 5.9, macOS 13+, SQLite (via Csqlite3)

**Risks:**
- TTY 可能为空（非终端窗口）→ 缓解：TTY 允许 NULL，非终端窗口使用 `(pid, "__none__")` 作为伪主键
- 旧表数据迁移失败 → 缓解：创建新表后不删除旧表，旧表数据在 next reboot 后自动过期
- 改动文件多（8 个文件）→ 缓解：按依赖顺序逐个修改，每步编译验证
- SessionWindowBinding / SavedWindowState 结构体变化影响面大 → 缓解：用新的 `WindowState` 统一结构体替代，旧结构体保留用于过渡期内存使用

---

## 变更总览

| 文件 | 变更类型 | 核心改动 |
|------|---------|---------|
| `Sources/WindowStateStore.swift` | **重写** | 新建 `windows` 表 + 所有 CRUD 方法 |
| `Sources/ClaudeHookModels.swift` | **修改** | 新增 `WindowState` 统一结构体 |
| `Sources/SessionWindowRegistry.swift` | **重写** | 改为调用 `WindowStateStore` 的新方法 |
| `Sources/HookEventHandler.swift` | **重写查找逻辑** | 用 `(pid, tty)` 直接查行，删除 6 级 fallback |
| `Sources/WindowManager+State.swift` | **修改** | `saveWindowState` / `hydrateMemory` 适配新结构 |
| `Sources/WindowManager+MoveWindow.swift` | **修改** | `moveWindowToMainScreen` 写入同一行 |
| `Sources/WindowManager.swift` | **修改** | `shouldRestoreCurrentWindow` / `isSavedStateCorrupted` 适配 |
| `Sources/ClaudeHookServer.swift` | **无改动** | 路由层不变 |

---

### Task 1: 新增 WindowState 统一结构体

**Depends on:** None
**Files:**
- Modify: `Sources/ClaudeHookModels.swift:15-38`（在 SessionWindowBinding 之后添加新结构体）

- [ ] **Step 1: 在 ClaudeHookModels.swift 中添加 WindowState 结构体 — 统一 binding + saved state**

文件: `Sources/ClaudeHookModels.swift:38`（在 `SessionWindowBinding` 之后、`TerminalContext` 之前插入）

```swift
/// 统一的窗口状态记录 — 对应 SQLite `windows` 表的一行
/// 合并了原来的 SessionWindowBinding + SavedWindowState
struct WindowState: Codable, Equatable {
    // MARK: - Primary Key
    let pid: Int32
    let tty: String?              // 终端 TTY 路径 (如 /dev/ttys003)，非终端窗口为 nil

    // MARK: - Window Identity
    var windowID: UInt32?         // CGWindowNumber
    var axWindowNumber: Int?
    var appName: String?
    var bundleIdentifier: String?
    var title: String?

    // MARK: - Terminal Context
    var termSessionID: String?
    var itermSessionID: String?
    var kittyWindowID: String?
    var weztermPane: String?
    var envWindowID: String?

    // MARK: - Claude Session
    var sessionID: String?
    var cwd: String?
    var model: String?

    // MARK: - Toggle State (窗口位置信息)
    var origX: CGFloat?
    var origY: CGFloat?
    var origW: CGFloat?
    var origH: CGFloat?
    var targetX: CGFloat?
    var targetY: CGFloat?
    var targetW: CGFloat?
    var targetH: CGFloat?
    var sourceSpace: Int?
    var sourceDisplay: Int?
    var sourceYabaiDisp: Int?
    var sourceDispSpace: Int?
    var targetDisplay: Int?
    var toggleReason: String?
    var toggledAt: Date?

    // MARK: - Lifecycle
    var isCompleted: Bool
    var completedAt: Date?
    let createdAt: Date
    var updatedAt: Date

    /// toggle state 是否已填充（有 origX 且有 targetX 表示曾被 toggle 保存过）
    var hasToggleState: Bool {
        origX != nil && targetX != nil
    }

    /// 获取原始 frame
    var originalFrame: CGRect? {
        guard let x = origX, let y = origY, let w = origW, let h = origH else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// 获取目标 frame
    var targetFrame: CGRect? {
        guard let x = targetX, let y = targetY, let w = targetW, let h = targetH else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// 是否被污染（originalFrame 和 targetFrame 都在主屏幕上）
    func isCorrupted(mainScreenFrame: CGRect) -> Bool {
        guard let orig = originalFrame, let tgt = targetFrame else { return false }
        let origCenter = CGPoint(x: orig.midX, y: orig.midY)
        let tgtCenter = CGPoint(x: tgt.midX, y: tgt.midY)
        return mainScreenFrame.contains(origCenter) && mainScreenFrame.contains(tgtCenter)
    }

    /// 兼容 WindowManager.WindowToken 的构造
    var windowToken: WindowManager.WindowToken? {
        guard let wid = windowID else { return nil }
        return WindowManager.WindowToken(
            stateID: "\(pid)_\(tty ?? "none")",
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            windowID: wid,
            windowNumber: axWindowNumber,
            title: title
        )
    }
}
```

- [ ] **Step 2: 编译验证（预期有未使用警告但无 error）**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | grep -E "error:|Build complete"`
Expected:
  - Output does NOT contain: "error:"
  - Output contains: "Build complete"

---

### Task 2: 重写 WindowStateStore — 新建 windows 表 + CRUD

**Depends on:** Task 1
**Files:**
- Modify: `Sources/WindowStateStore.swift`（重写 createTables + 新增 windows 表方法，保留旧表方法不动）

- [ ] **Step 1: 在 WindowStateStore.createTables() 中添加 windows 表的创建语句**

文件: `Sources/WindowStateStore.swift:49-75`（在 `createTables()` 方法末尾，`log("[WindowStateStore] tables created/verified")` 之前添加）

```swift
        // 新宽表：合并 session_bindings + window_states
        runSchema("""
            CREATE TABLE IF NOT EXISTS windows (
                pid INTEGER NOT NULL,
                tty TEXT NOT NULL DEFAULT '',
                window_id INTEGER,
                ax_window_number INTEGER,
                app_name TEXT,
                bundle_id TEXT,
                title TEXT,
                term_session_id TEXT,
                iterm_session_id TEXT,
                kitty_window_id TEXT,
                wezterm_pane TEXT,
                env_window_id TEXT,
                session_id TEXT,
                cwd TEXT,
                model TEXT,
                orig_x REAL, orig_y REAL, orig_w REAL, orig_h REAL,
                target_x REAL, target_y REAL, target_w REAL, target_h REAL,
                source_space INTEGER,
                source_display INTEGER,
                source_yabai_disp INTEGER,
                source_disp_space INTEGER,
                target_display INTEGER,
                toggle_reason TEXT,
                toggled_at REAL,
                is_completed INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (pid, tty)
            );
            """)
        runSchema("CREATE INDEX IF NOT EXISTS idx_windows_session_id ON windows(session_id);")
        runSchema("CREATE INDEX IF NOT EXISTS idx_windows_window_id ON windows(window_id);")
        runSchema("CREATE INDEX IF NOT EXISTS idx_windows_last_seen ON windows(updated_at);")
```

- [ ] **Step 2: 在 WindowStateStore 中添加 windows 表的 CRUD 方法**

文件: `Sources/WindowStateStore.swift`（在 `bindingsCount` 属性之后、文件末尾之前添加）

```swift
    // MARK: - Windows (New Unified Table)

    /// 保存或更新窗口状态（INSERT OR REPLACE by pid+tty）
    func saveWindowState(_ state: WindowState) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = """
            INSERT OR REPLACE INTO windows (
                pid, tty, window_id, ax_window_number, app_name, bundle_id, title,
                term_session_id, iterm_session_id, kitty_window_id, wezterm_pane, env_window_id,
                session_id, cwd, model,
                orig_x, orig_y, orig_w, orig_h,
                target_x, target_y, target_w, target_h,
                source_space, source_display, source_yabai_disp, source_disp_space,
                target_display, toggle_reason, toggled_at,
                is_completed, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, state.pid)
        sqlite3_bind_text(stmt, 2, state.tty ?? "", -1, SQLITE_TRANSIENT)
        if let v = state.windowID { sqlite3_bind_int64(stmt, 3, Int64(v)) } else { sqlite3_bind_null(stmt, 3) }
        if let v = state.axWindowNumber { sqlite3_bind_int(stmt, 4, Int32(v)) } else { sqlite3_bind_null(stmt, 4) }
        sqlite3_bind_text(stmt, 5, state.appName ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, state.bundleIdentifier ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 7, state.title ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 8, state.termSessionID ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 9, state.itermSessionID ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 10, state.kittyWindowID ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 11, state.weztermPane ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 12, state.envWindowID ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 13, state.sessionID ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 14, state.cwd ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 15, state.model ?? "", -1, SQLITE_TRANSIENT)
        if let v = state.origX { sqlite3_bind_double(stmt, 16, Double(v)) } else { sqlite3_bind_null(stmt, 16) }
        if let v = state.origY { sqlite3_bind_double(stmt, 17, Double(v)) } else { sqlite3_bind_null(stmt, 17) }
        if let v = state.origW { sqlite3_bind_double(stmt, 18, Double(v)) } else { sqlite3_bind_null(stmt, 18) }
        if let v = state.origH { sqlite3_bind_double(stmt, 19, Double(v)) } else { sqlite3_bind_null(stmt, 19) }
        if let v = state.targetX { sqlite3_bind_double(stmt, 20, Double(v)) } else { sqlite3_bind_null(stmt, 20) }
        if let v = state.targetY { sqlite3_bind_double(stmt, 21, Double(v)) } else { sqlite3_bind_null(stmt, 21) }
        if let v = state.targetW { sqlite3_bind_double(stmt, 22, Double(v)) } else { sqlite3_bind_null(stmt, 22) }
        if let v = state.targetH { sqlite3_bind_double(stmt, 23, Double(v)) } else { sqlite3_bind_null(stmt, 23) }
        if let v = state.sourceSpace { sqlite3_bind_int(stmt, 24, Int32(v)) } else { sqlite3_bind_null(stmt, 24) }
        if let v = state.sourceDisplay { sqlite3_bind_int(stmt, 25, Int32(v)) } else { sqlite3_bind_null(stmt, 25) }
        if let v = state.sourceYabaiDisp { sqlite3_bind_int(stmt, 26, Int32(v)) } else { sqlite3_bind_null(stmt, 26) }
        if let v = state.sourceDispSpace { sqlite3_bind_int(stmt, 27, Int32(v)) } else { sqlite3_bind_null(stmt, 27) }
        if let v = state.targetDisplay { sqlite3_bind_int(stmt, 28, Int32(v)) } else { sqlite3_bind_null(stmt, 28) }
        sqlite3_bind_text(stmt, 29, state.toggleReason ?? "", -1, SQLITE_TRANSIENT)
        if let v = state.toggledAt { sqlite3_bind_double(stmt, 30, v.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 30) }
        sqlite3_bind_int(stmt, 31, state.isCompleted ? 1 : 0)
        sqlite3_bind_double(stmt, 32, state.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 33, state.updatedAt.timeIntervalSince1970)

        if sqlite3_step(stmt) != SQLITE_DONE {
            log("[WindowStateStore] saveWindowState (windows table) failed", level: .error)
        }
    }

    /// 按 (pid, tty) 查找窗口状态
    func findWindowState(pid: Int32, tty: String?) -> WindowState? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let ttyValue = tty ?? ""
        let sql = "SELECT * FROM windows WHERE pid = ? AND tty = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, pid)
        sqlite3_bind_text(stmt, 2, ttyValue, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return parseWindowStateRow(stmt)
    }

    /// 按 sessionID 查找窗口状态（用于 hook 事件路由）
    func findWindowStateBySession(sessionID: String) -> WindowState? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let sql = "SELECT * FROM windows WHERE session_id = ? ORDER BY updated_at DESC LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionID, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return parseWindowStateRow(stmt)
    }

    /// 按 windowID 查找窗口状态（用于 toggle 判断）
    func findWindowStateByWindowID(_ windowID: UInt32) -> WindowState? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let sql = "SELECT * FROM windows WHERE window_id = ? ORDER BY updated_at DESC LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(windowID))

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return parseWindowStateRow(stmt)
    }

    /// 清除指定窗口的 toggle state（将位置字段置 NULL）
    func clearToggleState(pid: Int32, tty: String?) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = """
            UPDATE windows SET
                orig_x = NULL, orig_y = NULL, orig_w = NULL, orig_h = NULL,
                target_x = NULL, target_y = NULL, target_w = NULL, target_h = NULL,
                source_space = NULL, source_display = NULL, source_yabai_disp = NULL,
                source_disp_space = NULL, target_display = NULL,
                toggle_reason = NULL, toggled_at = NULL,
                updated_at = ?
            WHERE pid = ? AND tty = ?;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_int(stmt, 2, pid)
        sqlite3_bind_text(stmt, 3, tty ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    /// 清除所有窗口状态（调试用）
    func deleteAllWindowsStates() {
        guard let db else { return }
        runSchema("DELETE FROM windows;")
    }

    /// 清理过期记录
    func pruneExpiredWindowStates(activeRetention: TimeInterval, completedRetention: TimeInterval) -> Int {
        guard let db else { return 0 }
        let now = Date().timeIntervalSince1970
        let activeCutoff = now - activeRetention
        let completedCutoff = now - completedRetention

        let sql = """
            DELETE FROM windows
            WHERE (is_completed = 0 AND updated_at < ?)
               OR (is_completed = 1 AND updated_at < ?);
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, activeCutoff)
        sqlite3_bind_double(stmt, 2, completedCutoff)
        sqlite3_step(stmt)
        return Int(sqlite3_changes(db))
    }

    /// 加载所有窗口状态（用于启动时恢复内存）
    func loadAllWindowStates() -> [WindowState] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        let sql = "SELECT * FROM windows ORDER BY updated_at ASC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [WindowState] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let state = parseWindowStateRow(stmt) {
                results.append(state)
            }
        }
        return results
    }

    /// 删除指定行
    func deleteWindowState(pid: Int32, tty: String?) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = "DELETE FROM windows WHERE pid = ? AND tty = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, pid)
        sqlite3_bind_text(stmt, 2, tty ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    /// windows 表记录数
    var windowStatesCount: Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM windows;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - Row Parser

    private func parseWindowStateRow(_ stmt: OpaquePointer) -> WindowState? {
        let pid = sqlite3_column_int(stmt, 0)
        let tty = String(cString: sqlite3_column_text(stmt, 1))
        let windowID: UInt32? = sqlite3_column_type(stmt, 2) != SQLITE_NULL ? UInt32(sqlite3_column_int64(stmt, 2)) : nil
        let axWindowNumber: Int? = sqlite3_column_type(stmt, 3) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 3)) : nil
        let appName = optionalString(stmt, col: 4)
        let bundleID = optionalString(stmt, col: 5)
        let title = optionalString(stmt, col: 6)
        let termSessionID = optionalString(stmt, col: 7)
        let itermSessionID = optionalString(stmt, col: 8)
        let kittyWindowID = optionalString(stmt, col: 9)
        let weztermPane = optionalString(stmt, col: 10)
        let envWindowID = optionalString(stmt, col: 11)
        let sessionID = optionalString(stmt, col: 12)
        let cwd = optionalString(stmt, col: 13)
        let model = optionalString(stmt, col: 14)

        let origX: CGFloat? = sqlite3_column_type(stmt, 15) != SQLITE_NULL ? CGFloat(sqlite3_column_double(stmt, 15)) : nil
        let origY: CGFloat? = sqlite3_column_type(stmt, 16) != SQLITE_NULL ? CGFloat(sqlite3_column_double(stmt, 16)) : nil
        let origW: CGFloat? = sqlite3_column_type(stmt, 17) != SQLITE_NULL ? CGFloat(sqlite3_column_double(stmt, 17)) : nil
        let origH: CGFloat? = sqlite3_column_type(stmt, 18) != SQLITE_NULL ? CGFloat(sqlite3_column_double(stmt, 18)) : nil
        let targetX: CGFloat? = sqlite3_column_type(stmt, 19) != SQLITE_NULL ? CGFloat(sqlite3_column_double(stmt, 19)) : nil
        let targetY: CGFloat? = sqlite3_column_type(stmt, 20) != SQLITE_NULL ? CGFloat(sqlite3_column_double(stmt, 20)) : nil
        let targetW: CGFloat? = sqlite3_column_type(stmt, 21) != SQLITE_NULL ? CGFloat(sqlite3_column_double(stmt, 21)) : nil
        let targetH: CGFloat? = sqlite3_column_type(stmt, 22) != SQLITE_NULL ? CGFloat(sqlite3_column_double(stmt, 22)) : nil
        let sourceSpace: Int? = sqlite3_column_type(stmt, 23) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 23)) : nil
        let sourceDisplay: Int? = sqlite3_column_type(stmt, 24) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 24)) : nil
        let sourceYabaiDisp: Int? = sqlite3_column_type(stmt, 25) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 25)) : nil
        let sourceDispSpace: Int? = sqlite3_column_type(stmt, 26) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 26)) : nil
        let targetDisplay: Int? = sqlite3_column_type(stmt, 27) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 27)) : nil
        let toggleReason = optionalString(stmt, col: 28)
        let toggledAt: Date? = sqlite3_column_type(stmt, 29) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 29)) : nil

        let isCompleted = sqlite3_column_int(stmt, 30) != 0
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 31))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 32))

        return WindowState(
            pid: pid,
            tty: tty.isEmpty ? nil : tty,
            windowID: windowID,
            axWindowNumber: axWindowNumber,
            appName: appName,
            bundleIdentifier: bundleID,
            title: title,
            termSessionID: termSessionID,
            itermSessionID: itermSessionID,
            kittyWindowID: kittyWindowID,
            weztermPane: weztermPane,
            envWindowID: envWindowID,
            sessionID: sessionID,
            cwd: cwd,
            model: model,
            origX: origX, origY: origY, origW: origW, origH: origH,
            targetX: targetX, targetY: targetY, targetW: targetW, targetH: targetH,
            sourceSpace: sourceSpace,
            sourceDisplay: sourceDisplay,
            sourceYabaiDisp: sourceYabaiDisp,
            sourceDispSpace: sourceDispSpace,
            targetDisplay: targetDisplay,
            toggleReason: toggleReason,
            toggledAt: toggledAt,
            isCompleted: isCompleted,
            completedAt: nil,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// 读取可能为空的 TEXT 列
    private func optionalString(_ stmt: OpaquePointer, col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        let raw = String(cString: sqlite3_column_text(stmt, col))
        return raw.isEmpty ? nil : raw
    }
```

- [ ] **Step 3: 编译验证**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | grep -E "error:|Build complete"`
Expected:
  - Output does NOT contain: "error:"
  - Output contains: "Build complete"

---

### Task 3: 重写 SessionWindowRegistry — 改用 windows 表

**Depends on:** Task 2
**Files:**
- Modify: `Sources/SessionWindowRegistry.swift`（重写核心方法，改用 `WindowStateStore` 的新 `windows` 表方法）

- [ ] **Step 1: 重写 SessionWindowRegistry 的核心方法**

文件: `Sources/SessionWindowRegistry.swift`（整体重写，替换整个类体）

关键改动：
- `bindings: [String: SessionWindowBinding]` → `windowStates: [String: WindowState]`（key = `"\(pid)_\(tty ?? "")"`）
- `bind()` → 创建/更新 `WindowState` 行（仅写 binding 字段，不写 toggle state）
- `binding(for:)` → `windowState(forSession:)` 查找
- `verifyBinding()` → `verifyWindowState()` 逻辑相同，但从 `WindowState` 读数据
- `markCompleted()` → 更新 `isCompleted` 字段
- `reactivate()` → 重置 `isCompleted = false`
- `persistBindings()` → 改用 `WindowStateStore.shared.saveWindowState()`

```swift
import Foundation
import Cocoa

@MainActor
final class SessionWindowRegistry: ObservableObject {
    static let shared = SessionWindowRegistry()

    @Published private(set) var lastEventDescription: String = "尚未收到 Claude Hook 事件"

    /// 内存缓存：key = "\(pid)_\(tty ?? "")"，value = WindowState
    private(set) var windowStates: [String: WindowState] = [:]

    var activeBindingCount: Int {
        windowStates.values.filter { !$0.isCompleted }.count
    }

    var completedBindingCount: Int {
        windowStates.values.filter(\.isCompleted).count
    }

    private let completedRetention: TimeInterval = 4 * 60 * 60
    private let activeRetention: TimeInterval = 24 * 60 * 60

    private init() {
        let loaded = WindowStateStore.shared.loadAllWindowStates()
        for state in loaded {
            let key = cacheKey(pid: state.pid, tty: state.tty)
            windowStates[key] = state
        }
        log("SessionWindowRegistry.init loaded \(loaded.count) window states from SQLite")
        pruneExpiredBindings(shouldPersist: false)
    }

    /// 绑定 session 到窗口 — 创建或更新 WindowState 行
    func bind(sessionID: String, windowIdentity: WindowIdentity, terminalTTY: String? = nil, terminalSessionID: String? = nil) {
        let now = Date()
        let key = cacheKey(pid: windowIdentity.pid, tty: terminalTTY)

        if var existing = windowStates[key] {
            // 更新已有行：窗口身份 + session 信息
            existing.windowID = windowIdentity.windowID
            existing.axWindowNumber = windowIdentity.windowNumber
            existing.appName = windowIdentity.appName
            existing.bundleIdentifier = windowIdentity.bundleIdentifier
            existing.title = windowIdentity.title
            existing.sessionID = sessionID
            existing.isCompleted = false
            existing.completedAt = nil
            existing.updatedAt = now
            existing.tty = terminalTTY
            existing.termSessionID = terminalSessionID
            windowStates[key] = existing
        } else {
            // 新建行
            windowStates[key] = WindowState(
                pid: windowIdentity.pid,
                tty: terminalTTY,
                windowID: windowIdentity.windowID,
                axWindowNumber: windowIdentity.windowNumber,
                appName: windowIdentity.appName,
                bundleIdentifier: windowIdentity.bundleIdentifier,
                title: windowIdentity.title,
                termSessionID: terminalSessionID,
                sessionID: sessionID,
                isCompleted: false,
                createdAt: now,
                updatedAt: now
            )
        }

        lastEventDescription = "SessionStart 绑定窗口：\(windowIdentity.appName ?? "Unknown") / \(windowIdentity.title ?? "Untitled")"
        pruneExpiredBindings(shouldPersist: false)
        persistToDB(key: key)
    }

    /// 按 sessionID 查找窗口状态
    func binding(for sessionID: String) -> WindowState? {
        // 先查内存
        if let state = windowStates.values.first(where: { $0.sessionID == sessionID }) {
            return state
        }
        // 再查 SQLite（可能其他进程写入了新行）
        if let state = WindowStateStore.shared.findWindowStateBySession(sessionID: sessionID) {
            let key = cacheKey(pid: state.pid, tty: state.tty)
            windowStates[key] = state
            return state
        }
        return nil
    }

    /// 验证窗口状态是否仍然有效
    func verifyBinding(_ state: WindowState) -> Bool {
        guard let windowID = state.windowID else { return false }
        let expectedPID = state.pid

        // 检查 PID 是否仍然存在
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: state.bundleIdentifier ?? "")
        let pidMatches = runningApps.contains { $0.processIdentifier == expectedPID }
        if !pidMatches {
            let pidExists = kill(expectedPID, 0) == 0
            if !pidExists { return false }
        }

        // 检查 windowID 对应的窗口 PID 是否匹配
        let options: CGWindowListOption = [.optionAll]
        if let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
            if let matchedWindow = windowList.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == windowID }) {
                let actualPID = matchedWindow[kCGWindowOwnerPID as String] as? Int32
                return actualPID == expectedPID
            } else {
                return false
            }
        }
        return false
    }

    /// 标记会话完成
    func markCompleted(sessionID: String) {
        guard let state = binding(for: sessionID) else { return }
        let key = cacheKey(pid: state.pid, tty: state.tty)
        guard var updated = windowStates[key] else { return }
        updated.isCompleted = true
        updated.completedAt = Date()
        updated.updatedAt = Date()
        windowStates[key] = updated
        lastEventDescription = "SessionEnd 已完成：\(updated.appName ?? "Unknown")"
        persistToDB(key: key)
    }

    /// 重新激活已完成的绑定
    func reactivate(sessionID: String) {
        guard let state = binding(for: sessionID) else { return }
        let key = cacheKey(pid: state.pid, tty: state.tty)
        guard var updated = windowStates[key] else { return }
        updated.isCompleted = false
        updated.completedAt = nil
        updated.updatedAt = Date()
        windowStates[key] = updated
        persistToDB(key: key)
    }

    /// 更新最后活跃时间
    func touch(sessionID: String, message: String? = nil) {
        guard let state = binding(for: sessionID) else { return }
        let key = cacheKey(pid: state.pid, tty: state.tty)
        guard var updated = windowStates[key] else { return }
        updated.updatedAt = Date()
        windowStates[key] = updated
        persistToDB(key: key)
        if let message, !message.isEmpty {
            lastEventDescription = message
        }
    }

    func setLastEventDescription(_ message: String) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lastEventDescription = message
    }

    /// 更新指定窗口的 toggle state（由 WindowManager 调用）
    func updateToggleState(pid: Int32, tty: String?, toggleUpdater: (inout WindowState) -> Void) {
        let key = cacheKey(pid: pid, tty: tty)
        if var state = windowStates[key] {
            toggleUpdater(&state)
            state.updatedAt = Date()
            windowStates[key] = state
            persistToDB(key: key)
        } else {
            // 窗口没有 binding 记录（纯 toggle 场景），创建新行
            var state = WindowState(
                pid: pid, tty: tty,
                isCompleted: false,
                createdAt: Date(), updatedAt: Date()
            )
            toggleUpdater(&state)
            windowStates[key] = state
            persistToDB(key: key)
        }
    }

    /// 按 pid+tty 查找窗口状态
    func findState(pid: Int32, tty: String?) -> WindowState? {
        let key = cacheKey(pid: pid, tty: tty)
        if let state = windowStates[key] { return state }
        // fallback to SQLite
        if let state = WindowStateStore.shared.findWindowState(pid: pid, tty: tty) {
            windowStates[key] = state
            return state
        }
        return nil
    }

    /// 按 windowID 查找窗口状态
    func findStateByWindowID(_ windowID: UInt32) -> WindowState? {
        if let state = windowStates.values.first(where: { $0.windowID == windowID }) {
            return state
        }
        if let state = WindowStateStore.shared.findWindowStateByWindowID(windowID) {
            let key = cacheKey(pid: state.pid, tty: state.tty)
            windowStates[key] = state
            return state
        }
        return nil
    }

    /// 清除指定窗口的 toggle state
    func clearToggleState(pid: Int32, tty: String?) {
        let key = cacheKey(pid: pid, tty: tty)
        if var state = windowStates[key] {
            state.origX = nil; state.origY = nil; state.origW = nil; state.origH = nil
            state.targetX = nil; state.targetY = nil; state.targetW = nil; state.targetH = nil
            state.sourceSpace = nil; state.sourceDisplay = nil; state.sourceYabaiDisp = nil
            state.sourceDispSpace = nil; state.targetDisplay = nil
            state.toggleReason = nil; state.toggledAt = nil
            state.updatedAt = Date()
            windowStates[key] = state
            persistToDB(key: key)
        }
        WindowStateStore.shared.clearToggleState(pid: pid, tty: tty)
    }

    /// 清除所有绑定（调试用）
    func clearAllBindings() {
        windowStates.removeAll()
        lastEventDescription = "所有绑定已清除"
        WindowStateStore.shared.deleteAllWindowsStates()
    }

    // MARK: - UI Support

    var activeBindingsForUI: [WindowState] {
        windowStates.values
            .filter { !$0.isCompleted }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var recentCompletedBindings: [WindowState] {
        let now = Date()
        return windowStates.values
            .filter { $0.isCompleted && $0.updatedAt.addingTimeInterval(30 * 60) > now }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Private

    private func cacheKey(pid: Int32, tty: String?) -> String {
        "\(pid)_\(tty ?? "")"
    }

    private func pruneExpiredBindings(shouldPersist: Bool = true) {
        let removed = WindowStateStore.shared.pruneExpiredWindowStates(
            activeRetention: activeRetention,
            completedRetention: completedRetention
        )
        if removed > 0 {
            let now = Date()
            windowStates = windowStates.filter { _, state in
                let deadline = state.updatedAt.addingTimeInterval(
                    state.isCompleted ? completedRetention : activeRetention
                )
                return deadline > now
            }
        }
    }

    private func persistToDB(key: String) {
        guard let state = windowStates[key] else { return }
        WindowStateStore.shared.saveWindowState(state)
    }
}
```

- [ ] **Step 2: 编译验证（预期有类型不匹配错误，后续 Task 修复）**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | grep "error:" | head -20`
Expected:
  - 错误都集中在 `HookEventHandler.swift` 和 `WindowManager*.swift` 中使用旧 `SessionWindowBinding` / `SavedWindowState` 类型的地方

---

### Task 4: 重写 HookEventHandler — 用 WindowState 替代旧类型

**Depends on:** Task 3
**Files:**
- Modify: `Sources/HookEventHandler.swift`（替换所有 `SessionWindowBinding` → `WindowState` 引用，删除 6 级 fallback）

- [ ] **Step 1: 修改 handleSessionStart — 绑定参数不变，类型自动适配**

文件: `Sources/HookEventHandler.swift:79-84`

`SessionWindowRegistry.shared.bind()` 的调用签名不变（接受 `sessionID`、`windowIdentity`、`terminalTTY`、`terminalSessionID`），此函数无需改动。但需要确认编译通过。

- [ ] **Step 2: 重写 handleUserPromptSubmit — 用 (pid, tty) 直接查行替代 6 级 fallback**

文件: `Sources/HookEventHandler.swift:126-347`（替换从 `let binding = ...` 到函数末尾）

核心改动：不再需要 6 级 fallback，直接从 binding 获取 `(pid, tty)`，用它在同一行查到 toggle state。

```swift
        // 通过 sessionID 找到窗口状态
        let state = SessionWindowRegistry.shared.binding(for: payload.sessionID)
        let identity: WindowIdentity?

        if let state {
            guard SessionWindowRegistry.shared.verifyBinding(state) else {
                log(
                    "[HookEventHandler] UserPromptSubmit binding verification failed",
                    level: .warn,
                    fields: [
                        "sessionID": payload.sessionID,
                        "pid": String(state.pid),
                        "tty": state.tty ?? "nil"
                    ]
                )
                return (
                    200,
                    ClaudeHookResponse(
                        ok: true, code: "binding_verification_failed",
                        message: "Binding verification failed, skipping restore",
                        sessionID: payload.sessionID, handled: false
                    )
                )
            }
            identity = WindowIdentity(
                windowID: state.windowID ?? 0,
                pid: state.pid,
                bundleIdentifier: state.bundleIdentifier,
                appName: state.appName,
                windowNumber: state.axWindowNumber,
                title: state.title,
                capturedAt: state.createdAt
            )
        } else if let terminalCtx = payload.terminalCtx, terminalCtx.hasUsefulContext {
            identity = WindowManager.shared.findWindowByTerminalContext(terminalCtx)
            if let identity {
                log(
                    "[HookEventHandler] UserPromptSubmit no binding, resolved via terminal context",
                    fields: [
                        "sessionID": payload.sessionID,
                        "resolvedWindowID": String(identity.windowID),
                        "app": identity.appName ?? "unknown"
                    ]
                )
            }
        } else {
            log(
                "[HookEventHandler] UserPromptSubmit no binding and no terminal context",
                level: .warn,
                fields: ["sessionID": payload.sessionID]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "no_binding_skip",
                    message: "No session binding, skipping restore",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        guard let identity else {
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "no_binding_skip",
                    message: "Could not resolve window identity",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        let wm = WindowManager.shared
        let isOnMain = wm.isWindowOnMainScreen(windowID: identity.windowID)

        guard isOnMain else {
            log(
                "[HookEventHandler] UserPromptSubmit window not on main screen",
                fields: [
                    "sessionID": payload.sessionID,
                    "windowID": String(identity.windowID)
                ]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "no_action_needed",
                    message: "Window not on main screen",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 直接通过 (pid, tty) 在同一行查找 toggle state — 无需跨表匹配
        let tty = state?.tty ?? payload.terminalCtx?.tty
        if let toggleState = SessionWindowRegistry.shared.findState(pid: identity.pid, tty: tty) {
            if toggleState.hasToggleState {
                guard let mainScreen = wm.getMainScreen() else {
                    return (200, ClaudeHookResponse(ok: true, code: "no_main_screen", message: "No main screen", sessionID: payload.sessionID, handled: false))
                }
                if !toggleState.isCorrupted(mainScreenFrame: mainScreen.frame) {
                    return performRestoreFromState(
                        payload: payload, toggleState: toggleState,
                        matchLevel: "pid_tty_direct"
                    )
                } else {
                    SessionWindowRegistry.shared.clearToggleState(pid: identity.pid, tty: tty)
                }
            }
        }

        // Fallback: 按 windowID 查找（toggle 发生在 binding 之前的情况）
        if let windowState = SessionWindowRegistry.shared.findStateByWindowID(identity.windowID) {
            if windowState.hasToggleState {
                guard let mainScreen = wm.getMainScreen() else {
                    return (200, ClaudeHookResponse(ok: true, code: "no_main_screen", message: "No main screen", sessionID: payload.sessionID, handled: false))
                }
                if !windowState.isCorrupted(mainScreenFrame: mainScreen.frame) {
                    return performRestoreFromState(
                        payload: payload, toggleState: windowState,
                        matchLevel: "windowid_fallback"
                    )
                } else {
                    SessionWindowRegistry.shared.clearToggleState(pid: windowState.pid, tty: windowState.tty)
                }
            }
        }

        log(
            "[HookEventHandler] UserPromptSubmit no toggle state found",
            fields: [
                "sessionID": payload.sessionID,
                "pid": String(identity.pid),
                "tty": tty ?? "nil",
                "windowOnMainScreen": String(isOnMain)
            ]
        )
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "no_action_needed",
                message: "No toggle state found for window",
                sessionID: payload.sessionID, handled: false
            )
        )
```

- [ ] **Step 3: 重写 performRestore — 使用 WindowState 替代 SavedWindowState**

文件: `Sources/HookEventHandler.swift:352-390`（替换 performRestore 方法）

```swift
    private func performRestoreFromState(
        payload: ClaudeHookPayload,
        toggleState: WindowState,
        matchLevel: String
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        let wm = WindowManager.shared

        // 从 WindowState 构建 SavedWindowState 用于 hydrateMemory
        guard let origFrame = toggleState.originalFrame,
              let tgtFrame = toggleState.targetFrame else {
            return (200, ClaudeHookResponse(ok: true, code: "no_frame_data", message: "No frame data", sessionID: payload.sessionID, handled: false))
        }

        let savedState = WindowManager.SavedWindowState(
            id: "\(toggleState.pid)_\(toggleState.tty ?? "none")",
            pid: toggleState.pid,
            bundleIdentifier: toggleState.bundleIdentifier,
            appName: toggleState.appName,
            windowID: toggleState.windowID,
            windowNumber: toggleState.axWindowNumber,
            title: toggleState.title,
            originalFrame: WindowManager.RectPayload(origFrame),
            targetFrame: WindowManager.RectPayload(tgtFrame),
            sourceSpaceIndex: toggleState.sourceSpace,
            targetSpaceIndex: nil,
            sourceYabaiDisplayIndex: toggleState.sourceYabaiDisp,
            sourceDisplaySpaceIndex: toggleState.sourceDispSpace,
            sourceDisplayIndex: toggleState.sourceDisplay,
            sourceDisplayID: nil,
            targetDisplayIndex: toggleState.targetDisplay,
            restoreReason: toggleState.toggleReason,
            sessionID: toggleState.sessionID,
            savedAt: toggleState.toggledAt ?? Date()
        )

        wm.hydrateMemory(from: savedState, window: nil)

        log(
            "[HookEventHandler] UserPromptSubmit restoring window",
            fields: [
                "sessionID": payload.sessionID,
                "matchLevel": matchLevel,
                "pid": String(toggleState.pid),
                "tty": toggleState.tty ?? "nil",
                "app": toggleState.appName ?? "unknown",
                "windowID": String(describing: toggleState.windowID),
                "originalFrame": String(describing: origFrame),
                "targetFrame": String(describing: tgtFrame)
            ]
        )

        wm.restore(
            operationID: makeOperationID(prefix: "hook-restore"),
            triggerSource: "user_prompt_submit"
        )

        SessionWindowRegistry.shared.reactivate(sessionID: payload.sessionID)
        SessionWindowRegistry.shared.clearToggleState(pid: toggleState.pid, tty: toggleState.tty)

        SessionWindowRegistry.shared.setLastEventDescription(
            "UserPromptSubmit 恢复窗口（\(matchLevel)）：\(toggleState.appName ?? "Unknown")"
        )
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "window_restored",
                message: "Window restored to original position",
                sessionID: payload.sessionID, handled: true
            )
        )
    }
```

- [ ] **Step 4: 修改 handleWindowMoveTrigger 和 moveBindingToMainScreen — 使用 WindowState**

文件: `Sources/HookEventHandler.swift:479`（将 `SessionWindowBinding` 类型改为 `WindowState`）

关键改动点：
- 第 479 行: `guard let binding = SessionWindowRegistry.shared.binding(...)` → 返回类型已经是 `WindowState?`
- 第 495 行: `SessionWindowRegistry.shared.verifyBinding(binding)` → 参数类型改为 `WindowState`
- 第 535 行: `moveBindingToMainScreen(binding: SessionWindowBinding, ...)` → 改为 `binding: WindowState`
- 第 632-638 行: `moveWindowToMainScreen` 调用后 `markCompleted` — 逻辑不变

- [ ] **Step 5: 编译验证**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | grep "error:" | head -20`
Expected:
  - 错误数量显著减少，主要集中在 WindowManager 相关文件的类型适配

---

### Task 5: 修改 WindowManager+MoveWindow — toggle state 写入同一行

**Depends on:** Task 4
**Files:**
- Modify: `Sources/WindowManager+MoveWindow.swift:360-391`（`moveWindowToMainScreen` 中保存 state 的逻辑）

- [ ] **Step 1: 修改 moveWindowToMainScreen — 保存 toggle state 到 WindowState 行**

文件: `Sources/WindowManager+MoveWindow.swift:360-391`（替换 SavedWindowState 创建和保存逻辑）

核心改动：不再创建独立的 `SavedWindowState`，而是更新 `(pid, tty)` 对应行的 toggle state 字段。

```swift
        // 更新 SessionWindowRegistry 中对应窗口的 toggle state
        SessionWindowRegistry.shared.updateToggleState(
            pid: identity.pid,
            tty: nil  // toggle 场景不一定有 tty，后续通过 pid+windowID 匹配
        ) { state in
            state.windowID = currentWindowID
            state.appName = identity.appName
            state.bundleIdentifier = identity.bundleIdentifier
            state.title = resolvedTitle
            state.axWindowNumber = resolvedWindowNumber
            state.origX = currentFrame.origin.x
            state.origY = currentFrame.origin.y
            state.origW = currentFrame.width
            state.origH = currentFrame.height
            state.targetX = actualTargetFrame.origin.x
            state.targetY = actualTargetFrame.origin.y
            state.targetW = actualTargetFrame.width
            state.targetH = actualTargetFrame.height
            state.sourceSpace = spaceContext.sourceSpaceIndex
            state.sourceDisplay = sourceContext.index
            state.sourceYabaiDisp = spaceContext.sourceDisplayIndex
            state.sourceDispSpace = spaceContext.sourceDisplaySpaceIndex
            state.targetDisplay = targetDisplayIndex
            state.toggleReason = reason.rawValue
            state.toggledAt = Date()
            if let sid = sessionID {
                state.sessionID = sid
            }
        }
```

同时需要保留 `hydrateMemory` 调用，但改用兼容 `SavedWindowState` 的方式：

```swift
        // 构建 SavedWindowState 用于 hydrateMemory（内存数据结构兼容）
        let savedState = SavedWindowState(
            id: UUID().uuidString,
            pid: identity.pid,
            bundleIdentifier: identity.bundleIdentifier,
            appName: identity.appName,
            windowID: currentWindowID,
            windowNumber: resolvedWindowNumber,
            title: resolvedTitle,
            originalFrame: RectPayload(currentFrame),
            targetFrame: RectPayload(actualTargetFrame),
            sourceSpaceIndex: spaceContext.sourceSpaceIndex,
            targetSpaceIndex: spaceContext.targetSpaceIndex,
            sourceYabaiDisplayIndex: spaceContext.sourceDisplayIndex,
            sourceDisplaySpaceIndex: spaceContext.sourceDisplaySpaceIndex,
            sourceDisplayIndex: sourceContext.index,
            sourceDisplayID: sourceContext.displayID,
            targetDisplayIndex: targetDisplayIndex,
            restoreReason: reason.rawValue,
            sessionID: sessionID,
            savedAt: Date()
        )
        windowElementsByStateID[savedState.id] = windowAX
        hydrateMemory(from: savedState, window: windowAX)
```

- [ ] **Step 2: 编译验证**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | grep "error:" | head -20`
Expected:
  - 错误数量继续减少

---

### Task 6: 修改 WindowManager — shouldRestoreCurrentWindow 适配

**Depends on:** Task 5
**Files:**
- Modify: `Sources/WindowManager.swift:801-891`（`shouldRestoreCurrentWindow`）
- Modify: `Sources/WindowManager.swift:897-927`（`isSavedStateCorrupted`）

- [ ] **Step 1: 修改 shouldRestoreCurrentWindow — 通过 windowID 查 WindowState**

文件: `Sources/WindowManager.swift:857-883`（替换 `findState` 调用为 `findStateByWindowID`）

```swift
        // 聚焦窗口在主屏 → 检查 WindowState 中是否有 toggle state
        if let wsState = SessionWindowRegistry.shared.findStateByWindowID(currentWindowID) {
            if wsState.hasToggleState {
                guard let mainScreen = getMainScreen() else { return false }
                if wsState.isCorrupted(mainScreenFrame: mainScreen.frame) {
                    SessionWindowRegistry.shared.clearToggleState(pid: wsState.pid, tty: wsState.tty)
                    return false
                }
                // 构建 SavedWindowState 用于 hydrateMemory
                if let origFrame = wsState.originalFrame, let tgtFrame = wsState.targetFrame {
                    let savedState = SavedWindowState(
                        id: "\(wsState.pid)_\(wsState.tty ?? "none")",
                        pid: wsState.pid,
                        bundleIdentifier: wsState.bundleIdentifier,
                        appName: wsState.appName,
                        windowID: wsState.windowID,
                        windowNumber: wsState.axWindowNumber,
                        title: wsState.title,
                        originalFrame: RectPayload(origFrame),
                        targetFrame: RectPayload(tgtFrame),
                        sourceSpaceIndex: wsState.sourceSpace,
                        targetSpaceIndex: nil,
                        sourceYabaiDisplayIndex: wsState.sourceYabaiDisp,
                        sourceDisplaySpaceIndex: wsState.sourceDispSpace,
                        sourceDisplayIndex: wsState.sourceDisplay,
                        sourceDisplayID: nil,
                        targetDisplayIndex: wsState.targetDisplay,
                        restoreReason: wsState.toggleReason,
                        sessionID: wsState.sessionID,
                        savedAt: wsState.toggledAt ?? Date()
                    )
                    hydrateMemory(from: savedState, window: focusedWindow)
                    return true
                }
            }
        }
```

- [ ] **Step 2: 修改 isSavedStateCorrupted — 保持签名不变（仍接受 SavedWindowState）**

`isSavedStateCorrupted` 方法签名不变，它仍然接受 `SavedWindowState` 类型。但由于 toggle state 现在也在 `WindowState` 中，`WindowState.isCorrupted()` 方法已经提供了相同功能。`shouldRestoreCurrentWindow` 中已改用 `wsState.isCorrupted()`。

- [ ] **Step 3: 修改 WindowManager+State.swift — saveWindowState 适配**

文件: `Sources/WindowManager+State.swift:10-36`

`saveWindowState` 方法在 toggle 场景下已被 Task 5 替代（直接调用 `SessionWindowRegistry.shared.updateToggleState`），但 hook 场景（`handleWindowMoveTrigger` → `moveBindingToMainScreen`）仍然调用 `moveWindowToMainScreen`，所以 `saveWindowState` 需要保留，但不再写入旧的 `window_states` 表（仅维护内存数组和 hydrate）。

将 `saveWindowState` 中的 `WindowStateStore.shared.saveState(state)` 注释或删除，因为 toggle state 已由 `SessionWindowRegistry.updateToggleState` 写入新表。同时保留内存数组的更新和 AX element 缓存。

- [ ] **Step 4: 编译验证**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | grep -E "error:|Build complete"`
Expected:
  - Output contains: "Build complete"
  - Output does NOT contain: "error:"

---

### Task 7: 清理旧代码 + 全量编译 + 部署验证

**Depends on:** Task 6
**Files:**
- Modify: `Sources/WindowStateStore.swift`（旧方法标记 `@available(*, deprecated)` 或删除）
- Modify: `Sources/WindowManager+State.swift`（清理旧的 `window_states` 读写）

- [ ] **Step 1: 标记旧方法为 deprecated**

在 `WindowStateStore.swift` 中，给 `saveState`、`loadStates`、`findState`、`findStateByApp`、`findStateByPID`、`saveBinding`、`loadBindings` 等 old-table 方法添加 `@available(*, deprecated, message: "Use windows table methods instead")`。不删除方法体，确保如果有遗漏的调用也不会编译失败。

- [ ] **Step 2: 全量编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"
  - Output does NOT contain: "error:"

- [ ] **Step 3: 部署到本地应用**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && bash scripts/build-and-deploy.sh 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output contains: "signed" or "deployed"

- [ ] **Step 4: 重启 VibeFocus 并验证**
Run: `killall VibeFocus 2>/dev/null; sleep 1; open /Users/cc11001100/Applications/VibeFocus.app`
Expected:
  - VibeFocus app launches successfully
  - 日志中出现 "loaded N window states from SQLite" (N 可能是 0，因为新表刚创建)

- [ ] **Step 5: 提交**
Run: `git add Sources/ && git commit -m "refactor(storage): migrate from dual-table (session_bindings + window_states) to unified windows table with PK=(pid, tty) — eliminates cross-table lookup failures"`
