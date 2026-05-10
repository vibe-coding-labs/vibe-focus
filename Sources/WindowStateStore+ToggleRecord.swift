import Foundation
import SQLite3

extension WindowStateStore {
    // MARK: - ToggleRecord (Single Source of Truth)

    /// 原子性保存 toggle record 到 windows 表
    func saveToggleRecord(_ record: ToggleRecord) {
        guard let db else {
            log("saveToggleRecord: db is nil", level: .error)
            return
        }
        let now = Date().timeIntervalSince1970
        var stmt: OpaquePointer?

        let sql = """
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

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
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
            log("saveToggleRecord failed", level: .error, fields: [
                "error": String(cString: sqlite3_errmsg(db)),
                "windowID": String(record.windowID)
            ])
            return
        }

        log("saveToggleRecord saved", level: .info, fields: [
            "windowID": String(record.windowID),
            "sourceSpace": String(record.sourceSpace),
            "sourceDisplay": String(record.sourceDisplay),
            "sourceYabaiDisp": String(record.sourceYabaiDisp),
            "sourceDispSpace": String(record.sourceDispSpace),
            "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y))",
            "targetFrame": "\(Int(record.targetFrame.origin.x)),\(Int(record.targetFrame.origin.y))"
        ])
    }

    /// 按 windowID 读取 toggle record
    func loadToggleRecord(windowID: UInt32) -> ToggleRecord? {
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
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let wID = UInt32(sqlite3_column_int64(stmt, 0))
        let pid = sqlite3_column_int(stmt, 1)
        let bundleID: String? = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
        let appName: String? = sqlite3_column_text(stmt, 3).map { String(cString: $0) }

        let ox = CGFloat(sqlite3_column_double(stmt, 4))
        let oy = CGFloat(sqlite3_column_double(stmt, 5))
        let ow = CGFloat(sqlite3_column_double(stmt, 6))
        let oh = CGFloat(sqlite3_column_double(stmt, 7))
        let tx = CGFloat(sqlite3_column_double(stmt, 8))
        let ty = CGFloat(sqlite3_column_double(stmt, 9))
        let tw = CGFloat(sqlite3_column_double(stmt, 10))
        let th = CGFloat(sqlite3_column_double(stmt, 11))

        let sourceSpace = Int(sqlite3_column_int(stmt, 12))
        let sourceDisplay = Int(sqlite3_column_int(stmt, 13))
        let sourceYabaiDisp = Int(sqlite3_column_int(stmt, 14))
        let sourceDispSpace = Int(sqlite3_column_int(stmt, 15))
        let targetDisplay = Int(sqlite3_column_int(stmt, 16))
        let toggledAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 17))
        let sessionID: String? = sqlite3_column_text(stmt, 18).map { String(cString: $0) }

        return ToggleRecord(
            windowID: wID, pid: pid,
            bundleIdentifier: bundleID, appName: appName,
            origFrame: CGRect(x: ox, y: oy, width: ow, height: oh),
            sourceSpace: sourceSpace, sourceDisplay: sourceDisplay,
            sourceYabaiDisp: sourceYabaiDisp, sourceDispSpace: sourceDispSpace,
            targetFrame: CGRect(x: tx, y: ty, width: tw, height: th),
            targetDisplay: targetDisplay,
            toggledAt: toggledAt, sessionID: sessionID
        )
    }

    /// 清除指定窗口的 toggle state
    func clearToggleRecord(windowID: UInt32) {
        guard let db else { return }
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

    // MARK: - Row Parser

    func parseWindowStateRow(_ stmt: OpaquePointer) -> WindowState? {
        let windowID = UInt32(sqlite3_column_int64(stmt, 0))
        let pid = sqlite3_column_int(stmt, 1)
        let tty = String(cString: sqlite3_column_text(stmt, 2))
        let axWindowNumber: Int? = sqlite3_column_type(stmt, 3) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 3)) : nil
        let appName = optionalStringCol(stmt, col: 4)
        let bundleID = optionalStringCol(stmt, col: 5)
        let title = optionalStringCol(stmt, col: 6)
        let termSessionID = optionalStringCol(stmt, col: 7)
        let itermSessionID = optionalStringCol(stmt, col: 8)
        let kittyWindowID = optionalStringCol(stmt, col: 9)
        let weztermPane = optionalStringCol(stmt, col: 10)
        let envWindowID = optionalStringCol(stmt, col: 11)
        let sessionID = optionalStringCol(stmt, col: 12)
        let cwd = optionalStringCol(stmt, col: 13)
        let model = optionalStringCol(stmt, col: 14)

        let origX: CGFloat? = sqlite3_column_type(stmt, 15) != SQLITE_NULL ? CGFloat(sqlite3_column_double(stmt, 15)) : nil
        let origY: CGFloat? = sqlite3_column_type(stmt, 16) != SQLITE_NULL ? CGFloat(sqlite3_column_double(stmt, 16)) : nil
        let origW: CGFloat? = sqlite3_column_type(stmt, 17) != SQLITE_NULL ? CGFloat(sqlite3_column_double(stmt, 17)) : nil
        let origH: CGFloat? = sqlite3_column_type(stmt, 18) != SQLITE_NULL ? CGFloat(sqlite3_column_double(stmt, 18)) : nil
        let targetX: CGFloat? = sqlite3_column_type(stmt, 19) != SQLITE_NULL ? CGFloat(sqlite3_column_double(stmt, 19)) : nil
        let targetY: CGFloat? = sqlite3_column_type(stmt, 20) != SQLITE_NULL ? CGFloat(sqlite3_column_double(stmt, 20)) : nil
        let targetW: CGFloat? = sqlite3_column_type(stmt, 21) != SQLITE_NULL ? CGFloat(sqlite3_column_double(stmt, 21)) : nil
        let targetH: CGFloat? = sqlite3_column_type(stmt, 22) != SQLITE_NULL ? CGFloat(sqlite3_column_double(stmt, 22)) : nil
        let sourceSpace: Int? = sqlite3_column_type(stmt, 23) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 23)) : nil
        let sourceDisplay: Int? = sqlite3_column_type(stmt, 24) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 24)) : nil
        let sourceYabaiDisp: Int? = sqlite3_column_type(stmt, 25) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 25)) : nil
        let sourceDispSpace: Int? = sqlite3_column_type(stmt, 26) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 26)) : nil
        let targetDisplay: Int? = sqlite3_column_type(stmt, 27) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 27)) : nil
        let toggleReason = optionalStringCol(stmt, col: 28)
        let toggledAt: Date? = sqlite3_column_type(stmt, 29) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 29)) : nil

        let isCompleted = sqlite3_column_int(stmt, 30) != 0
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 31))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 32))
        let completedAt: Date? = sqlite3_column_type(stmt, 33) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 33)) : nil

        return WindowState(
            windowID: windowID,
            pid: pid,
            tty: tty.isEmpty ? nil : tty,
            axWindowNumber: axWindowNumber,
            appName: appName,
            bundleIdentifier: bundleID,
            title: title,
            termSessionID: termSessionID,
            itermSessionID: itermSessionID,
            kittyWindowID: kittyWindowID,
            weztermPane: weztermPane,
            envWindowID: envWindowID,
            sessionID: sessionID,
            cwd: cwd,
            model: model,
            origX: origX, origY: origY, origW: origW, origH: origH,
            targetX: targetX, targetY: targetY, targetW: targetW, targetH: targetH,
            sourceSpace: sourceSpace,
            sourceDisplay: sourceDisplay,
            sourceYabaiDisp: sourceYabaiDisp,
            sourceDispSpace: sourceDispSpace,
            targetDisplay: targetDisplay,
            toggleReason: toggleReason,
            toggledAt: toggledAt,
            isCompleted: isCompleted,
            completedAt: completedAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    func optionalStringCol(_ stmt: OpaquePointer, col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        let raw = String(cString: sqlite3_column_text(stmt, col))
        return raw.isEmpty ? nil : raw
    }
}

