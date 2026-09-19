import Foundation
import Csqlite3
@testable import VibeFocusKit

// Tests/Runner/RunnerAuditLoggerTests.swift — B214/B216 双线合并（add/add 冲突裁决）：
// B216 线（runAuditLoggerTests）与本线（runAuditLoggerCoverageTests）各自独立直测
// 同一注入缝 init(db:)+临时独立库，方法与辅助名零重叠故共存；
// 重复断言保留（审计是 B194 事故域，双作者交叉验证价值高于行数精简）。

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

// MARK: - B229 追加线：:memory: 纯内存注入直测（与本文件上方 store.db 注入互为交叉验证；
// 方法名避让上方的 runAuditLoggerTests——调度/积压/裁剪/坏连接分支由本块锁定）

extension RunnerHarness {
    func runAuditLoggerPureMemoryTests() {
        var db: OpaquePointer?
        sqlite3_open(":memory:", &db)
        defer { sqlite3_close(db) }
        let logger = AuditLogger(db: db)

        // 1. init 建表：注入连接上真实 CREATE TABLE 生效
        check("auditPM: 注入连接建表成功（表可查询）",
              sqlite3_exec(db, "SELECT 1 FROM window_audit_log LIMIT 1", nil, nil, nil) == SQLITE_OK)

        // 2. record 只入内存缓冲不落库（flush 前表空）
        logger.record(eventType: "toggle", windowID: 7, pid: 123, sessionID: "sess-1", details: ["k": "v"])
        check("auditPM: record 只入缓冲不落库",
              scalarInt(db, "SELECT COUNT(*) FROM window_audit_log") == 0)

        // 3. flushPendingEvents 批量落库 + 全列保真
        logger.flushPendingEvents()
        let rows = auditRows(db, "SELECT event_type, window_id, pid, session_id, details FROM window_audit_log")
        check("auditPM: flush 后一行落库", rows.count == 1)
        check("auditPM: 全列保真（type/window/pid/session/JSON details）",
              rows.first == (["toggle", "7", "123", "sess-1", "{\"k\":\"v\"}"] as [String?]))

        // 4. 空值绑定：pid nil / sessionID 空串 / details 空字典 → 三列 NULL
        logger.record(eventType: "restore", windowID: 9, pid: nil, sessionID: "", details: [:])
        logger.flushPendingEvents()
        let nullRow = auditRows(db, "SELECT pid, session_id, details FROM window_audit_log WHERE event_type='restore'").first
        check("auditPM: 空 pid/空 session/空 details 全绑 NULL", nullRow == [nil, nil, nil])

        // 5. 防抖调度：record 后泵主 RunLoop 越过 0.3s 防抖窗 → 自动 flush 落库
        let logger2 = AuditLogger(db: db)
        logger2.record(eventType: "session-bind", windowID: 11)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        check("auditPM: record 防抖调度自动 flush（主队列 asyncAfter 命中）",
              scalarInt(db, "SELECT COUNT(*) FROM window_audit_log WHERE event_type='session-bind'") == 1)

        // 6. 积压看门：一次攒 55 条（> 阈值 50）→ 手动 flush 全部落库（事件不丢）
        for i in 0..<55 { logger2.record(eventType: "bulk", windowID: UInt32(i)) }
        logger2.flushPendingEvents()
        check("auditPM: 积压 55 条（超看门阈值）一次 flush 全部落库",
              scalarInt(db, "SELECT COUNT(*) FROM window_audit_log WHERE event_type='bulk'") == 55)

        // 7. 周期 trim 触发：第 50 条 insert 达 cleanupInterval → trimOldRecords 执行且 50 条全保留
        let logger3 = AuditLogger(db: db)
        for i in 0..<50 { logger3.record(eventType: "trim-trigger", windowID: UInt32(i)) }
        logger3.flushPendingEvents()
        check("auditPM: 第 50 条 insert 触发周期 trim 且 50 条全保留",
              scalarInt(db, "SELECT COUNT(*) FROM window_audit_log WHERE event_type='trim-trigger'") == 50)

        // 8. 上限裁剪：10005 行（created_at 取未来纪元 2.0e9 起，确保比其他用例的真实
        // 时间戳行「新」、不会先被挤出生存集）→ trim 保留 created_at 最新 10000、丢最旧 5 行
        sqlite3_exec(db, """
        INSERT INTO window_audit_log (event_type, window_id, created_at)
        WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c LIMIT 10005)
        SELECT 'cap', x, 2000000000 + x FROM c
        """, nil, nil, nil)
        logger3.trimOldRecords()
        check("auditPM: 超 10k 上限裁剪保留最新 10000",
              scalarInt(db, "SELECT COUNT(*) FROM window_audit_log WHERE event_type='cap'") == 10000)
        check("auditPM: 裁剪丢最旧（created_at 最小=起点+6）",
              scalarInt(db, "SELECT MIN(created_at) FROM window_audit_log WHERE event_type='cap'") == 2_000_000_006)

        // 9. testDB 透传注入连接
        check("auditPM: testDB 透传注入连接", AuditLogger(db: db).testDB == db)

        // 10. 坏连接安全：惰性打开句柄在坏路径上 → 建表 exec 失败走 error 分支、flush prepare 失败不崩
        var bad: OpaquePointer?
        sqlite3_open("/nonexistent-vf-dir-\(getpid())/x.db", &bad)
        defer { if let bad { sqlite3_close(bad) } }
        check("auditPM: 坏路径 open 仍返回句柄（sqlite 惰性打开语义）", bad != nil)
        let badLogger = AuditLogger(db: bad)
        badLogger.record(eventType: "x", windowID: 1)
        badLogger.flushPendingEvents()
        check("auditPM: 坏连接建表失败（表不存在）",
              sqlite3_exec(bad, "SELECT 1 FROM window_audit_log", nil, nil, nil) != SQLITE_OK)
        check("auditPM: 坏连接 flush 不崩不产行", scalarInt(bad, "SELECT COUNT(*) FROM window_audit_log") == nil)
    }

    // MARK: 查询助手（B229 追加线专用）

    private func scalarInt(_ db: OpaquePointer?, _ sql: String) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func auditRows(_ db: OpaquePointer?, _ sql: String) -> [[String?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [[String?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String?] = []
            for i in 0..<sqlite3_column_count(stmt) {
                if sqlite3_column_type(stmt, i) == SQLITE_NULL {
                    row.append(nil)
                } else {
                    row.append(String(cString: sqlite3_column_text(stmt, i)))
                }
            }
            rows.append(row)
        }
        return rows
    }
}
