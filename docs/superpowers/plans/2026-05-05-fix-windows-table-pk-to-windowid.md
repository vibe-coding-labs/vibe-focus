# Fix: Windows 表主键从 (pid, tty) 改为 window_id

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 将 `windows` 表主键从 `(pid, tty)` 改为 `window_id`，修复 Terminal.app 多窗口共享同一行导致 toggle state 被覆盖的根因。同时删除之前加的所有 fallback 逻辑（windowID mismatch check、updateToggleState 多级匹配等）。

**Root Cause:** `PRIMARY KEY (pid, tty)` 设计错误。Terminal.app 所有窗口共享 pid=454 和 tty="not a tty"，导致多个窗口映射到同一行。窗口 A 的 toggle state 被窗口 B 覆盖，restore 时把窗口 B 移动到窗口 A 的坐标。

**Architecture:** 数据流：SessionStart → 按 window_id 绑定 → 每个窗口独占一行。Ctrl+Q toggle → 按 window_id 更新 toggle state。UserPromptSubmit → 按 window_id 查找 toggle state 并 restore。pid 和 tty 降级为普通列，仅用于日志和匹配辅助，不再参与行标识。

**Tech Stack:** Swift 5.9, macOS 13+, SQLite (via Csqlite3), CGWindowList API

**Risks:**
- Task 1 改 WindowState 结构体影响所有调用点 → 缓解：逐文件更新 + 编译验证
- Task 3 数据库迁移会丢弃现有状态 → 缓解：窗口状态是临时的，可接受清空
- Task 4 删除 fallback 逻辑可能暴露其他 bug → 缓解：删除后全流程测试

---

### Task 1: 修改 WindowState 模型 — windowID 从 Optional 改为 Non-Optional

**Depends on:** None
**Files:**
- Modify: `Sources/ClaudeHookModels.swift:42-53` (WindowState struct header)

`windowID: UInt32?` 改为 `windowID: UInt32`。window_id 是主键，必须非空。同时调整构造函数中 windowID 的位置——放在最前面，体现它是主键。

- [ ] **Step 1: 修改 WindowState struct — windowID 改为非 Optional 主键**

文件: `Sources/ClaudeHookModels.swift:42-53`（替换 WindowState struct 的属性声明区）

```swift
struct WindowState: Codable, Equatable {
    // MARK: - Primary Key
    let windowID: UInt32          // CGWindowNumber — 主键，全局唯一标识窗口
    var pid: Int32
    var tty: String?              // 终端 TTY 路径 (如 /dev/ttys003)，仅用于日志和匹配辅助

    // MARK: - Window Identity
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
```

- [ ] **Step 2: 修改 WindowState 的 windowToken 计算属性 — 去掉可选解包**

文件: `Sources/ClaudeHookModels.swift:123-135`（替换 windowToken 属性）

```swift
    var windowToken: WindowManager.WindowToken? {
        return WindowManager.WindowToken(
            stateID: "\(windowID)",
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            windowID: windowID,
            windowNumber: axWindowNumber,
            title: title
        )
    }
```

- [ ] **Step 3: 验证编译**
Run: `swift build 2>&1 | tail -20`
Expected:
  - Output contains multiple errors referencing `windowID` — 这是预期的，后续 Task 修复

---

### Task 2: 修改 WindowStateStore — schema + SQL 全部改为 window_id 主键

**Depends on:** Task 1
**Files:**
- Modify: `Sources/WindowStateStore.swift:67-104` (CREATE TABLE + indexes)
- Modify: `Sources/WindowStateStore.swift:407-472` (saveWindowState INSERT)
- Modify: `Sources/WindowStateStore.swift:474-510` (findWindowState 系列)
- Modify: `Sources/WindowStateStore.swift:512-531` (clearToggleState)
- Modify: `Sources/WindowStateStore.swift:574-583` (deleteWindowState)
- Modify: `Sources/WindowStateStore.swift:596-650` (parseWindowStateRow)

- [ ] **Step 1: 修改 CREATE TABLE — PK 改为 window_id**

文件: `Sources/WindowStateStore.swift:67-104`（替换 runSchema 块中的 windows 建表语句和索引）

