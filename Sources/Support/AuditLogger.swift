import Foundation
import SQLite3

/// 窗口变更审计日志服务
/// 记录所有窗口状态变更（toggle、restore、session bind、space move、UserPromptSubmit）
/// 自动清理超过 maxRecords 条的旧记录
@MainActor
final class AuditLogger {
    static let shared = AuditLogger()

    private let maxRecords: Int = 10_000
    private var insertCount: Int = 0
    private let cleanupInterval: Int = 50

    private let _injectedDB: OpaquePointer?
    private var db: OpaquePointer? { _injectedDB ?? WindowStateStore.shared.db }

    init(db: OpaquePointer? = nil) {
        _injectedDB = db
        createTable()
    }

    // MARK: - Table Setup

    private func createTable() {
        guard let db else { return }
        let sql = """
            CREATE TABLE IF NOT EXISTS window_audit_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                event_type TEXT NOT NULL,
                window_id INTEGER NOT NULL,
                pid INTEGER,
                session_id TEXT,
                details TEXT,
                created_at REAL NOT NULL
            );
            """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            log("[AuditLogger] createTable failed: \(msg)", level: .error)
        }
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_audit_window_id ON window_audit_log(window_id);", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_audit_created_at ON window_audit_log(created_at);", nil, nil, nil)
    }

    // MARK: - Record

    func record(
        eventType: String,
        windowID: UInt32,
        pid: Int32? = nil,
        sessionID: String? = nil,
        details: [String: String] = [:]
    ) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = """
            INSERT INTO window_audit_log (event_type, window_id, pid, session_id, details, created_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            log("[AuditLogger] insert prepare failed: \(msg)", level: .error)
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, eventType, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, Int64(windowID))
        if let pid {
            sqlite3_bind_int(stmt, 3, pid)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        if let sessionID, !sessionID.isEmpty {
            sqlite3_bind_text(stmt, 4, sessionID, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        if !details.isEmpty,
           let jsonData = try? JSONSerialization.data(withJSONObject: details),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            sqlite3_bind_text(stmt, 5, jsonStr, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)

        if sqlite3_step(stmt) != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            log("[AuditLogger] insert failed: \(msg)", level: .error)
            return
        }

        insertCount += 1
        if insertCount >= cleanupInterval {
            insertCount = 0
            trimOldRecords()
        }
    }

    // MARK: - Cleanup

    func trimOldRecords() {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = """
            DELETE FROM window_audit_log WHERE id NOT IN (
                SELECT id FROM window_audit_log ORDER BY created_at DESC LIMIT ?
            );
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(maxRecords))
        sqlite3_step(stmt)
    }

    /// Test-only accessor for the injected database pointer
    var testDB: OpaquePointer? { db }
}
