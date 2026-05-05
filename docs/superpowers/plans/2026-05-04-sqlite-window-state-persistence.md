# 窗口状态 SQLite 持久化升级

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 将 SavedWindowState 和 SessionWindowBinding 从 UserDefaults 迁移到 SQLite（`~/.vibefocus/vibefocus.db`），修复启动时过度清理导致崩溃/重启后窗口状态丢失的问题。

**Architecture:** 创建 `WindowStateStore` 单例封装 sqlite3 C API，提供 `saveState`/`loadStates`/`deleteState`/`saveBinding`/`loadBindings`/`deleteBinding` 接口。WindowManager+State.swift 和 SessionWindowRegistry.swift 改为调用 WindowStateStore 而非 UserDefaults。启动时清理逻辑添加 grace period，不再立即删除 windowID 暂时不存在的 state。使用 sqlite3 WAL 模式确保写入原子性，防止崩溃导致数据损坏。

**Tech Stack:** Swift 5.9, macOS 13+, sqlite3 C API（系统内置）, GCDWebServer 3.5.4

**Risks:**
- sqlite3 C API 在 Swift 中需要手动内存管理（sqlite3_stmt 生命周期），不注意会 leak → 缓解：所有 statement 用 defer sqlite3_finalize() 确保释放
- Task 2 修改 `hydrateMemory()` 的数据来源，如果 SQLite 读取失败会导致 restore 不可用 → 缓解：保留 UserDefaults 作为 fallback，启动时检测 SQLite 是否可用
- Task 4 修改清理逻辑，grace period 太长会积累垃圾数据 → 缓解：设置合理的 grace period（5 分钟），过期后仍然清理

---

### Task 1: 创建 WindowStateStore SQLite 存储层

**Depends on:** None
**Files:**
- Create: `Sources/WindowStateStore.swift`

- [ ] **Step 1: 创建 WindowStateStore — 封装 sqlite3 C API 提供窗口状态和 session binding 的 CRUD 操作**

