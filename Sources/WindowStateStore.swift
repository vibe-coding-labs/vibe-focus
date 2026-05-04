import Foundation
import Csqlite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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

    private func runSchema(_ sql: String) {
        guard let db else { return }
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            log("[WindowStateStore] schema error: \(msg)", level: .error)
        }
    }

    private func createTables() {
        runSchema("""
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
            """)
        runSchema("CREATE INDEX IF NOT EXISTS idx_window_states_window_id ON window_states(window_id);")
        runSchema("CREATE INDEX IF NOT EXISTS idx_window_states_session_id ON window_states(session_id);")
        runSchema("""
            CREATE TABLE IF NOT EXISTS session_bindings (
                session_id TEXT PRIMARY KEY,
                data TEXT NOT NULL,
                is_completed INTEGER NOT NULL DEFAULT 0,
                last_seen_at REAL NOT NULL,
                created_at REAL NOT NULL DEFAULT (strftime('%s','now'))
            );
            """)
        runSchema("CREATE INDEX IF NOT EXISTS idx_session_bindings_last_seen ON session_bindings(last_seen_at);")

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
        runSchema("DELETE FROM window_states;")
    }

    func findState(windowID: UInt32, sessionID: String?) -> WindowManager.SavedWindowState? {
        guard let db else { return nil }
        var stmt: OpaquePointer?

        // 优先 windowID + sessionID 精确匹配
        if let sessionID, !sessionID.isEmpty {
            let sql = "SELECT data FROM window_states WHERE window_id = ? AND session_id = ? ORDER BY saved_at DESC LIMIT 1;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(windowID))
            sqlite3_bind_text(stmt, 2, sessionID, -1, SQLITE_TRANSIENT)

            if sqlite3_step(stmt) == SQLITE_ROW,
               let cStr = sqlite3_column_text(stmt, 0) {
                let jsonString = String(cString: cStr)
                if let data = jsonString.data(using: .utf8),
                   let state = try? JSONDecoder().decode(WindowManager.SavedWindowState.self, from: data) {
                    return state
                }
            }
            sqlite3_finalize(stmt)
            stmt = nil
        }

        // Fallback: 仅 windowID 匹配（session_id 为空或历史数据）
        let fallbackSQL = "SELECT data FROM window_states WHERE window_id = ? ORDER BY saved_at DESC LIMIT 1;"
        guard sqlite3_prepare_v2(db, fallbackSQL, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(windowID))

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

    func findStateByPID(pid: Int32, sessionID: String?) -> WindowManager.SavedWindowState? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let sql: String
        if let sessionID, !sessionID.isEmpty {
            sql = "SELECT data FROM window_states WHERE pid = ? AND session_id = ? ORDER BY saved_at DESC LIMIT 1;"
        } else {
            sql = "SELECT data FROM window_states WHERE pid = ? ORDER BY saved_at DESC LIMIT 1;"
        }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(pid))
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
            if !existingWindowIDs.contains(windowID) {
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
        runSchema("DELETE FROM session_bindings;")
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

    // MARK: - Windows (New Unified Table)

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
        return parseWindowStateRow(stmt!)
    }

    func findWindowStateBySession(sessionID: String) -> WindowState? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let sql = "SELECT * FROM windows WHERE session_id = ? ORDER BY updated_at DESC LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionID, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return parseWindowStateRow(stmt!)
    }

    func findWindowStateByWindowID(_ windowID: UInt32) -> WindowState? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let sql = "SELECT * FROM windows WHERE window_id = ? ORDER BY updated_at DESC LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(windowID))

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return parseWindowStateRow(stmt!)
    }

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

    func deleteAllWindowsStates() {
        guard let db else { return }
        runSchema("DELETE FROM windows;")
    }

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

    func loadAllWindowStates() -> [WindowState] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        let sql = "SELECT * FROM windows ORDER BY updated_at ASC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [WindowState] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let state = parseWindowStateRow(stmt!) {
                results.append(state)
            }
        }
        return results
    }

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

    private func optionalStringCol(_ stmt: OpaquePointer, col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        let raw = String(cString: sqlite3_column_text(stmt, col))
        return raw.isEmpty ? nil : raw
    }
}