```swift
        runSchema("""
            CREATE TABLE IF NOT EXISTS windows (
                window_id INTEGER NOT NULL,
                pid INTEGER NOT NULL,
                tty TEXT NOT NULL DEFAULT '',
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
                completed_at REAL,
                PRIMARY KEY (window_id)
            );
            """)
        runSchema("CREATE INDEX IF NOT EXISTS idx_windows_session_id ON windows(session_id);")
        runSchema("CREATE INDEX IF NOT EXISTS idx_windows_pid_tty ON windows(pid, tty);")
        runSchema("CREATE INDEX IF NOT EXISTS idx_windows_last_seen ON windows(updated_at);")
        // 迁移：重建表以更新 PK（窗口状态是临时的，清空可接受）
        runSchema("DROP TABLE IF EXISTS windows;")
        runSchema("""
            CREATE TABLE windows (
                window_id INTEGER NOT NULL,
                pid INTEGER NOT NULL,
                tty TEXT NOT NULL DEFAULT '',
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
                completed_at REAL,
                PRIMARY KEY (window_id)
            );
            """)
        runSchema("CREATE INDEX IF NOT EXISTS idx_windows_session_id ON windows(session_id);")
        runSchema("CREATE INDEX IF NOT EXISTS idx_windows_pid_tty ON windows(pid, tty);")
        runSchema("CREATE INDEX IF NOT EXISTS idx_windows_last_seen ON windows(updated_at);")
```

- [ ] **Step 2: 修改 saveWindowState — INSERT 列顺序改为 window_id 在前**

文件: `Sources/WindowStateStore.swift:407-459`（替换 saveWindowState 函数体）

```swift
    func saveWindowState(_ state: WindowState) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = """
            INSERT OR REPLACE INTO windows (
                window_id, pid, tty, ax_window_number, app_name, bundle_id, title,
                term_session_id, iterm_session_id, kitty_window_id, wezterm_pane, env_window_id,
                session_id, cwd, model,
                orig_x, orig_y, orig_w, orig_h,
                target_x, target_y, target_w, target_h,
                source_space, source_display, source_yabai_disp, source_disp_space,
                target_display, toggle_reason, toggled_at,
                is_completed, created_at, updated_at, completed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(state.windowID))
        sqlite3_bind_int(stmt, 2, state.pid)
        sqlite3_bind_text(stmt, 3, state.tty ?? "", -1, SQLITE_TRANSIENT)
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
        if let v = state.completedAt { sqlite3_bind_double(stmt, 34, v.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 34) }

        if sqlite3_step(stmt) != SQLITE_DONE {
            let errMsg = String(cString: sqlite3_errmsg(db))
            log("[WindowStateStore] saveWindowState failed: \(errMsg)", level: .error)
        } else {
            log("[WindowStateStore] saveWindowState OK wid=\(state.windowID) pid=\(state.pid) tty=\(state.tty ?? "")")
        }
    }
```

- [ ] **Step 3: 修改 findWindowState — 按 window_id 查找**

文件: `Sources/WindowStateStore.swift:474-486`（替换 findWindowState 函数）

```swift
    func findWindowState(windowID: UInt32) -> WindowState? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let sql = "SELECT * FROM windows WHERE window_id = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(windowID))

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return parseWindowStateRow(stmt!)
    }
```

- [ ] **Step 4: 修改 clearToggleState — 按 window_id 查找**

文件: `Sources/WindowStateStore.swift:512-531`（替换 clearToggleState 函数）

```swift
    func clearToggleState(windowID: UInt32) {
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
            WHERE window_id = ?;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 2, Int64(windowID))
        sqlite3_step(stmt)
    }
```

- [ ] **Step 5: 修改 deleteWindowState — 按 window_id 删除**

文件: `Sources/WindowStateStore.swift:574-583`（替换 deleteWindowState 函数）

```swift
    func deleteWindowState(windowID: UInt32) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = "DELETE FROM windows WHERE window_id = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(windowID))
        sqlite3_step(stmt)
    }
```

- [ ] **Step 6: 修改 parseWindowStateRow — 列顺序匹配新 schema**

文件: `Sources/WindowStateStore.swift:596-650`（替换 parseWindowStateRow 函数）