```swift
// Sources/WindowStateStore.swift
import Foundation
import sqlite3

@MainActor
final class WindowStateStore {
    static let shared = WindowStateStore()

    private var db: OpaquePointer?
    private let dbPath: String

    private init() {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".vibefocus")
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        dbPath = (dir as NSString).appendingPathComponent("vibefocus.db")
        openDatabase()
        createTables()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Database Setup

    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            log("[WindowStateStore] failed to open database at \(dbPath)", level: .error)
            db = nil
            return
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA journal_mode=WAL;", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else {
            log("[WindowStateStore] failed to set WAL mode", level: .error)
            return
        }
        sqlite3_finalize(stmt)
        log("[WindowStateStore] database opened with WAL mode at \(dbPath)")
    }

    private func createTables() {
        let schemas = [
            """
            CREATE TABLE IF NOT EXISTS window_states (
                id TEXT PRIMARY KEY,
                data TEXT NOT NULL,
                window_id INTEGER,
                pid INTEGER,
                app_name TEXT,
                session_id TEXT,
                saved_at REAL NOT NULL,
                created_at REAL NOT NULL DEFAULT (strftime('%s','now'))
            );
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_window_states_window_id
                ON window_states(window_id);
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_window_states_session_id
                ON window_states(session_id);
            """,
            """
            CREATE TABLE IF NOT EXISTS session_bindings (
                session_id TEXT PRIMARY KEY,
                data TEXT NOT NULL,
                is_completed INTEGER NOT NULL DEFAULT 0,
                last_seen_at REAL NOT NULL,
                created_at REAL NOT NULL DEFAULT (strftime('%s','now'))
            );
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_session_bindings_last_seen
                ON session_bindings(last_seen_at);
            """,
            """
            CREATE TABLE IF NOT EXISTS schema_version (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """
        ]
        for schema in schemas {
            if sqlite3_exec(db, schema, nil, nil, nil) != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(db))
                log("[WindowStateStore] schema error: \(msg)", level: .error)
            }
        }
        log("[WindowStateStore] tables created/verified")
    }

    // MARK: - Window States

    func saveState(_ state: WindowManager.SavedWindowState) {
        guard let db, let data = try? JSONEncoder().encode(state) else { return }
        let jsonString = String(data: data, encoding: .utf8) ?? "{}"
        var stmt: OpaquePointer?
        let sql = """
            INSERT OR REPLACE INTO window_states (id, data, window_id, pid, app_name, session_id, saved_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, state.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, jsonString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 3, Int64(state.windowID ?? 0))
        sqlite3_bind_int(stmt, 4, state.pid)
        sqlite3_bind_text(stmt, 5, state.appName ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, state.sessionID ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 7, state.savedAt.timeIntervalSince1970)

        if sqlite3_step(stmt) != SQLITE_DONE {
            log("[WindowStateStore] saveState failed", level: .error)
        }
    }

    func loadStates() -> [WindowManager.SavedWindowState] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        let sql = "SELECT data FROM window_states ORDER BY saved_at ASC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [WindowManager.SavedWindowState] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cStr = sqlite3_column_text(stmt, 0) else { continue }
            let jsonString = String(cString: cStr)
            guard let data = jsonString.data(using: .utf8),
                  let state = try? JSONDecoder().decode(WindowManager.SavedWindowState.self, from: data) else {
                continue
            }
            results.append(state)
        }
        return results
    }

    func deleteState(id: String) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = "DELETE FROM window_states WHERE id = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    func deleteAllStates() {
        guard let db else { return }
        sqlite3_exec(db, "DELETE FROM window_states;", nil, nil, nil)
    }

    func findState(windowID: UInt32, sessionID: String?) -> WindowManager.SavedWindowState? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let sql: String
        if let sessionID, !sessionID.isEmpty {
            sql = "SELECT data FROM window_states WHERE window_id = ? AND session_id = ? ORDER BY saved_at DESC LIMIT 1;"
        } else {
            sql = "SELECT data FROM window_states WHERE window_id = ? ORDER BY saved_at DESC LIMIT 1;"
        }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(windowID))
        if let sessionID, !sessionID.isEmpty {
            sqlite3_bind_text(stmt, 2, sessionID, -1, SQLITE_TRANSIENT)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        let jsonString = String(cString: cStr)
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WindowManager.SavedWindowState.self, from: data)
    }

    func findStateByApp(appName: String, sessionID: String?) -> WindowManager.SavedWindowState? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let sql: String
        if let sessionID, !sessionID.isEmpty {
            sql = "SELECT data FROM window_states WHERE app_name = ? AND session_id = ? ORDER BY saved_at DESC LIMIT 1;"
        } else {
            sql = "SELECT data FROM window_states WHERE app_name = ? ORDER BY saved_at DESC LIMIT 1;"
        }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, appName, -1, SQLITE_TRANSIENT)
        if let sessionID, !sessionID.isEmpty {
            sqlite3_bind_text(stmt, 2, sessionID, -1, SQLITE_TRANSIENT)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        let jsonString = String(cString: cStr)
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WindowManager.SavedWindowState.self, from: data)
    }

    func evictStatesOlderThan(maxAge: TimeInterval) -> Int {
        guard let db else { return 0 }
        let cutoff = Date().addingTimeInterval(-maxAge).timeIntervalSince1970
        var stmt: OpaquePointer?
        let sql = "DELETE FROM window_states WHERE saved_at < ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff)
        sqlite3_step(stmt)
        return Int(sqlite3_changes(db))
    }

    func cleanupStaleStates(existingWindowIDs: Set<UInt32>, gracePeriod: TimeInterval) -> Int {
        guard let db else { return 0 }
        let cutoff = Date().addingTimeInterval(-gracePeriod).timeIntervalSince1970
        var stmt: OpaquePointer?
        let sql = "SELECT id, window_id, data FROM window_states WHERE saved_at < ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff)

        var toDelete: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cStr = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: cStr)
            let windowID = UInt32(sqlite3_column_int64(stmt, 1))
            if let windowID, !existingWindowIDs.contains(windowID) {
                toDelete.append(id)
            }
        }

        for id in toDelete {
            deleteState(id: id)
        }
        return toDelete.count
    }

    var statesCount: Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM window_states;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - Session Bindings

    func saveBinding(_ binding: SessionWindowBinding) {
        guard let db, let data = try? JSONEncoder().encode(binding) else { return }
        let jsonString = String(data: data, encoding: .utf8) ?? "{}"
        var stmt: OpaquePointer?
        let sql = """
            INSERT OR REPLACE INTO session_bindings (session_id, data, is_completed, last_seen_at)
            VALUES (?, ?, ?, ?);
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, binding.sessionID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, jsonString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, binding.isCompleted ? 1 : 0)
        sqlite3_bind_double(stmt, 4, binding.lastSeenAt.timeIntervalSince1970)

        if sqlite3_step(stmt) != SQLITE_DONE {
            log("[WindowStateStore] saveBinding failed", level: .error)
        }
    }

    func loadBindings() -> [String: SessionWindowBinding] {
        guard let db else { return [:] }
        var stmt: OpaquePointer?
        let sql = "SELECT data FROM session_bindings;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        var results: [String: SessionWindowBinding] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cStr = sqlite3_column_text(stmt, 0) else { continue }
            let jsonString = String(cString: cStr)
            guard let data = jsonString.data(using: .utf8),
                  let binding = try? JSONDecoder().decode(SessionWindowBinding.self, from: data) else {
                continue
            }
            results[binding.sessionID] = binding
        }
        return results
    }

    func deleteBinding(sessionID: String) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = "DELETE FROM session_bindings WHERE session_id = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionID, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    func deleteAllBindings() {
        guard let db else { return }
        sqlite3_exec(db, "DELETE FROM session_bindings;", nil, nil, nil)
    }

    func pruneExpiredBindings(activeRetention: TimeInterval, completedRetention: TimeInterval) -> Int {
        guard let db else { return 0 }
        let now = Date().timeIntervalSince1970
        let activeCutoff = now - activeRetention
        let completedCutoff = now - completedRetention

        let sql = """
            DELETE FROM session_bindings
            WHERE (is_completed = 0 AND last_seen_at < ?)
               OR (is_completed = 1 AND last_seen_at < ?);
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, activeCutoff)
        sqlite3_bind_double(stmt, 2, completedCutoff)
        sqlite3_step(stmt)
        return Int(sqlite3_changes(db))
    }

    var bindingsCount: Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM session_bindings;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }
}
```

