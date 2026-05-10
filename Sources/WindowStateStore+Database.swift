import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
import SQLite3
import SQLite3

extension WindowStateStore {
    // MARK: - Database Setup

    func openDatabase() {
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

    func runSchema(_ sql: String) {
        guard let db else { return }
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            log("[WindowStateStore] schema error: \(msg)", level: .error)
        }
    }

    func createTables() {
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
        if !columnExists(table: "windows", column: "completed_at") {
            runSchema("ALTER TABLE windows ADD COLUMN completed_at REAL;")
        }

        // Migration: 如果旧表 PK 是 (pid, tty)，重建为 (window_id)
        migrateWindowsPKIfNeeded()
        log("[WindowStateStore] tables created/verified")
    }

    // MARK: - PK Migration

    /// 检测旧表 PK 是否为 (pid, tty)，如果是则重建为 (window_id)
    func migrateWindowsPKIfNeeded() {
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

    func cleanupLegacyTables() {
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

    // MARK: - Schema Helpers

    /// 检查表中是否存在指定列（用于安全的 migration）
    private func columnExists(table: String, column: String) -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info('\(table)');"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1) {
                if String(cString: name) == column { return true }
            }
        }
        return false
    }

}