```swift
    private func parseWindowStateRow(_ stmt: OpaquePointer) -> WindowState? {
        // 列顺序: window_id, pid, tty, ax_window_number, app_name, ...
        let windowID = UInt32(sqlite3_column_int64(stmt, 0))
        let pid = sqlite3_column_int(stmt, 1)
        let tty = String(cString: sqlite3_column_text(stmt, 2))
        let axWindowNumber: Int? = sqlite3_column_type(stmt, 3) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 3)) : nil
        let appName = optionalStringCol(stmt, col: 4)
        let bundleID = optionalStringCol(stmt, col: 5)
        let title = optionalStringCol(stmt, col: 6)
        let termSessionID = optionalStringCol(stmt, col: 7)
        let itermSessionID = optionalStringCol(stmt, col: 8)
        let kittyWindowID = optionalStringCol(stmt, col: 9)
        let weztermPane = optionalStringCol(stmt, col: 10)
        let envWindowID = optionalStringCol(stmt, col: 11)
        let sessionID = optionalStringCol(stmt, col: 12)
        let cwd = optionalStringCol(stmt, col: 13)
        let model = optionalStringCol(stmt, col: 14)

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
        let toggleReason = optionalStringCol(stmt, col: 28)
        let toggledAt: Date? = sqlite3_column_type(stmt, 29) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 29)) : nil

        let isCompleted = sqlite3_column_int(stmt, 30) != 0
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 31))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 32))
        let completedAt: Date? = sqlite3_column_type(stmt, 33) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 33)) : nil

        return WindowState(
            windowID: windowID,
            pid: pid,
            tty: tty.isEmpty ? nil : tty,
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
            completedAt: completedAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
```

- [ ] **Step 7: 验证编译**
Run: `swift build 2>&1 | grep -c "error:"`
Expected:
  - 输出一个数字（预计还有一些编译错误来自 SessionWindowRegistry 等调用方，下一 Task 修复）

- [ ] **Step 8: 提交**
Run: `git add Sources/ClaudeHookModels.swift Sources/WindowStateStore.swift && git commit -m "refactor(schema): change windows table PK from (pid,tty) to window_id"`

---

### Task 3: 重写 SessionWindowRegistry — 内存缓存改为 windowID 索引

**Depends on:** Task 2
**Files:**
- Modify: `Sources/SessionWindowRegistry.swift` (全文重构)

核心变更：`windowStates` 字典 key 从 `String`（"pid_tty"）改为 `UInt32`（windowID）。所有方法改为以 windowID 为主参数。删除 `cacheKey(pid:tty:)`、`findState(pid:tty:)`、`findStateByWindowID` 的 PID 验证（因为 key 就是 windowID，不可能匹配错误）。删除 `updateToggleState` 的多级匹配逻辑。

- [ ] **Step 1: 重写 SessionWindowRegistry — 以 windowID 为 key**

文件: `Sources/SessionWindowRegistry.swift`（替换全文）