- [ ] **Step 2: 验证编译 — 确保 SQLite 存储层能正确编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 3: 提交**
Run: `git add Sources/WindowStateStore.swift && git commit -m "$(cat <<'EOF'
feat(storage): add SQLite-backed WindowStateStore for crash-safe persistence

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

### Task 2: 迁移 WindowManager 窗口状态到 SQLite

**Depends on:** Task 1
**Files:**
- Modify: `Sources/WindowManager+State.swift:10-36, 38-52, 54-60`
- Modify: `Sources/WindowManager.swift:94-147`

- [ ] **Step 1: 修改 saveWindowState — 改用 WindowStateStore**

文件: `Sources/WindowManager+State.swift:10-36`（替换整个函数）

```swift
// 替换 Sources/WindowManager+State.swift:10-36 的 saveWindowState 函数
    func saveWindowState(_ state: SavedWindowState, window: AXUIElement? = nil) -> SavedWindowState {
        let removed = WindowStateStore.shared.evictStatesOlderThan(maxAge: 24 * 60 * 60)
        if removed > 0 {
            log("Evicted \(removed) expired state(s) from SQLite")
        }

        if let window {
            windowElementsByStateID[state.id] = window
        }

        WindowStateStore.shared.saveState(state)
        log(
            "Saved window state to SQLite: \(state.id)",
            fields: [
                "windowID": String(describing: state.windowID),
                "app": state.appName ?? "unknown"
            ]
        )
        return state
    }
