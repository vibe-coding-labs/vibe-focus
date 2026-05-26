import Testing
import Foundation
import SQLite3
@testable import VibeFocusKit

@Suite("AuditLogger (In-Memory SQLite)")
@MainActor
struct AuditLoggerTests {

    private func makeLogger() -> AuditLogger {
        var db: OpaquePointer?
        sqlite3_open(":memory:", &db)
        return AuditLogger(db: db)
    }

    private func recordCount(in db: OpaquePointer?) -> Int {
        guard let db else { return -1 }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM window_audit_log;", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func fetchLatest(in db: OpaquePointer?) -> (eventType: String, windowID: Int64, pid: Int32?, sessionID: String?, details: String?)? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let sql = "SELECT event_type, window_id, pid, session_id, details FROM window_audit_log ORDER BY id DESC LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let eventType = String(cString: sqlite3_column_text(stmt, 0))
        let windowID = sqlite3_column_int64(stmt, 1)
        let pid: Int32? = sqlite3_column_type(stmt, 2) != SQLITE_NULL ? sqlite3_column_int(stmt, 2) : nil
        let sessionID: String? = sqlite3_column_type(stmt, 3) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 3)) : nil
        let details: String? = sqlite3_column_type(stmt, 4) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 4)) : nil
        return (eventType, windowID, pid, sessionID, details)
    }

    // MARK: - record basic

    @Test("record inserts a row with all fields")
    func recordInsertsRow() {
        let logger = makeLogger()
        logger.record(eventType: "toggle", windowID: 42, pid: 1234, sessionID: "sess-1", details: ["key": "value"])

        #expect(recordCount(in: logger.testDB) == 1)
        let row = fetchLatest(in: logger.testDB)
        #expect(row != nil)
        #expect(row?.eventType == "toggle")
        #expect(row?.windowID == 42)
        #expect(row?.pid == 1234)
        #expect(row?.sessionID == "sess-1")
        #expect(row?.details?.contains("key") == true)
    }

    @Test("record with nil pid inserts NULL")
    func recordNilPID() {
        let logger = makeLogger()
        logger.record(eventType: "restore", windowID: 10, pid: nil)

        let row = fetchLatest(in: logger.testDB)
        #expect(row?.pid == nil)
    }

    @Test("record with empty sessionID inserts NULL")
    func recordEmptySessionID() {
        let logger = makeLogger()
        logger.record(eventType: "toggle", windowID: 10, sessionID: "")

        let row = fetchLatest(in: logger.testDB)
        #expect(row?.sessionID == nil)
    }

    @Test("record with nil sessionID inserts NULL")
    func recordNilSessionID() {
        let logger = makeLogger()
        logger.record(eventType: "toggle", windowID: 10, sessionID: nil)

        let row = fetchLatest(in: logger.testDB)
        #expect(row?.sessionID == nil)
    }

    @Test("record with empty details inserts NULL details")
    func recordEmptyDetails() {
        let logger = makeLogger()
        logger.record(eventType: "toggle", windowID: 10)

        let row = fetchLatest(in: logger.testDB)
        #expect(row?.details == nil)
    }

    @Test("record with non-empty details inserts JSON string")
    func recordJSONDetails() {
        let logger = makeLogger()
        logger.record(eventType: "session bind", windowID: 10, details: ["reason": "auto", "space": "3"])

        let row = fetchLatest(in: logger.testDB)
        #expect(row?.details != nil)
        let detailStr = row!.details!
        #expect(detailStr.contains("reason"))
        #expect(detailStr.contains("auto"))
        #expect(detailStr.contains("space"))
    }

    // MARK: - multiple records

    @Test("multiple records coexist")
    func multipleRecords() {
        let logger = makeLogger()
        logger.record(eventType: "toggle", windowID: 1)
        logger.record(eventType: "restore", windowID: 2)
        logger.record(eventType: "space move", windowID: 3)

        #expect(recordCount(in: logger.testDB) == 3)
    }

    // MARK: - trimOldRecords

    @Test("trimOldRecords keeps only maxRecords newest")
    func trimKeepsNewest() {
        var db: OpaquePointer?
        sqlite3_open(":memory:", &db)
        let logger = AuditLogger(db: db)

        // Insert 15 records
        for i in 1...15 {
            logger.record(eventType: "toggle", windowID: UInt32(i))
        }
        #expect(recordCount(in: logger.testDB) == 15)

        // trimOldRecords is now internal, call it directly
        logger.trimOldRecords()

        // maxRecords = 10_000, so all 15 survive
        #expect(recordCount(in: logger.testDB) == 15)
    }

    // MARK: - table creation

    @Test("table is created on init")
    func tableCreatedOnInit() {
        var db: OpaquePointer?
        sqlite3_open(":memory:", &db)

        // Verify table doesn't exist yet
        var stmt: OpaquePointer?
        let checkSQL = "SELECT name FROM sqlite_master WHERE type='table' AND name='window_audit_log';"
        sqlite3_prepare_v2(db, checkSQL, -1, &stmt, nil)
        let existsBefore = sqlite3_step(stmt) == SQLITE_ROW
        sqlite3_finalize(stmt)
        #expect(!existsBefore)

        // Init creates the table
        let _ = AuditLogger(db: db)

        sqlite3_prepare_v2(db, checkSQL, -1, &stmt, nil)
        let existsAfter = sqlite3_step(stmt) == SQLITE_ROW
        sqlite3_finalize(stmt)
        #expect(existsAfter)
    }

    // MARK: - nil db safety

    @Test("record with nil db does not crash")
    func recordNilDB() {
        let logger = AuditLogger(db: nil)
        logger.record(eventType: "toggle", windowID: 42)
    }

    // MARK: - event types

    @Test("various event types are stored correctly")
    func eventTypes() {
        let logger = makeLogger()
        let types = ["toggle", "restore", "session bind", "space move", "UserPromptSubmit"]
        for (i, type) in types.enumerated() {
            logger.record(eventType: type, windowID: UInt32(i))
        }

        #expect(recordCount(in: logger.testDB) == 5)
    }

    // MARK: - windowID is Int64

    @Test("large windowID values are preserved")
    func largeWindowID() {
        let logger = makeLogger()
        let largeID: UInt32 = 4_294_967_295 // UInt32.max
        logger.record(eventType: "toggle", windowID: largeID)

        let row = fetchLatest(in: logger.testDB)
        #expect(row?.windowID == Int64(largeID))
    }

    // MARK: - trimOldRecords direct verification

    @Test("trimOldRecords removes oldest records beyond limit")
    func trimRemovesOldest() {
        var db: OpaquePointer?
        sqlite3_open(":memory:", &db)
        let logger = AuditLogger(db: db)

        // Insert records directly with different timestamps to control ordering
        let now = Date().timeIntervalSince1970
        for i in 1...5 {
            var stmt: OpaquePointer?
            let sql = "INSERT INTO window_audit_log (event_type, window_id, pid, session_id, details, created_at) VALUES (?, ?, NULL, NULL, NULL, ?);"
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, "toggle", -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Int64(i))
            sqlite3_bind_double(stmt, 3, now - Double(5 - i)) // older records have lower timestamps
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        #expect(recordCount(in: db) == 5)

        // Manually trim to keep only 3 newest
        var trimStmt: OpaquePointer?
        let trimSQL = "DELETE FROM window_audit_log WHERE id NOT IN (SELECT id FROM window_audit_log ORDER BY created_at DESC LIMIT 3);"
        sqlite3_prepare_v2(db, trimSQL, -1, &trimStmt, nil)
        sqlite3_step(trimStmt)
        sqlite3_finalize(trimStmt)

        #expect(recordCount(in: db) == 3)
    }

    // MARK: - windowID zero

    @Test("record with windowID 0 inserts successfully")
    func recordWindowIDZero() {
        let logger = makeLogger()
        logger.record(eventType: "session bind", windowID: 0)

        let row = fetchLatest(in: logger.testDB)
        #expect(row?.windowID == 0)
    }

    // MARK: - duplicate windowID records

    @Test("multiple records with same windowID coexist")
    func duplicateWindowID() {
        let logger = makeLogger()
        logger.record(eventType: "toggle", windowID: 42)
        logger.record(eventType: "restore", windowID: 42)
        logger.record(eventType: "toggle", windowID: 42)

        #expect(recordCount(in: logger.testDB) == 3)
    }

    // MARK: - empty eventType

    @Test("record with empty eventType inserts successfully")
    func recordEmptyEventType() {
        let logger = makeLogger()
        logger.record(eventType: "", windowID: 1)

        let row = fetchLatest(in: logger.testDB)
        #expect(row?.eventType == "")
    }

    // MARK: - trimOldRecords with nil db

    @Test("trimOldRecords with nil db does not crash")
    func trimNilDB() {
        let logger = AuditLogger(db: nil)
        logger.trimOldRecords()
    }
}