```swift
import Foundation
import Cocoa

@MainActor
final class SessionWindowRegistry: ObservableObject {
    static let shared = SessionWindowRegistry()

    @Published private(set) var lastEventDescription: String = "尚未收到 Claude Hook 事件"

    /// 内存缓存：key = windowID (CGWindowNumber)，value = WindowState
    private(set) var windowStates: [UInt32: WindowState] = [:]

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
            windowStates[state.windowID] = state
        }
        log("SessionWindowRegistry.init loaded \(loaded.count) window states from SQLite")
        pruneExpiredBindings(shouldPersist: false)
    }

    // MARK: - Bind

    func bind(sessionID: String, windowIdentity: WindowIdentity, terminalTTY: String? = nil, terminalSessionID: String? = nil, itermSessionID: String? = nil, cwd: String? = nil, model: String? = nil) {
        let now = Date()
        let wid = windowIdentity.windowID

        var resolvedWindowNumber = windowIdentity.windowNumber
        if resolvedWindowNumber == nil, let axWindow = WindowManager.shared.resolveWindow(identity: windowIdentity) {
            resolvedWindowNumber = WindowManager.shared.windowNumber(for: axWindow)
        }

        if var existing = windowStates[wid] {
            existing.pid = windowIdentity.pid
            existing.tty = terminalTTY
            existing.axWindowNumber = resolvedWindowNumber
            existing.appName = windowIdentity.appName
            existing.bundleIdentifier = windowIdentity.bundleIdentifier
            existing.title = windowIdentity.title
            existing.sessionID = sessionID
            existing.isCompleted = false
            existing.completedAt = nil
            existing.updatedAt = now
            existing.termSessionID = terminalSessionID
            existing.itermSessionID = itermSessionID
            existing.cwd = cwd
            existing.model = model
            windowStates[wid] = existing
        } else {
            var state = WindowState(
                windowID: wid,
                pid: windowIdentity.pid,
                tty: terminalTTY,
                axWindowNumber: resolvedWindowNumber,
                appName: windowIdentity.appName,
                bundleIdentifier: windowIdentity.bundleIdentifier,
                title: windowIdentity.title,
                termSessionID: terminalSessionID,
                itermSessionID: itermSessionID,
                sessionID: sessionID,
                isCompleted: false,
                createdAt: now,
                updatedAt: now
            )
            state.cwd = cwd
            state.model = model
            windowStates[wid] = state
        }

        lastEventDescription = "SessionStart 绑定窗口：\(windowIdentity.appName ?? "Unknown") / \(windowIdentity.title ?? "Untitled")"
        pruneExpiredBindings(shouldPersist: false)
        persistToDB(windowID: wid)
    }

    // MARK: - Lookup

    /// 按 sessionID 查找窗口状态（扫描，低频操作）
    func binding(for sessionID: String) -> WindowState? {
        if let state = windowStates.values.first(where: { $0.sessionID == sessionID }) {
            return state
        }
        if let state = WindowStateStore.shared.findWindowStateBySession(sessionID: sessionID) {
            windowStates[state.windowID] = state
            return state
        }
        return nil
    }

    /// 按 windowID 查找窗口状态（O(1)，主查找路径）
    func findState(windowID: UInt32) -> WindowState? {
        if let state = windowStates[windowID] {
            return state
        }
        if let state = WindowStateStore.shared.findWindowState(windowID: windowID) {
            windowStates[state.windowID] = state
            return state
        }
        return nil
    }

    // MARK: - Verify

    func verifyBinding(_ state: WindowState) -> Bool {
        let expectedPID = state.pid
        let windowID = state.windowID

        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: state.bundleIdentifier ?? "")
        let pidMatches = runningApps.contains { $0.processIdentifier == expectedPID }
        if !pidMatches {
            let pidExists = kill(expectedPID, 0) == 0
            if !pidExists { return false }
        }

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

    // MARK: - State Updates

    func markCompleted(sessionID: String) {
        guard let state = binding(for: sessionID) else { return }
        guard var updated = windowStates[state.windowID] else { return }
        updated.isCompleted = true
        updated.completedAt = Date()
        updated.updatedAt = Date()
        windowStates[state.windowID] = updated
        lastEventDescription = "SessionEnd 已完成：\(updated.appName ?? "Unknown")"
        persistToDB(windowID: state.windowID)
    }

    func reactivate(sessionID: String) {
        guard let state = binding(for: sessionID) else { return }
        guard var updated = windowStates[state.windowID] else { return }
        updated.isCompleted = false
        updated.completedAt = nil
        updated.updatedAt = Date()
        windowStates[state.windowID] = updated
        persistToDB(windowID: state.windowID)
    }

    func touch(sessionID: String, message: String? = nil) {
        guard let state = binding(for: sessionID) else { return }
        guard var updated = windowStates[state.windowID] else { return }
        updated.updatedAt = Date()
        windowStates[state.windowID] = updated
        persistToDB(windowID: state.windowID)
        if let message, !message.isEmpty {
            lastEventDescription = message
        }
    }

    func setLastEventDescription(_ message: String) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lastEventDescription = message
    }

    // MARK: - Toggle State

    /// 按 windowID 更新 toggle state（由 WindowManager 调用）
    func updateToggleState(windowID: UInt32, toggleUpdater: (inout WindowState) -> Void) {
        if var state = windowStates[windowID] {
            toggleUpdater(&state)
            state.updatedAt = Date()
            windowStates[windowID] = state
            persistToDB(windowID: windowID)
        } else {
            // 不存在则创建 — windowID 已知
            var state = WindowState(
                windowID: windowID,
                pid: 0,
                isCompleted: false,
                createdAt: Date(),
                updatedAt: Date()
            )
            toggleUpdater(&state)
            windowStates[windowID] = state
            persistToDB(windowID: windowID)
        }
    }

    /// 清除指定窗口的 toggle state
    func clearToggleState(windowID: UInt32) {
        if var state = windowStates[windowID] {
            state.origX = nil; state.origY = nil; state.origW = nil; state.origH = nil
            state.targetX = nil; state.targetY = nil; state.targetW = nil; state.targetH = nil
            state.sourceSpace = nil; state.sourceDisplay = nil; state.sourceYabaiDisp = nil
            state.sourceDispSpace = nil; state.targetDisplay = nil
            state.toggleReason = nil; state.toggledAt = nil
            state.updatedAt = Date()
            windowStates[windowID] = state
            persistToDB(windowID: windowID)
        }
        WindowStateStore.shared.clearToggleState(windowID: windowID)
    }

    // MARK: - Bulk Operations

    func clearAllBindings() {
        windowStates.removeAll()
        lastEventDescription = "所有绑定已清除"
        WindowStateStore.shared.deleteAllWindowsStates()
    }

    func purgeClosedWindows() {
        let options: CGWindowListOption = [.optionAll]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        var activeWindowIDs: Set<UInt32> = []
        for info in windowList {
            if let wid = info[kCGWindowNumber as String] as? UInt32 {
                activeWindowIDs.insert(wid)
            }
        }

        let keysToRemove = windowStates.filter { _, state in
            guard !state.isCompleted else { return false }
            return !activeWindowIDs.contains(state.windowID)
        }.map(\.key)

        for key in keysToRemove {
            if let state = windowStates[key] {
                log("[SessionWindowRegistry] purging closed window: wid=\(state.windowID) pid=\(state.pid) app=\(state.appName ?? "unknown")")
                WindowStateStore.shared.deleteWindowState(windowID: state.windowID)
            }
            windowStates.removeValue(forKey: key)
        }
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

    private func persistToDB(windowID: UInt32) {
        guard let state = windowStates[windowID] else { return }
        WindowStateStore.shared.saveWindowState(state)
    }
}
```

