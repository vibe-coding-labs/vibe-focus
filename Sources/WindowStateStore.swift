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
        cleanupLegacyTables()
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
        // 旧表保留但不再新建（兼容已有数据库）
        // session_bindings 已废弃：数据迁移到 windows 表后清理
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

        // 新宽表：合并 session_bindings + window_states
        // PK = window_id (CGWindowNumber)，全局唯一标识窗口
        runSchema("""
            CREATE TABLE IF NOT EXISTS windows (
                window_id INTEGER NOT NULL PRIMARY KEY,
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
                completed_at REAL
            );
            """)
        runSchema("CREATE INDEX IF NOT EXISTS idx_windows_session_id ON windows(session_id);")
        runSchema("CREATE INDEX IF NOT EXISTS idx_windows_pid_tty ON windows(pid, tty);")
        runSchema("CREATE INDEX IF NOT EXISTS idx_windows_last_seen ON windows(updated_at);")
        // Migration: add completed_at column if missing (existing databases)
        runSchema("ALTER TABLE windows ADD COLUMN completed_at REAL;")

        // Migration: 如果旧表 PK 是 (pid, tty)，重建为 (window_id)
        migrateWindowsPKIfNeeded()
        log("[WindowStateStore] tables created/verified")
    }

    // MARK: - PK Migration

    /// 检测旧表 PK 是否为 (pid, tty)，如果是则重建为 (window_id)
    private func migrateWindowsPKIfNeeded() {
        guard let db else { return }

        var stmt: OpaquePointer?
        let pkSQL = "PRAGMA table_info('windows');"
        guard sqlite3_prepare_v2(db, pkSQL, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var pkColumns: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let pkFlag = sqlite3_column_int(stmt, 5)
            if pkFlag > 0 {
                if let name = sqlite3_column_text(stmt, 1) {
                    pkColumns.append(String(cString: name))
                }
            }
        }
        sqlite3_finalize(stmt)
        stmt = nil

        if pkColumns == ["window_id"] {
            log("[WindowStateStore] windows table PK is correct (window_id)")
            return
        }

        log("[WindowStateStore] MIGRATING windows table PK from (\(pkColumns.joined(separator: ", "))) to (window_id)", level: .warn)

        let newTable = "windows_v2"
        let createSQL = """
            CREATE TABLE \(newTable) (
                window_id INTEGER NOT NULL PRIMARY KEY,
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
                completed_at REAL
            );
            """

        if sqlite3_exec(db, createSQL, nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            log("[WindowStateStore] migrate: create new table failed: \(msg)", level: .error)
            return
        }

        let copySQL = """
            INSERT OR IGNORE INTO \(newTable)
                SELECT window_id, pid, tty, ax_window_number, app_name, bundle_id, title,
                       term_session_id, iterm_session_id, kitty_window_id, wezterm_pane, env_window_id,
                       session_id, cwd, model,
                       orig_x, orig_y, orig_w, orig_h,
                       target_x, target_y, target_w, target_h,
                       source_space, source_display, source_yabai_disp, source_disp_space,
                       target_display, toggle_reason, toggled_at,
                       is_completed, created_at, updated_at, completed_at
                FROM windows;
            """
        if sqlite3_exec(db, copySQL, nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            log("[WindowStateStore] migrate: copy data failed: \(msg)", level: .error)
            sqlite3_exec(db, "DROP TABLE IF EXISTS \(newTable);", nil, nil, nil)
            return
        }

        let copiedRows = sqlite3_changes(db)

        sqlite3_exec(db, "DROP TABLE windows;", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE \(newTable) RENAME TO windows;", nil, nil, nil)

        runSchema("CREATE INDEX IF NOT EXISTS idx_windows_session_id ON windows(session_id);")
        runSchema("CREATE INDEX IF NOT EXISTS idx_windows_pid_tty ON windows(pid, tty);")
        runSchema("CREATE INDEX IF NOT EXISTS idx_windows_last_seen ON windows(updated_at);")

        log("[WindowStateStore] migrate: copied \(copiedRows) rows, PK now (window_id)")
    }

    private func cleanupLegacyTables() {
        // session_bindings 已废弃：清理所有数据
        runSchema("DELETE FROM session_bindings;")
        // window_states 保留给 WindowManager+State 使用，但清理超过 1 小时的旧记录
        let cutoff = Date().addingTimeInterval(-3600).timeIntervalSince1970
        var stmt: OpaquePointer?
        let sql = "DELETE FROM window_states WHERE saved_at < ?;"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_step(stmt)
            let removed = sqlite3_changes(db)
            sqlite3_finalize(stmt)
            if removed > 0 {
                log("[WindowStateStore] cleanupLegacyTables: removed \(removed) old window_states rows")
            }
        }
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
            log("[WindowStateStore] saveWindowState (windows table) failed: \(errMsg)", level: .error)
        } else {
            let srcSp: String = if let v = state.sourceSpace { String(v) } else { "nil" }
            let tgtDsp: String = if let v = state.targetDisplay { String(v) } else { "nil" }
            let oX: String = if let v = state.origX { String(describing: v) } else { "nil" }
            let tX: String = if let v = state.targetX { String(describing: v) } else { "nil" }
            let sid: String = if let v = state.sessionID { String(v.prefix(8)) } else { "nil" }
            log("[WindowStateStore] saveWindowState OK wid=\(state.windowID) pid=\(state.pid) tty=\(state.tty ?? "") origX=\(oX) targetX=\(tX) srcSpace=\(srcSp) tgtDisp=\(tgtDsp) sid=\(sid)")
        }
    }

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

    func deleteWindowState(windowID: UInt32) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = "DELETE FROM windows WHERE window_id = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(windowID))
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

    // MARK: - ToggleRecord (Single Source of Truth)

    /// 原子性保存 toggle record 到 windows 表
    func saveToggleRecord(_ record: ToggleRecord) {
        guard let db else {
            log("saveToggleRecord: db is nil", level: .error)
            return
        }
        let now = Date().timeIntervalSince1970
        var stmt: OpaquePointer?

        let sql = """
            UPDATE windows SET
                orig_x = ?, orig_y = ?, orig_w = ?, orig_h = ?,
                target_x = ?, target_y = ?, target_w = ?, target_h = ?,
                source_space = ?, source_display = ?,
                source_yabai_disp = ?, source_disp_space = ?,
                target_display = ?,
                toggle_reason = 'manual_hotkey',
                toggled_at = ?,
                session_id = ?,
                updated_at = ?
            WHERE window_id = ?
        """

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log("saveToggleRecord prepare failed", level: .error, fields: [
                "error": String(cString: sqlite3_errmsg(db))
            ])
            return
        }

        sqlite3_bind_double(stmt, 1, Double(record.origFrame.origin.x))
        sqlite3_bind_double(stmt, 2, Double(record.origFrame.origin.y))
        sqlite3_bind_double(stmt, 3, Double(record.origFrame.size.width))
        sqlite3_bind_double(stmt, 4, Double(record.origFrame.size.height))
        sqlite3_bind_double(stmt, 5, Double(record.targetFrame.origin.x))
        sqlite3_bind_double(stmt, 6, Double(record.targetFrame.origin.y))
        sqlite3_bind_double(stmt, 7, Double(record.targetFrame.size.width))
        sqlite3_bind_double(stmt, 8, Double(record.targetFrame.size.height))
        sqlite3_bind_int(stmt, 9, Int32(record.sourceSpace))
        sqlite3_bind_int(stmt, 10, Int32(record.sourceDisplay))
        sqlite3_bind_int(stmt, 11, Int32(record.sourceYabaiDisp))
        sqlite3_bind_int(stmt, 12, Int32(record.sourceDispSpace))
        sqlite3_bind_int(stmt, 13, Int32(record.targetDisplay))
        sqlite3_bind_double(stmt, 14, record.toggledAt.timeIntervalSince1970)
        if let sid = record.sessionID, !sid.isEmpty {
            sqlite3_bind_text(stmt, 15, sid, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 15)
        }
        sqlite3_bind_double(stmt, 16, now)
        sqlite3_bind_int64(stmt, 17, Int64(record.windowID))

        let result = sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        if result != SQLITE_DONE {
            log("saveToggleRecord failed", level: .error, fields: [
                "error": String(cString: sqlite3_errmsg(db)),
                "windowID": String(record.windowID)
            ])
            return
        }

        log("saveToggleRecord saved", level: .info, fields: [
            "windowID": String(record.windowID),
            "sourceSpace": String(record.sourceSpace),
            "sourceDisplay": String(record.sourceDisplay),
            "sourceYabaiDisp": String(record.sourceYabaiDisp),
            "sourceDispSpace": String(record.sourceDispSpace),
            "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y))",
            "targetFrame": "\(Int(record.targetFrame.origin.x)),\(Int(record.targetFrame.origin.y))"
        ])
    }

    /// 按 windowID 读取 toggle record
    func loadToggleRecord(windowID: UInt32) -> ToggleRecord? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let sql = """
            SELECT window_id, pid, bundle_id, app_name,
                   orig_x, orig_y, orig_w, orig_h,
                   target_x, target_y, target_w, target_h,
                   source_space, source_display, source_yabai_disp, source_disp_space,
                   target_display, toggled_at, session_id
            FROM windows
            WHERE window_id = ? AND toggle_reason IS NOT NULL AND orig_x IS NOT NULL
        """

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(windowID))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let wID = UInt32(sqlite3_column_int64(stmt, 0))
        let pid = sqlite3_column_int(stmt, 1)
        let bundleID: String? = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
        let appName: String? = sqlite3_column_text(stmt, 3).map { String(cString: $0) }

        let ox = CGFloat(sqlite3_column_double(stmt, 4))
        let oy = CGFloat(sqlite3_column_double(stmt, 5))
        let ow = CGFloat(sqlite3_column_double(stmt, 6))
        let oh = CGFloat(sqlite3_column_double(stmt, 7))
        let tx = CGFloat(sqlite3_column_double(stmt, 8))
        let ty = CGFloat(sqlite3_column_double(stmt, 9))
        let tw = CGFloat(sqlite3_column_double(stmt, 10))
        let th = CGFloat(sqlite3_column_double(stmt, 11))

        let sourceSpace = Int(sqlite3_column_int(stmt, 12))
        let sourceDisplay = Int(sqlite3_column_int(stmt, 13))
        let sourceYabaiDisp = Int(sqlite3_column_int(stmt, 14))
        let sourceDispSpace = Int(sqlite3_column_int(stmt, 15))
        let targetDisplay = Int(sqlite3_column_int(stmt, 16))
        let toggledAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 17))
        let sessionID: String? = sqlite3_column_text(stmt, 18).map { String(cString: $0) }

        return ToggleRecord(
            windowID: wID, pid: pid,
            bundleIdentifier: bundleID, appName: appName,
            origFrame: CGRect(x: ox, y: oy, width: ow, height: oh),
            sourceSpace: sourceSpace, sourceDisplay: sourceDisplay,
            sourceYabaiDisp: sourceYabaiDisp, sourceDispSpace: sourceDispSpace,
            targetFrame: CGRect(x: tx, y: ty, width: tw, height: th),
            targetDisplay: targetDisplay,
            toggledAt: toggledAt, sessionID: sessionID
        )
    }

    /// 清除指定窗口的 toggle state
    func clearToggleRecord(windowID: UInt32) {
        guard let db else { return }
        let sql = """
            UPDATE windows SET
                orig_x = NULL, orig_y = NULL, orig_w = NULL, orig_h = NULL,
                target_x = NULL, target_y = NULL, target_w = NULL, target_h = NULL,
                source_space = NULL, source_display = NULL,
                source_yabai_disp = NULL, source_disp_space = NULL,
                target_display = NULL,
                toggle_reason = NULL, toggled_at = NULL,
                updated_at = ?
            WHERE window_id = ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 2, Int64(windowID))
        sqlite3_step(stmt)
        log("clearToggleRecord cleared", fields: ["windowID": String(windowID)])
    }

    // MARK: - Row Parser

    private func parseWindowStateRow(_ stmt: OpaquePointer) -> WindowState? {
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

    private func optionalStringCol(_ stmt: OpaquePointer, col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        let raw = String(cString: sqlite3_column_text(stmt, col))
        return raw.isEmpty ? nil : raw
    }
}
