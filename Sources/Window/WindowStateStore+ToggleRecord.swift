import Foundation
import SQLite3

extension WindowStateStore {
    // MARK: - ToggleRecord (Single Source of Truth)

    /// 原子性保存 toggle record 到 windows 表
    func saveToggleRecord(_ record: ToggleRecord) {
        // P-INST-202: toggle record 保存耗时（UPDATE prepare/bind_double x12+ bind_int64/step + 必要时 INSERT upsert；ToggleEngine.save/restore 调用，hook+toggle 热路径 SQLite 写，WAL 通常 <1ms ≥5ms 异常）。
        let strStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: strStart)
            if durMs >= 5 { log("[WindowStateStore] saveToggleRecord slow", level: .warn, fields: ["windowID": String(record.windowID), "durationMs": String(durMs)]) }
        }
        guard let db else {
            log("saveToggleRecord: db is nil", level: .error)
            return
        }
        let now = Date().timeIntervalSince1970
        var stmt: OpaquePointer?

        // 1. 尝试 UPDATE 已有行
        let updateSQL = """
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

        guard sqlite3_prepare_v2(db, updateSQL, -1, &stmt, nil) == SQLITE_OK else {
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
            log("saveToggleRecord update failed", level: .error, fields: [
                "error": String(cString: sqlite3_errmsg(db)),
                "windowID": String(record.windowID)
            ])
            return
        }

        let changes = sqlite3_changes(db)
        if changes > 0 {
            log("saveToggleRecord saved", level: .info, fields: [
                "windowID": String(record.windowID),
                "sourceSpace": String(record.sourceSpace),
                "sourceDisplay": String(record.sourceDisplay),
                "sourceYabaiDisp": String(record.sourceYabaiDisp),
                "sourceDispSpace": String(record.sourceDispSpace),
                "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y))",
                "targetFrame": "\(Int(record.targetFrame.origin.x)),\(Int(record.targetFrame.origin.y))"
            ])
            return
        }

        // 2. UPDATE 影响 0 行 → 行不存在，fallback INSERT
        log("saveToggleRecord: no existing row, inserting new", level: .info, fields: [
            "windowID": String(record.windowID),
            "pid": String(record.pid)
        ])

        let insertSQL = """
            INSERT INTO windows (
                window_id, pid, bundle_id, app_name, tty, updated_at,
                orig_x, orig_y, orig_w, orig_h,
                target_x, target_y, target_w, target_h,
                source_space, source_display, source_yabai_disp, source_disp_space,
                target_display, toggle_reason, toggled_at, session_id,
                is_completed, created_at
            ) VALUES (?, ?, ?, ?, '', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'manual_hotkey', ?, ?, 0, ?)
        """

        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            log("saveToggleRecord insert prepare failed", level: .error, fields: [
                "error": String(cString: sqlite3_errmsg(db))
            ])
            return
        }

        sqlite3_bind_int64(stmt, 1, Int64(record.windowID))
        sqlite3_bind_int(stmt, 2, record.pid)
        sqlite3_bind_text(stmt, 3, record.bundleIdentifier ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, record.appName ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 5, now)
        sqlite3_bind_double(stmt, 6, Double(record.origFrame.origin.x))
        sqlite3_bind_double(stmt, 7, Double(record.origFrame.origin.y))
        sqlite3_bind_double(stmt, 8, Double(record.origFrame.size.width))
        sqlite3_bind_double(stmt, 9, Double(record.origFrame.size.height))
        sqlite3_bind_double(stmt, 10, Double(record.targetFrame.origin.x))
        sqlite3_bind_double(stmt, 11, Double(record.targetFrame.origin.y))
        sqlite3_bind_double(stmt, 12, Double(record.targetFrame.size.width))
        sqlite3_bind_double(stmt, 13, Double(record.targetFrame.size.height))
        sqlite3_bind_int(stmt, 14, Int32(record.sourceSpace))
        sqlite3_bind_int(stmt, 15, Int32(record.sourceDisplay))
        sqlite3_bind_int(stmt, 16, Int32(record.sourceYabaiDisp))
        sqlite3_bind_int(stmt, 17, Int32(record.sourceDispSpace))
        sqlite3_bind_int(stmt, 18, Int32(record.targetDisplay))
        sqlite3_bind_double(stmt, 19, record.toggledAt.timeIntervalSince1970)
        if let sid = record.sessionID, !sid.isEmpty {
            sqlite3_bind_text(stmt, 20, sid, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 20)
        }
        sqlite3_bind_double(stmt, 21, now)

        let insertResult = sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        if insertResult != SQLITE_DONE {
            log("saveToggleRecord insert failed", level: .error, fields: [
                "error": String(cString: sqlite3_errmsg(db)),
                "windowID": String(record.windowID)
            ])
            return
        }

        log("saveToggleRecord inserted new row", level: .info, fields: [
            "windowID": String(record.windowID),
            "sourceSpace": String(record.sourceSpace),
            "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y))",
            "targetFrame": "\(Int(record.targetFrame.origin.x)),\(Int(record.targetFrame.origin.y))"
        ])
    }

    /// 按 windowID 读取 toggle record
    func loadToggleRecord(windowID: UInt32) -> ToggleRecord? {
        // P-INST-203: toggle record 按 windowID 读取耗时（SELECT prepare/bind_int64/step + parseToggleRecord P-INST-156；ToggleEngine.load 调用，shouldRestore 决策 SQLite 读，WAL 通常 <1ms ≥5ms 异常。P-INST-18 在 ToggleEngine.load 编排层）。
        let ltrStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: ltrStart)
            if durMs >= 5 { log("[WindowStateStore] loadToggleRecord slow", level: .warn, fields: ["windowID": String(windowID), "durationMs": String(durMs)]) }
        }
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
        guard sqlite3_step(stmt) == SQLITE_ROW, let s = stmt else { return nil }

        return parseToggleRecord(s)
    }

    /// 按 PID 读取最近的 toggle record（CGWindowNumber 变化时的 fallback）
    func loadToggleRecordByPID(pid: Int32) -> ToggleRecord? {
        guard let db else { return nil }
        // P-INST-67: PID fallback 读 SQLite 耗时（toggle 决策 fallback 路径；P-INST-18 仅覆盖 loadToggleRecord(windowID:)；WAL 读通常 <1ms，≥5ms 异常信号）。
        let lbpStart = Date()
        var found = false
        defer {
            let ms = elapsedMilliseconds(since: lbpStart)
            if ms >= 5 { log("[WindowStateStore] loadToggleRecordByPID slow", level: .warn, fields: ["pid": String(pid), "found": String(found), "durationMs": String(ms)]) }
        }
        var stmt: OpaquePointer?
        let sql = """
            SELECT window_id, pid, bundle_id, app_name,
                   orig_x, orig_y, orig_w, orig_h,
                   target_x, target_y, target_w, target_h,
                   source_space, source_display, source_yabai_disp, source_disp_space,
                   target_display, toggled_at, session_id
            FROM windows
            WHERE pid = ? AND toggle_reason IS NOT NULL AND orig_x IS NOT NULL
            ORDER BY toggled_at DESC
            LIMIT 1
        """

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, pid)
        guard sqlite3_step(stmt) == SQLITE_ROW, let s = stmt else { return nil }
        found = true

        return parseToggleRecord(s)
    }

    /// 清除指定窗口的 toggle state
    func clearToggleRecord(windowID: UInt32) {
        guard let db else { return }
        // P-INST-67: clear SQLite 写耗时（restore 后清除 toggle state，UPDATE 操作；WAL 写通常 <1ms，≥5ms 异常）。
        let clrStart = Date()
        defer {
            let ms = elapsedMilliseconds(since: clrStart)
            if ms >= 5 { log("[WindowStateStore] clearToggleRecord slow", level: .warn, fields: ["windowID": String(windowID), "durationMs": String(ms)]) }
        }
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

    // Row 解析已移至 WindowStateStore+Parsing.swift
    // 包含: parseWindowStateRow, parseToggleRecord, optionalStringCol
}

