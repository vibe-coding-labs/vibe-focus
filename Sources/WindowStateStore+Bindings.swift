import Foundation
import SQLite3

extension WindowStateStore {
    // MARK: - Windows Table (Unified)

    func saveWindowState(_ state: WindowState) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = """
            INSERT OR REPLACE INTO windows (
                window_id, pid, tty, ax_window_number, app_name, bundle_id, title,
                term_session_id, iterm_session_id, kitty_window_id, wezterm_pane, env_window_id,
                session_id, cwd, model,
                orig_x, orig_y, orig_w, orig_h,
                target_x, target_y, target_w, target_h,
                source_space, source_display, source_yabai_disp, source_disp_space,
                target_display, toggle_reason, toggled_at,
                is_completed, created_at, updated_at, completed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(state.windowID))
        sqlite3_bind_int(stmt, 2, state.pid)
        sqlite3_bind_text(stmt, 3, state.tty ?? "", -1, SQLITE_TRANSIENT)
        if let v = state.axWindowNumber { sqlite3_bind_int(stmt, 4, Int32(v)) } else { sqlite3_bind_null(stmt, 4) }
        sqlite3_bind_text(stmt, 5, state.appName ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, state.bundleIdentifier ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 7, state.title ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 8, state.termSessionID ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 9, state.itermSessionID ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 10, state.kittyWindowID ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 11, state.weztermPane ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 12, state.envWindowID ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 13, state.sessionID ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 14, state.cwd ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 15, state.model ?? "", -1, SQLITE_TRANSIENT)
        if let v = state.origX { sqlite3_bind_double(stmt, 16, Double(v)) } else { sqlite3_bind_null(stmt, 16) }
        if let v = state.origY { sqlite3_bind_double(stmt, 17, Double(v)) } else { sqlite3_bind_null(stmt, 17) }
        if let v = state.origW { sqlite3_bind_double(stmt, 18, Double(v)) } else { sqlite3_bind_null(stmt, 18) }
        if let v = state.origH { sqlite3_bind_double(stmt, 19, Double(v)) } else { sqlite3_bind_null(stmt, 19) }
        if let v = state.targetX { sqlite3_bind_double(stmt, 20, Double(v)) } else { sqlite3_bind_null(stmt, 20) }
        if let v = state.targetY { sqlite3_bind_double(stmt, 21, Double(v)) } else { sqlite3_bind_null(stmt, 21) }
        if let v = state.targetW { sqlite3_bind_double(stmt, 22, Double(v)) } else { sqlite3_bind_null(stmt, 22) }
        if let v = state.targetH { sqlite3_bind_double(stmt, 23, Double(v)) } else { sqlite3_bind_null(stmt, 23) }
        if let v = state.sourceSpace { sqlite3_bind_int(stmt, 24, Int32(v)) } else { sqlite3_bind_null(stmt, 24) }
        if let v = state.sourceDisplay { sqlite3_bind_int(stmt, 25, Int32(v)) } else { sqlite3_bind_null(stmt, 25) }
        if let v = state.sourceYabaiDisp { sqlite3_bind_int(stmt, 26, Int32(v)) } else { sqlite3_bind_null(stmt, 26) }
        if let v = state.sourceDispSpace { sqlite3_bind_int(stmt, 27, Int32(v)) } else { sqlite3_bind_null(stmt, 27) }
        if let v = state.targetDisplay { sqlite3_bind_int(stmt, 28, Int32(v)) } else { sqlite3_bind_null(stmt, 28) }
        sqlite3_bind_text(stmt, 29, state.toggleReason ?? "", -1, SQLITE_TRANSIENT)
        if let v = state.toggledAt { sqlite3_bind_double(stmt, 30, v.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 30) }
        sqlite3_bind_int(stmt, 31, state.isCompleted ? 1 : 0)
        sqlite3_bind_double(stmt, 32, state.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 33, state.updatedAt.timeIntervalSince1970)
        if let v = state.completedAt { sqlite3_bind_double(stmt, 34, v.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 34) }

        if sqlite3_step(stmt) != SQLITE_DONE {
            let errMsg = String(cString: sqlite3_errmsg(db))
            log("[WindowStateStore] saveWindowState (windows table) failed: \(errMsg)", level: .error)
        } else {
            let srcSp: String = if let v = state.sourceSpace { String(v) } else { "nil" }
            let tgtDsp: String = if let v = state.targetDisplay { String(v) } else { "nil" }
            let oX: String = if let v = state.origX { String(describing: v) } else { "nil" }
            let tX: String = if let v = state.targetX { String(describing: v) } else { "nil" }
            let sid: String = if let v = state.sessionID { String(v.prefix(8)) } else { "nil" }
            log("[WindowStateStore] saveWindowState OK wid=\(state.windowID) pid=\(state.pid) tty=\(state.tty ?? "") origX=\(oX) targetX=\(tX) srcSpace=\(srcSp) tgtDisp=\(tgtDsp) sid=\(sid)")
        }
    }

    func findWindowState(windowID: UInt32) -> WindowState? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let sql = "SELECT * FROM windows WHERE window_id = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(windowID))

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return parseWindowStateRow(stmt!)
    }

    func findWindowStateBySession(sessionID: String) -> WindowState? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let sql = "SELECT * FROM windows WHERE session_id = ? ORDER BY updated_at DESC LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionID, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return parseWindowStateRow(stmt!)
    }

    func findWindowStateByWindowID(_ windowID: UInt32) -> WindowState? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let sql = "SELECT * FROM windows WHERE window_id = ? ORDER BY updated_at DESC LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(windowID))

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return parseWindowStateRow(stmt!)
    }

    func clearToggleState(windowID: UInt32) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = """
            UPDATE windows SET
                orig_x = NULL, orig_y = NULL, orig_w = NULL, orig_h = NULL,
                target_x = NULL, target_y = NULL, target_w = NULL, target_h = NULL,
                source_space = NULL, source_display = NULL, source_yabai_disp = NULL,
                source_disp_space = NULL, target_display = NULL,
                toggle_reason = NULL, toggled_at = NULL,
                updated_at = ?
            WHERE window_id = ?;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 2, Int64(windowID))
        sqlite3_step(stmt)
    }

    func deleteAllWindowsStates() {
        guard let db else { return }
        runSchema("DELETE FROM windows;")
    }

    func pruneExpiredWindowStates(activeRetention: TimeInterval, completedRetention: TimeInterval) -> Int {
        guard let db else { return 0 }
        let now = Date().timeIntervalSince1970
        let activeCutoff = now - activeRetention
        let completedCutoff = now - completedRetention

        let sql = """
            DELETE FROM windows
            WHERE (is_completed = 0 AND updated_at < ?)
               OR (is_completed = 1 AND updated_at < ?);
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, activeCutoff)
        sqlite3_bind_double(stmt, 2, completedCutoff)
        sqlite3_step(stmt)
        return Int(sqlite3_changes(db))
    }

    func loadAllWindowStates() -> [WindowState] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        let sql = "SELECT * FROM windows ORDER BY updated_at ASC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [WindowState] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let state = parseWindowStateRow(stmt!) {
                results.append(state)
            }
        }
        return results
    }

    func deleteWindowState(windowID: UInt32) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = "DELETE FROM windows WHERE window_id = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(windowID))
        sqlite3_step(stmt)
    }

    var windowStatesCount: Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM windows;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
}
}
