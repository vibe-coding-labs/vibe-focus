import Foundation
import Csqlite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

@MainActor
final class WindowStateStore {
    static let shared = WindowStateStore()

    var db: OpaquePointer?
    let dbPath: String

    init(dbPath: String? = nil) {
        if let dbPath {
            self.dbPath = dbPath
        } else {
            let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".vibefocus")
            if !FileManager.default.fileExists(atPath: dir) {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            self.dbPath = (dir as NSString).appendingPathComponent("vibefocus.db")
        }
        openDatabase()
        createTables()
    }
}

extension WindowStateStore {
    // MARK: - Database Setup

    func openDatabase() {
        // P-INST-168: 数据库打开耗时（sqlite3_open 连接 + PRAGMA journal_mode=WAL prepare/step/finalize；启动路径单次调用，WAL 模式设置）。
        let odStart = Date()
        defer {
            let ms = elapsedMilliseconds(since: odStart)
            if ms >= 5 { log("[WindowStateStore] openDatabase slow", level: .warn, fields: ["durationMs": String(ms)]) }
        }
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
        // P-INST-169: schema 执行耗时（sqlite3_exec DDL + sqlite3_errmsg；createTables 启动建表/索引/迁移调用，每次 schema 语句一次）。
        let rsStart = Date()
        defer {
            let ms = elapsedMilliseconds(since: rsStart)
            if ms >= 5 { log("[WindowStateStore] runSchema slow", level: .warn, fields: ["durationMs": String(ms)]) }
        }
        guard let db else { return }
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            log("[WindowStateStore] schema error: \(msg)", level: .error)
        }
    }

    func createTables() {
        // P-INST-170: 建表/迁移编排耗时（5x runSchema P-INST-169 CREATE TABLE/INDEX/ALTER + columnExists P-INST-172 + migrateWindowsPKIfNeeded P-INST-171；启动路径单次调用，DDL 全量执行）。
        let ctStart = Date()
        defer {
            let ms = elapsedMilliseconds(since: ctStart)
            if ms >= 5 { log("[WindowStateStore] createTables slow", level: .warn, fields: ["durationMs": String(ms)]) }
        }
        // windows 宽表：统一会话绑定 + toggle 状态
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

        // preferences 表：key-value 持久化（不受 app rebuild 影响）
        runSchema("""
            CREATE TABLE IF NOT EXISTS preferences (
                key TEXT NOT NULL PRIMARY KEY,
                value TEXT NOT NULL,
                updated_at REAL NOT NULL
            );
            """)

        // Migration: 如果旧表 PK 是 (pid, tty)，重建为 (window_id)
        migrateWindowsPKIfNeeded()
        log("[WindowStateStore] tables created/verified")
    }

    // MARK: - PK Migration

    /// 检测旧表 PK 是否为 (pid, tty)，如果是则重建为 (window_id)
    func migrateWindowsPKIfNeeded() {
        // P-INST-171: windows 表 PK 迁移耗时（PRAGMA table_info prepare/step 读 PK 列 + 必要时 CREATE windows_v2 + INSERT SELECT + DROP/RENAME；createTables 启动调用，迁移路径含多步 DDL）。
        let mpStart = Date()
        defer {
            let ms = elapsedMilliseconds(since: mpStart)
            if ms >= 5 { log("[WindowStateStore] migrateWindowsPKIfNeeded slow", level: .warn, fields: ["durationMs": String(ms)]) }
        }
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

    // MARK: - Preference Persistence (SQLite key-value store)

    func savePreference(key: String, value: String) {
        guard let db else { return }
        // P-INST-69: 偏好写 SQLite 耗时（ScreenIndexPreferences didSet 触发；低频但为完整性覆盖所有 SQLite 公开方法；WAL 写通常 <1ms，≥5ms 异常）。
        let spStart = Date()
        defer {
            let ms = elapsedMilliseconds(since: spStart)
            if ms >= 5 { log("[WindowStateStore] savePreference slow", level: .warn, fields: ["key": key, "durationMs": String(ms)]) }
        }
        let sql = "INSERT OR REPLACE INTO preferences (key, value, updated_at) VALUES (?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log("[WindowStateStore] savePreference prepare failed", level: .warn, fields: ["key": key])
            return
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            log("[WindowStateStore] savePreference step failed", level: .warn, fields: ["key": key])
            return
        }
    }

    func loadPreference(key: String) -> String? {
        guard let db else { return nil }
        // P-INST-69: 偏好读 SQLite 耗时（ScreenIndexPreferences init 触发，启动路径；WAL 读通常 <1ms，≥5ms 异常）。
        let lpStart = Date()
        var found = false
        defer {
            let ms = elapsedMilliseconds(since: lpStart)
            if ms >= 5 { log("[WindowStateStore] loadPreference slow", level: .warn, fields: ["key": key, "found": String(found), "durationMs": String(ms)]) }
        }
        let sql = "SELECT value FROM preferences WHERE key = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        found = true
        guard let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }

    // MARK: - Schema Helpers

    /// 检查表中是否存在指定列（用于安全的 migration）
    private func columnExists(table: String, column: String) -> Bool {
        // P-INST-172: 列存在性检查耗时（PRAGMA table_info prepare/step/finalize 扫列名；createTables 迁移判断调用）。
        let ceStart = Date()
        defer {
            let ms = elapsedMilliseconds(since: ceStart)
            if ms >= 5 { log("[WindowStateStore] columnExists slow", level: .warn, fields: ["table": table, "column": column, "durationMs": String(ms)]) }
        }
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