```

- [ ] **Step 2: 修改 loadSavedWindowStates 和 persistSavedWindowStates**

文件: `Sources/WindowManager+State.swift:38-52`（替换两个函数）

```swift
// 替换 Sources/WindowManager+State.swift:38-52
    func loadSavedWindowStates() -> [SavedWindowState] {
        let states = WindowStateStore.shared.loadStates()
        log("Loaded \(states.count) window state(s) from SQLite")
        return states
    }

    func persistSavedWindowStates() {
        // SQLite 的 saveWindowState 已经逐条写入，无需批量持久化
    }
```

- [ ] **Step 3: 修改 clearSavedWindowState — 改用 WindowStateStore**

文件: `Sources/WindowManager+State.swift:54-60`（替换整个函数）

```swift
// 替换 Sources/WindowManager+State.swift:54-60 的 clearSavedWindowState
    func clearSavedWindowState(id: String?) {
        guard let id else { return }
        WindowStateStore.shared.deleteState(id: id)
        windowElementsByStateID.removeValue(forKey: id)
        log("Cleared window state from SQLite: \(id)")
    }
```

- [ ] **Step 4: 修改 WindowManager init — 替换清理逻辑为 grace period 模式**

文件: `Sources/WindowManager.swift:94-147`（替换 init + evictExpiredStates + cleanupStaleSavedStates）

```swift
// 替换 Sources/WindowManager.swift:94-147
    init() {
        savedWindowStates = loadSavedWindowStates()
        if !savedWindowStates.isEmpty {
            log("Loaded persisted window states from SQLite: \(savedWindowStates.count)")
        }
        cleanupStaleStatesWithGracePeriod()
    }

    /// 启动时清理 grace period 之外的无效 state
    /// grace period = 5 分钟：state 保存时间超过 5 分钟且 window 已不存在才删除
    /// 防止 app 短暂重启期间误删仍在使用的 state
    private func cleanupStaleStatesWithGracePeriod() {
        let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        let existingWindowIDs = Set(windowList.compactMap { $0["kCGWindowNumber"] as? UInt32 })

        let gracePeriod: TimeInterval = 5 * 60
        let removed = WindowStateStore.shared.cleanupStaleStates(
            existingWindowIDs: existingWindowIDs,
            gracePeriod: gracePeriod
        )

        if removed > 0 {
            savedWindowStates.removeAll { state in
                guard let wid = state.windowID else { return false }
                return !existingWindowIDs.contains(wid)
            }
            log("[WindowManager] cleanup with grace period: removed \(removed) stale state(s)")
        }
    }
```

- [ ] **Step 5: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 6: 提交**
Run: `git add Sources/WindowManager+State.swift Sources/WindowManager.swift && git commit -m "$(cat <<'EOF'
refactor(state): migrate window state persistence from UserDefaults to SQLite

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

### Task 3: 迁移 SessionWindowBinding 到 SQLite

**Depends on:** Task 1
**Files:**
- Modify: `Sources/SessionWindowRegistry.swift:19-28, 100, 210-216, 222-262`

- [ ] **Step 1: 修改 retention 常量和 init — 延长过期时间**

文件: `Sources/SessionWindowRegistry.swift:19-28`（替换常量和 init）

```swift
// 替换 Sources/SessionWindowRegistry.swift:19-28
    private let completedRetention: TimeInterval = 4 * 60 * 60  // 4 小时（原 30 分钟）
    private let activeRetention: TimeInterval = 24 * 60 * 60    // 24 小时（原 12 小时）

    private init() {
        bindings = WindowStateStore.shared.loadBindings()
        log("SessionWindowRegistry.init entry", level: .debug, fields: ["loadedBindingCount": String(bindings.count)])
        pruneExpiredBindings(shouldPersist: false)
        log("SessionWindowRegistry.init exit", level: .debug, fields: ["activeCount": String(activeBindingCount), "completedCount": String(completedBindingCount)])
    }
```

- [ ] **Step 2: 修改 verifyBinding — 使用 .optionAll 替代 .optionOnScreenOnly**

文件: `Sources/SessionWindowRegistry.swift:100`（修改 CGWindowList 查询选项）

```swift
// 替换 Sources/SessionWindowRegistry.swift:100
// 原代码: let options: CGWindowListOption = [.optionOnScreenOnly]
// 新代码: 使用 .optionAll 以包含最小化窗口
        let options: CGWindowListOption = [.optionAll]
```

