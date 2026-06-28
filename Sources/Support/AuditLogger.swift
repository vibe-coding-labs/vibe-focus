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

    /// 待写入事件缓冲区 — toggle 热路径中仅追加到此数组，不阻塞
    private var pendingEvents: [(eventType: String, windowID: UInt32, pid: Int32?, sessionID: String?, details: [String: String])] = []
    private var flushScheduled = false
    private let flushDebounceInterval: TimeInterval = 0.3

    private let _injectedDB: OpaquePointer?
    private var db: OpaquePointer? { _injectedDB ?? WindowStateStore.shared.db }

    init(db: OpaquePointer? = nil) {
        _injectedDB = db
        createTable()
    }

    // MARK: - Table Setup

    private func createTable() {
        // P-INST-199: audit 表建表耗时（sqlite3_exec CREATE TABLE + 2x CREATE INDEX；AuditLogger init 启动单次调用）。
        let atStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: atStart)
            if durMs >= 5 { log("[AuditLogger] createTable slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
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
        // 追加到内存缓冲区 — 不阻塞调用者
        pendingEvents.append((eventType, windowID, pid, sessionID, details))
        scheduleFlush()
    }

    /// 调度异步刷新（带防抖）
    private func scheduleFlush() {
        // P-INST-258: 审计日志批量写防抖调度入口（DispatchQueue.main.asyncAfter 调度 flushPendingEvents P-INST-66 SQLite 批量写；record() 每次事件追加后调用，实际 flush 已覆盖，此处归因调度入口/防抖频率）。
        let sfStart = Date()
        defer {
            log("[AuditLogger] scheduleFlush finished", level: .debug, fields: ["durationMs": String(elapsedMilliseconds(since: sfStart))])
        }
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + flushDebounceInterval) { [weak self] in
            self?.flushScheduled = false
            self?.flushPendingEvents()
        }
    }

    /// 批量写入待处理事件到 SQLite
    /// internal 以便测试直接调用（@testable import 可见）
    func flushPendingEvents() {
        guard !pendingEvents.isEmpty else { return }
        // P-INST-66: AuditLogger 批量 SQLite 写耗时（异步防抖后执行，N 条 insertEventSync；record() 本身只内存 append 不阻塞，此埋点归因批量写对主线程的占用）。
        let flushStart = Date()
        let events = pendingEvents
        pendingEvents = []
        let flushed = events.count
        defer {
            log("[AuditLogger] flushPendingEvents finished", level: .debug, fields: [
                "events": String(flushed),
                "durationMs": String(elapsedMilliseconds(since: flushStart))
            ])
        }
        guard let db else { return }
        for event in events {
            insertEventSync(
                db: db,
                eventType: event.eventType,
                windowID: event.windowID,
                pid: event.pid,
                sessionID: event.sessionID,
                details: event.details
            )
        }
    }

    /// 同步写入单条事件到 SQLite（内部使用）
    private func insertEventSync(
        db: OpaquePointer,
        eventType: String,
        windowID: UInt32,
        pid: Int32?,
        sessionID: String?,
        details: [String: String]
    ) {
        // P-INST-200: audit 事件同步插入耗时（sqlite3_prepare/bind_text/bind_int64/bind_double/step/finalize INSERT；flushPendingEvents P-INST-66 批量调用，每条事件一次）。
        let iesStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: iesStart)
            if durMs >= 5 { log("[AuditLogger] insertEventSync slow", level: .warn, fields: ["eventType": eventType, "durationMs": String(durMs)]) }
        }
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
        // P-INST-201: audit 旧记录清理耗时（sqlite3_prepare/bind_int/step DELETE NOT IN 子查询；flushPendingEvents P-INST-66 后周期调用，保留 maxRecords 条）。
        let torStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: torStart)
            if durMs >= 5 { log("[AuditLogger] trimOldRecords slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
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