- [ ] **Step 2: 验证编译**
Run: `swift build 2>&1 | grep "error:" | head -20`
Expected:
  - 剩余编译错误全部来自调用方（HookEventHandler、WindowManager、MoveWindow），下一 Task 修复

- [ ] **Step 3: 提交**
Run: `git add Sources/SessionWindowRegistry.swift && git commit -m "refactor(registry): reindex SessionWindowRegistry by windowID as primary key"`

---

### Task 4: 更新所有调用方 — HookEventHandler + WindowManager + MoveWindow

**Depends on:** Task 3
**Files:**
- Modify: `Sources/HookEventHandler.swift` (全文更新)
- Modify: `Sources/WindowManager.swift:857-900` (shouldRestoreCurrentWindow)
- Modify: `Sources/WindowManager+MoveWindow.swift:385-412` (updateToggleState 调用)

**删除所有 fallback 逻辑：** windowID mismatch check、findStateByWindowID 的 PID 验证、updateToggleState 的多级匹配。这些 workaround 不再需要——key 就是 windowID，不可能匹配到错误的行。

- [ ] **Step 1: 重写 HookEventHandler — 简化所有查找路径**

文件: `Sources/HookEventHandler.swift`（替换 handleUserPromptSubmit 和 performRestoreFromState）