- [ ] **Step 3: 修改 clearAllBindings — 使用 SQLite 批量删除**

文件: `Sources/SessionWindowRegistry.swift:210-216`（替换整个函数）

```swift
// 替换 Sources/SessionWindowRegistry.swift:210-216
    func clearAllBindings() {
        log("SessionWindowRegistry.clearAllBindings entry", level: .debug, fields: ["count": String(bindings.count)])
        bindings.removeAll()
        lastEventDescription = "所有绑定已清除"
        WindowStateStore.shared.deleteAllBindings()
        log("SessionWindowRegistry.clearAllBindings exit", level: .debug)
    }
```

- [ ] **Step 4: 修改 pruneExpiredBindings — 使用 SQLite 批量删除**

文件: `Sources/SessionWindowRegistry.swift:222-241`（替换整个函数）

```swift
// 替换 Sources/SessionWindowRegistry.swift:222-241
    private func pruneExpiredBindings(shouldPersist: Bool = true) {
        log("SessionWindowRegistry.pruneExpiredBindings entry", level: .debug, fields: ["bindingCount": String(bindings.count)])

        let removed = WindowStateStore.shared.pruneExpiredBindings(
            activeRetention: activeRetention,
            completedRetention: completedRetention
        )

        let now = Date()
        bindings = bindings.filter { _, binding in
            if binding.isCompleted {
                let deadline = (binding.completedAt ?? binding.lastSeenAt).addingTimeInterval(completedRetention)
                return deadline > now
            }
            let deadline = binding.lastSeenAt.addingTimeInterval(activeRetention)
            return deadline > now
        }

        if removed > 0 {
            log("SessionWindowRegistry.pruneExpiredBindings pruned", level: .debug, fields: ["removedCount": String(removed), "remaining": String(bindings.count)])
        }
    }
```

- [ ] **Step 5: 修改 persistBindings 和 loadBindings — 使用 SQLite**

文件: `Sources/SessionWindowRegistry.swift:243-262`（替换两个函数）

```swift
// 替换 Sources/SessionWindowRegistry.swift:243-262
    private func persistBindings() {
        for (_, binding) in bindings {
            WindowStateStore.shared.saveBinding(binding)
        }
        log("SessionWindowRegistry.persistBindings exit", level: .debug, fields: ["bindingCount": String(bindings.count)])
    }

    private func loadBindings() -> [String: SessionWindowBinding] {
        let loaded = WindowStateStore.shared.loadBindings()
        log("SessionWindowRegistry.loadBindings exit", level: .debug, fields: ["loadedCount": String(loaded.count)])
        return loaded
    }
```

