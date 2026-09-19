import Foundation
import Csqlite3
@testable import VibeFocusKit

// Tests/Runner/RunnerAuditLoggerTests.swift — B216：AuditLogger 记账链真身直测
// （record 缓冲/flush 批量写/pid-session-details 三列 nil 分支/50 条自动 trim/积压看门）。
// 注入缝 init(db:) + WindowStateStore(dbPath:) 定向隔离 DB，断言直查 window_audit_log 表。

extension RunnerHarness {
    /// 直查审计表行数与字段（store.db 真指针，@testable 可见）
    private func auditQuery(_ db: OpaquePointer?, _ sql: String) -> (Int, String?, String?) {
        guard let db else { return (-1, nil, nil) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (-2, nil, nil) }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (-3, nil, nil) }
        let count = Int(sqlite3_column_int64(stmt, 0))
        let c1 = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
        let c2 = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
        return (count, c1, c2)
    }

    func runAuditLoggerTests() {
        do {
            let dir = "/tmp/vibefocus-audit-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let store = WindowStateStore(dbPath: dir + "/audit.db")
            let logger = AuditLogger(db: store.db)

            // ===== record 缓冲 + flush 批量落库 =====
            logger.record(eventType: "toggle", windowID: 7, pid: 42, sessionID: "sess-a",
                          details: ["reason": "manual_hotkey"])
            logger.record(eventType: "restore", windowID: 7)   // pid/sessionID/details 全 nil 分支
            logger.record(eventType: "session_bind", windowID: 9, sessionID: "")  // 空 sessionID → NULL 分支
            logger.flushPendingEvents()
            let (n1, d1, _) = auditQuery(store.db,
                "SELECT COUNT(*), details, NULL FROM window_audit_log WHERE event_type='toggle'")
            check("audit: flush 后事件落库", n1 == 1)
            check("audit: details JSON 落库", d1?.contains("manual_hotkey") == true)
            let (_, pidCol, sidCol) = auditQuery(store.db,
                "SELECT COUNT(*), pid, session_id FROM window_audit_log WHERE event_type='restore'")
            check("audit: 全 nil 字段落 NULL", pidCol == nil && sidCol == nil)
            let (_, _, emptySid) = auditQuery(store.db,
                "SELECT COUNT(*), NULL, session_id FROM window_audit_log WHERE event_type='session_bind'")
            check("audit: 空 sessionID → NULL（不落空串）", emptySid == nil)

            // ===== 空 flush no-op（guard !events.isEmpty 分支） =====
            logger.flushPendingEvents()
            let (n2, _, _) = auditQuery(store.db, "SELECT COUNT(*), NULL, NULL FROM window_audit_log")
            check("audit: 空 flush 不增行", n2 == 3)

            // ===== 50 条单批 flush → insertCount 触发周期 trimOldRecords（覆盖 trim 调用链） =====
            for i in 0..<50 {
                logger.record(eventType: "bulk", windowID: UInt32(100 + i))
            }
            logger.flushPendingEvents()
            let (n3, _, _) = auditQuery(store.db, "SELECT COUNT(*), NULL, NULL FROM window_audit_log")
            check("audit: 50 条批量落库+周期 trim 触发不丢行", n3 == 53)

            // ===== trimOldRecords 手动调用（保留最近 maxRecords 条的 DELETE 路径） =====
            logger.trimOldRecords()
            let (n4, _, _) = auditQuery(store.db, "SELECT COUNT(*), NULL, NULL FROM window_audit_log")
            check("audit: trim 后行数不减（远小于 maxRecords）", n4 == 53)

            // ===== B194 积压看门：50+ 条未 flush → ERROR 留证路径（事件不丢） =====
            for _ in 0..<AuditLogger.backlogWarnThreshold {
                logger.record(eventType: "backlog", windowID: 1)
            }
            logger.flushPendingEvents()
            let (n5, _, _) = auditQuery(store.db,
                "SELECT COUNT(*), NULL, NULL FROM window_audit_log WHERE event_type='backlog'")
            check("audit: 积压看门触发路径事件仍全落库", n5 == AuditLogger.backlogWarnThreshold)
        }
    }
}