`handleUserPromptSubmit`:
```swift
    func handleUserPromptSubmit(
        payload: ClaudeHookPayload
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        lastActivityBySession[payload.sessionID] = Date()

        log(
            "[HookEventHandler] UserPromptSubmit triggered",
            fields: [
                "sessionID": payload.sessionID,
                "autoRestoreEnabled": String(ClaudeHookPreferences.autoRestoreOnPromptSubmit),
                "cwd": payload.cwd ?? "nil"
            ]
        )

        guard ClaudeHookPreferences.autoRestoreOnPromptSubmit else {
            SessionWindowRegistry.shared.touch(
                sessionID: payload.sessionID,
                message: "UserPromptSubmit 收到（自动恢复已关闭）"
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "auto_restore_disabled",
                    message: "UserPromptSubmit received, auto restore disabled",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 通过 sessionID 找到窗口状态
        let state = SessionWindowRegistry.shared.binding(for: payload.sessionID)
        let identity: WindowIdentity?

        if let state {
            guard SessionWindowRegistry.shared.verifyBinding(state) else {
                log(
                    "[HookEventHandler] UserPromptSubmit binding verification failed",
                    level: .warn,
                    fields: ["sessionID": payload.sessionID, "wid": String(state.windowID)]
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
                windowID: state.windowID,
                pid: state.pid,
                bundleIdentifier: state.bundleIdentifier,
                appName: state.appName,
                windowNumber: state.axWindowNumber,
                title: state.title,
                capturedAt: state.createdAt
            )
        } else if let terminalCtx = payload.terminalCtx, terminalCtx.hasUsefulContext {
            identity = WindowManager.shared.findWindowByTerminalContext(terminalCtx)
        } else {
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
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "no_action_needed",
                    message: "Window not on main screen",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 按 windowID 直接查找 toggle state
        if let toggleState = SessionWindowRegistry.shared.findState(windowID: identity.windowID) {
            if toggleState.hasToggleState {
                guard let mainScreen = wm.getMainScreen() else {
                    return (200, ClaudeHookResponse(ok: true, code: "no_main_screen", message: "No main screen", sessionID: payload.sessionID, handled: false))
                }
                if !toggleState.isCorrupted(mainScreenFrame: mainScreen.frame) {
                    return performRestoreFromState(
                        payload: payload, toggleState: toggleState
                    )
                } else {
                    SessionWindowRegistry.shared.clearToggleState(windowID: identity.windowID)
                }
            }
        }

        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "no_action_needed",
                message: "No toggle state found for window",
                sessionID: payload.sessionID, handled: false
            )
        )
    }
```

