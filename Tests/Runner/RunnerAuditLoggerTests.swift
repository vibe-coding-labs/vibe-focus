// Tests/Runner/RunnerAuditLoggerTests.swift — AuditLogger 全族直测（注入独立 SQLite 连接）。
// 背景：B194 双检互斥事故（调度链断、audit 表 4 天零写入无人知）暴露该域只有盲区没有验证。
// 本文件以 :memory: / 坏路径连接直测真实行为：record 缓冲→防抖调度→批量 flush→NULL 绑定
// →积压看门→50 条周期 trim→10k 上限裁剪→坏连接安全。零触 WindowStateStore.shared 生产库。

import Foundation
import SQLite3
@testable import VibeFocusKit

extension RunnerHarness {
    func runAuditLoggerTests() {
        var db: OpaquePointer?
        sqlite3_open(":memory:", &db)
        defer { sqlite3_close(db) }
        let logger = AuditLogger(db: db)

        // 1. init 建表：注入连接上真实 CREATE TABLE 生效
        check("audit: 注入连接建表成功（表可查询）",
              sqlite3_exec(db, "SELECT 1 FROM window_audit_log LIMIT 1", nil, nil, nil) == SQLITE_OK)

        // 2. record 只入内存缓冲不落库（flush 前表空）
        logger.record(eventType: "toggle", windowID: 7, pid: 123, sessionID: "sess-1", details: ["k": "v"])
        check("audit: record 只入缓冲不落库",
              scalarInt(db, "SELECT COUNT(*) FROM window_audit_log") == 0)

        // 3. flushPendingEvents 批量落库 + 全列保真
        logger.flushPendingEvents()
        let rows = auditRows(db, "SELECT event_type, window_id, pid, session_id, details FROM window_audit_log")
        check("audit: flush 后一行落库", rows.count == 1)
        check("audit: 全列保真（type/window/pid/session/JSON details）",
              rows.first == (["toggle", "7", "123", "sess-1", "{\"k\":\"v\"}"] as [String?]))

        // 4. 空值绑定：pid nil / sessionID 空串 / details 空字典 → 三列 NULL
        logger.record(eventType: "restore", windowID: 9, pid: nil, sessionID: "", details: [:])
        logger.flushPendingEvents()
        let nullRow = auditRows(db, "SELECT pid, session_id, details FROM window_audit_log WHERE event_type='restore'").first
        check("audit: 空 pid/空 session/空 details 全绑 NULL", nullRow == [nil, nil, nil])

        // 5. 防抖调度：record 后泵主 RunLoop 越过 0.3s 防抖窗 → 自动 flush 落库
        let logger2 = AuditLogger(db: db)
        logger2.record(eventType: "session-bind", windowID: 11)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        check("audit: record 防抖调度自动 flush（主队列 asyncAfter 命中）",
              scalarInt(db, "SELECT COUNT(*) FROM window_audit_log WHERE event_type='session-bind'") == 1)

        // 6. 积压看门：一次攒 55 条（> 阈值 50）→ 手动 flush 全部落库（事件不丢）
        for i in 0..<55 { logger2.record(eventType: "bulk", windowID: UInt32(i)) }
        logger2.flushPendingEvents()
        check("audit: 积压 55 条（超看门阈值）一次 flush 全部落库",
              scalarInt(db, "SELECT COUNT(*) FROM window_audit_log WHERE event_type='bulk'") == 55)

        // 7. 周期 trim 触发：第 50 条 insert 达 cleanupInterval → trimOldRecords 执行且 50 条全保留
        let logger3 = AuditLogger(db: db)
        for i in 0..<50 { logger3.record(eventType: "trim-trigger", windowID: UInt32(i)) }
        logger3.flushPendingEvents()
        check("audit: 第 50 条 insert 触发周期 trim 且 50 条全保留",
              scalarInt(db, "SELECT COUNT(*) FROM window_audit_log WHERE event_type='trim-trigger'") == 50)

        // 8. 上限裁剪：10005 行（created_at 取未来纪元 2.0e9 起，确保比其他用例的真实
        // 时间戳行「新」、不会先被挤出生存集）→ trim 保留 created_at 最新 10000、丢最旧 5 行
        sqlite3_exec(db, """
        INSERT INTO window_audit_log (event_type, window_id, created_at)
        WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c LIMIT 10005)
        SELECT 'cap', x, 2000000000 + x FROM c
        """, nil, nil, nil)
        logger3.trimOldRecords()
        check("audit: 超 10k 上限裁剪保留最新 10000",
              scalarInt(db, "SELECT COUNT(*) FROM window_audit_log WHERE event_type='cap'") == 10000)
        check("audit: 裁剪丢最旧（created_at 最小=起点+6）",
              scalarInt(db, "SELECT MIN(created_at) FROM window_audit_log WHERE event_type='cap'") == 2_000_000_006)

        // 9. testDB 透传注入连接
        check("audit: testDB 透传注入连接", AuditLogger(db: db).testDB == db)

        // 10. 坏连接安全：惰性打开句柄在坏路径上 → 建表 exec 失败走 error 分支、flush prepare 失败不崩
        var bad: OpaquePointer?
        sqlite3_open("/nonexistent-vf-dir-\(getpid())/x.db", &bad)
        defer { if let bad { sqlite3_close(bad) } }
        check("audit: 坏路径 open 仍返回句柄（sqlite 惰性打开语义）", bad != nil)
        let badLogger = AuditLogger(db: bad)
        badLogger.record(eventType: "x", windowID: 1)
        badLogger.flushPendingEvents()
        check("audit: 坏连接建表失败（表不存在）",
              sqlite3_exec(bad, "SELECT 1 FROM window_audit_log", nil, nil, nil) != SQLITE_OK)
        check("audit: 坏连接 flush 不崩不产行", scalarInt(bad, "SELECT COUNT(*) FROM window_audit_log") == nil)
    }

    // MARK: 查询助手（本文件专用）

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
