import Foundation
import Csqlite3
@testable import VibeFocusKit

// Tests/Runner/RunnerAuditLoggerTests.swift — B214 审计日志覆盖补强
// 靶：Sources/Support/AuditLogger.swift（基线 20%）。
// 全程走 init(db:) 注入缝（临时目录独立 SQLite 文件），绝不触碰
// WindowStateStore.shared 真身库；record 的防抖调度闭包不依赖主 RunLoop，
// 断言一律走同步 flushPendingEvents（internal 测试缝）。

extension RunnerHarness {
    /// 临时目录独立库 + 注入式 AuditLogger（每个用例组独立，互不串扰）
    private func makeAuditFixture(_ tag: String) -> (AuditLogger, OpaquePointer?, String) {
        let dir = NSTemporaryDirectory() + "ut100-audit-\(tag)-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = WindowStateStore(dbPath: dir + "/audit.db")
        return (AuditLogger(db: store.db), store.db, dir)
    }

    private func auditScalar(_ db: OpaquePointer?, _ sql: String) -> String? {
        var stmt: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
    }

    private func auditColumnIsNull(_ db: OpaquePointer?, _ sql: String) -> Bool {
        var stmt: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return true }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return true }
        return sqlite3_column_type(stmt, 0) == SQLITE_NULL
    }

    private func auditRowCount(_ db: OpaquePointer?) -> Int {
        Int(auditScalar(db, "SELECT COUNT(*) FROM window_audit_log") ?? "0") ?? 0
    }

    func runAuditLoggerCoverageTests() {
        // A. record 缓冲语义 + flush 批量落库 + 字段保真（含 NULL 域）
        do {
            let (logger, db, _) = makeAuditFixture("a")
            check("audit A0: 夹具库已打开", db != nil)

            logger.record(eventType: "toggle", windowID: 11, pid: 100,
                          sessionID: "sess-1", details: ["k": "v"])
            logger.record(eventType: "restore", windowID: 12)
            logger.record(eventType: "bind", windowID: 13, sessionID: "")
            check("audit A1: record 只入缓冲不落库（防抖承诺）", auditRowCount(db) == 0)

            logger.flushPendingEvents()
            check("audit A2: flush 批量落库 3 行", auditRowCount(db) == 3)
            logger.flushPendingEvents()
            check("audit A3: 缓冲已空再 flush 幂等（guard events.isEmpty）", auditRowCount(db) == 3)

            check("audit A4: pid/session/details 全保真（JSON 序列化）",
                  auditScalar(db, "SELECT pid FROM window_audit_log WHERE window_id=11") == "100"
                  && auditScalar(db, "SELECT session_id FROM window_audit_log WHERE window_id=11") == "sess-1"
                  && auditScalar(db, "SELECT details FROM window_audit_log WHERE window_id=11")?
                      .contains("\"k\"") == true)
            check("audit A5: 全缺省 → pid/session_id/details 三列 NULL",
                  auditColumnIsNull(db, "SELECT pid FROM window_audit_log WHERE window_id=12")
                  && auditColumnIsNull(db, "SELECT session_id FROM window_audit_log WHERE window_id=12")
                  && auditColumnIsNull(db, "SELECT details FROM window_audit_log WHERE window_id=12"))
            check("audit A6: 空 sessionID 走 bind_null（非空串入库）",
                  auditColumnIsNull(db, "SELECT session_id FROM window_audit_log WHERE window_id=13"))
        }

        // B. 积压看门：>50 条未 flush 不丢不崩（B194 事故防回归哨兵行为域）
        do {
            let (logger, db, _) = makeAuditFixture("b")
            for i in 0..<55 { logger.record(eventType: "bulk", windowID: UInt32(i + 1)) }
            logger.flushPendingEvents()
            check("audit B1: 积压 55 条全部落地（一条不丢）", auditRowCount(db) == 55)
        }

        // C. trimOldRecords：阈值内保留全部（DELETE LIMIT ? 语义）
        do {
            let (logger, db, _) = makeAuditFixture("c")
            logger.record(eventType: "keep", windowID: 1)
            logger.record(eventType: "keep", windowID: 2)
            logger.flushPendingEvents()
            logger.trimOldRecords()
            check("audit C1: 行数低于 maxRecords 时 trim 不删", auditRowCount(db) == 2)
        }

        // D. 容量治理实弹：10050 条 → 自动裁剪收敛到 maxRecords=10000
        //    （insertCount 每 50 条触发一次 trimOldRecords 的内部计数路径同批覆盖）
        do {
            let (logger, db, _) = makeAuditFixture("d")
            logger.record(eventType: "flood", windowID: 0)
            logger.flushPendingEvents()
            for chunk in 0..<201 {
                for i in 0..<50 {
                    logger.record(eventType: "flood", windowID: UInt32(chunk * 50 + i + 1))
                }
                logger.flushPendingEvents()
            }
            // 收敛语义：每 50 条插入触发一次裁剪（DELETE 保留最新 10000），故终态 =
            // maxRecords + 本清理周期内未触发的余量——有界，而非恒等于 10000。
            let flooded = auditRowCount(db)
            check("audit D1: 写入超限后收敛在 maxRecords~maxRecords+清理周期内",
                  (10_000...10_049).contains(flooded))
        }
    }
}