`performRestoreFromState`:
```swift
    private func performRestoreFromState(
        payload: ClaudeHookPayload,
        toggleState: WindowState
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        let wm = WindowManager.shared

        guard let origFrame = toggleState.originalFrame,
              let tgtFrame = toggleState.targetFrame else {
            return (200, ClaudeHookResponse(ok: true, code: "no_frame_data", message: "No frame data", sessionID: payload.sessionID, handled: false))
        }

        let savedState = WindowManager.SavedWindowState(
            id: "\(toggleState.windowID)",
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

        // 验证找到的窗口确实在 targetFrame 附近
        if let resolvedWindow = wm.lastWindowElement,
           let resolvedFrame = wm.frame(of: resolvedWindow) {
            if !toggleState.isNearTarget(currentFrame: resolvedFrame) {
                log(
                    "[HookEventHandler] restore aborted: window moved from target pos",
                    level: .warn,
                    fields: [
                        "sessionID": payload.sessionID,
                        "windowID": String(toggleState.windowID)
                    ]
                )
                SessionWindowRegistry.shared.clearToggleState(windowID: toggleState.windowID)
                return (
                    200,
                    ClaudeHookResponse(
                        ok: true, code: "window_moved_skip",
                        message: "Window position changed, skipping stale restore",
                        sessionID: payload.sessionID, handled: false
                    )
                )
            }
        }

        log(
            "[HookEventHandler] restoring window",
            fields: [
                "sessionID": payload.sessionID,
                "windowID": String(toggleState.windowID),
                "app": toggleState.appName ?? "unknown",
                "originalFrame": String(describing: origFrame),
                "targetFrame": String(describing: tgtFrame)
            ]
        )

        wm.restore(
            operationID: makeOperationID(prefix: "hook-restore"),
            triggerSource: "user_prompt_submit"
        )

        SessionWindowRegistry.shared.reactivate(sessionID: payload.sessionID)
        SessionWindowRegistry.shared.clearToggleState(windowID: toggleState.windowID)

        SessionWindowRegistry.shared.setLastEventDescription(
            "UserPromptSubmit 恢复窗口：\(toggleState.appName ?? "Unknown")"
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

- [ ] **Step 2: 修改 shouldRestoreCurrentWindow — 按 windowID 查找**

文件: `Sources/WindowManager.swift` 找到 `shouldRestoreCurrentWindow` 函数中的 `findStateByWindowID` 调用块，替换为：

```swift
        if let wsState = SessionWindowRegistry.shared.findState(windowID: currentWindowID) {
            if wsState.hasToggleState {
                guard let mainScreen = getMainScreen() else { return false }
                if wsState.isCorrupted(mainScreenFrame: mainScreen.frame) {
                    SessionWindowRegistry.shared.clearToggleState(windowID: currentWindowID)
                    return false
                }
                if let origFrame = wsState.originalFrame, let tgtFrame = wsState.targetFrame {
                    let currentFrame = self.frame(of: focusedWindow)
                    if let curFrame = currentFrame, !wsState.isNearTarget(currentFrame: curFrame) {
                        log(
                            "[WindowManager] shouldRestoreCurrentWindow: window not at target position",
                            level: .warn,
                            fields: ["windowID": "\(currentWindowID)"]
                        )
                        return false
                    }
                    let savedState = SavedWindowState(
                        id: "\(wsState.windowID)",
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

- [ ] **Step 3: 修改 MoveWindow 的 updateToggleState 调用 — 传 windowID**

文件: `Sources/WindowManager+MoveWindow.swift:385-412`（替换 updateToggleState 调用块）

```swift
        SessionWindowRegistry.shared.updateToggleState(
            windowID: currentWindowID
        ) { state in
            state.pid = identity.pid
            state.tty = nil
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

- [ ] **Step 4: 验证编译**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 5: 部署验证**
Run: `bash scripts/dev-build.sh 2>&1 | tail -3`
Expected:
  - Output contains: "构建成功"

- [ ] **Step 6: 提交**
Run: `git add Sources/HookEventHandler.swift Sources/WindowManager.swift Sources/WindowManager+MoveWindow.swift && git commit -m "refactor(callers): update all callers to use windowID as primary lookup key, remove fallback logic"`

---

### Task 5: 迁移日志文件从 /tmp 到 ~/Library/Logs/VibeFocus/

**Depends on:** None
**Files:**
- Modify: `Sources/Support.swift:19-21` (日志路径)

- [ ] **Step 1: 修改日志路径到 macOS 标准位置**

文件: `Sources/Support.swift:19-21`（替换三个日志路径常量）

```swift
private let logDirectoryURL: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Logs")
        .appendingPathComponent("VibeFocus")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

private let logFileURL = logDirectoryURL.appendingPathComponent("vibefocus.log")
private let structuredLogFileURL = logDirectoryURL.appendingPathComponent("vibefocus-events.jsonl")
private let logFileBackupURL = logDirectoryURL.appendingPathComponent("vibefocus.log.1")
private let structuredLogBackupURL = logDirectoryURL.appendingPathComponent("vibefocus-events.jsonl.1")
```

同步修改 crash snapshot 路径:

文件: `Sources/Support.swift:493-496`（替换 crashSnapshotFD 路径）

```swift
private let crashSnapshotFD: Int32 = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Logs")
        .appendingPathComponent("VibeFocus")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("vibefocus-crash-snapshot.log").path
    return open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
}()
```

文件: `Sources/Support.swift:610-615`（替换 atexit 中的路径）

```swift
func installAtExitHandler() {
    atexit {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Logs")
            .appendingPathComponent("VibeFocus")
        let path = dir.appendingPathComponent("vibefocus-crash-snapshot.log").path
        let msg = "VibeFocus exiting via atexit (likely normal termination)\n"
        msg.withCString { ptr in
            let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            if fd != -1 {
                write(fd, ptr, strlen(ptr))
                close(fd)
            }
        }
    }
}
```

- [ ] **Step 2: 验证编译**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 3: 提交**
Run: `git add Sources/Support.swift && git commit -m "refactor(log): migrate log files from /tmp to ~/Library/Logs/VibeFocus/"`