- [ ] **Step 6: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 7: 提交**
Run: `git add Sources/SessionWindowRegistry.swift && git commit -m "$(cat <<'EOF'
refactor(bindings): migrate session bindings to SQLite, extend retention, fix verifyBinding

- Completed binding retention: 30min → 4h
- Active binding retention: 12h → 24h
- verifyBinding: use .optionAll instead of .optionOnScreenOnly to include minimized windows

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

### Task 4: 清理 PreferencesSync 和 HookEventHandler 中的 UserDefaults 残留

**Depends on:** Task 2, Task 3
**Files:**
- Modify: `Sources/PreferencesSync.swift:36-40`
- Modify: `Sources/HookEventHandler.swift:167-253`

- [ ] **Step 1: 从 PreferencesSync 注册表移除已迁移的 key**

文件: `Sources/PreferencesSync.swift:36-40`（删除两个已迁移的 key）

```swift
// 替换 Sources/PreferencesSync.swift:36-40
// 删除 "claudeSessionWindowBindings.v1" 和 "savedWindowStates" 这两行
// 它们已迁移到 SQLite，不再通过 PreferencesSync 管理
```

- [ ] **Step 2: 修改 HookEventHandler handleUserPromptSubmit — 使用 SQLite 查询**

文件: `Sources/HookEventHandler.swift:167-253`（替换 saved state 查找逻辑）

```swift
// 替换 Sources/HookEventHandler.swift:167-253 的 saved state 查找部分
// 从 "let targetWindowID = binding.windowIdentity.windowID" 开始到函数结束
        let targetWindowID = binding.windowIdentity.windowID
        let targetPID = binding.windowIdentity.pid
        let store = WindowStateStore.shared

        log(
            "[HookEventHandler] UserPromptSubmit searching saved state via SQLite",
            fields: [
                "sessionID": payload.sessionID,
                "bindingWindowID": String(targetWindowID),
                "bindingPID": String(targetPID)
            ]
        )

        // 优先级 1: windowID + session 精确匹配
        if let matchedState = store.findState(windowID: targetWindowID, sessionID: payload.sessionID) {
            let wm = WindowManager.shared
            if !wm.isSavedStateCorrupted(matchedState) {
                return performRestore(
                    payload: payload, matchedState: matchedState,
                    matchLevel: "exact_binding_match_session_scoped"
                )
            } else {
                wm.clearSavedWindowState(id: matchedState.id)
            }
        }

        // 优先级 2: 窗口在主屏 + 同会话同 app 的 saved state
        let wm = WindowManager.shared
        let isOnMain = wm.isWindowOnMainScreen(windowID: targetWindowID)
        if isOnMain {
            if let appState = store.findStateByApp(
                appName: binding.windowIdentity.appName ?? "",
                sessionID: payload.sessionID
            ) {
                if !wm.isSavedStateCorrupted(appState) {
                    return performRestore(
                        payload: payload, matchedState: appState,
                        matchLevel: "app_fallback_session_scoped"
                    )
                }
            }
        }

        log(
            "[HookEventHandler] UserPromptSubmit no matching state in SQLite",
            fields: [
                "sessionID": payload.sessionID,
                "windowOnMainScreen": String(isOnMain)
            ]
        )
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "no_action_needed",
                message: "No matching saved state in SQLite",
                sessionID: payload.sessionID, handled: false
            )
        )
```

- [ ] **Step 3: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 4: 提交**
Run: `git add Sources/PreferencesSync.swift Sources/HookEventHandler.swift && git commit -m "$(cat <<'EOF'
refactor: remove migrated keys from PreferencesSync, use SQLite queries in HookEventHandler

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

### Task 5: 构建部署验证 — 确保 SQLite 持久化端到端工作

**Depends on:** Task 4
**Files:**
- Modify: `Sources/WindowManager.swift:821`（shouldRestoreCurrentWindow 使用 SQLite 查询）

- [ ] **Step 1: 修改 shouldRestoreCurrentWindow — 使用 SQLite 查询**

文件: `Sources/WindowManager.swift:821`（替换 saved state 查找）

```swift
// 替换 Sources/WindowManager.swift:821
// 原代码: if let matchedState = savedWindowStates.reversed().first(where: { $0.windowID == currentWindowID }) {
// 新代码: 优先查 SQLite，fallback 到内存数组
        if let matchedState = WindowStateStore.shared.findState(windowID: currentWindowID, sessionID: nil) ?? savedWindowStates.reversed().first(where: { $0.windowID == currentWindowID }) {
```

- [ ] **Step 2: 构建并部署**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && bash scripts/dev-build.sh 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - Output contains: "构建成功！"

- [ ] **Step 3: 验证 SQLite 数据库创建**
Run: `ls -la ~/.vibefocus/vibefocus.db && sqlite3 ~/.vibefocus/vibefocus.db ".tables"`
Expected:
  - File exists and size > 0
  - Output contains: "window_states" and "session_bindings"

- [ ] **Step 4: 启动 app 并验证日志**
Run: `open /Applications/VibeFocus.app && sleep 3 && grep "WindowStateStore" /tmp/vibefocus.log | tail -5`
Expected:
  - Output contains: "database opened with WAL mode"
  - Output contains: "Loaded N window state(s) from SQLite"

- [ ] **Step 5: 提交**
Run: `git add Sources/WindowManager.swift && git commit -m "$(cat <<'EOF'
refactor(toggle): use SQLite queries in shouldRestoreCurrentWindow for reliable state lookup

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`
