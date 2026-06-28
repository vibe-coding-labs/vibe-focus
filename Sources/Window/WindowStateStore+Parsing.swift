// WindowStateStore+Parsing.swift
// VibeFocus — SQLite 行解析（WindowState / ToggleRecord）
// 从 WindowStateStore+ToggleRecord.swift 中提取

import Foundation
import SQLite3

@MainActor
extension WindowStateStore {

    // MARK: - Row Parser

    func parseWindowStateRow(_ stmt: OpaquePointer) -> WindowState? {
        // P-INST-155: WindowState 行解析耗时（34 列 sqlite3_column_int64/int/double/text/type 读取 + optionalStringCol + Date 构造；loadAllWindowStates/findWindowState P-INST-68 每行调用，SQLite 列读取）。
        let pwsrStart = Date()
        defer {
            log("[WindowStateStore] parseWindowStateRow finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: pwsrStart))
            ])
        }
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
            bindingType: .local,
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

    // MARK: - Toggle Record Row Parser

    func parseToggleRecord(_ stmt: OpaquePointer) -> ToggleRecord? {
        // P-INST-156: ToggleRecord 行解析耗时（19 列 sqlite3_column_int64/int/double/text 读取 + String(cString:) + Date 构造；loadToggleRecord P-INST-18/loadByPID P-INST-67 每行调用，SQLite 列读取）。
        let ptrStart = Date()
        defer {
            log("[WindowStateStore] parseToggleRecord finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: ptrStart))
            ])
        }
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

    func optionalStringCol(_ stmt: OpaquePointer, col: Int32) -> String? {
        // P-INST-157: 可选字符串列读取耗时（sqlite3_column_type NULL 检查 + sqlite3_column_text + String(cString:)；parseWindowStateRow P-INST-155 内每可选列调用，SQLite 列读取叶子）。
        let oscStart = Date()
        let value: String? = {
            guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
            let raw = String(cString: sqlite3_column_text(stmt, col))
            return raw.isEmpty ? nil : raw
        }()
        log("[WindowStateStore] optionalStringCol finished", level: .debug, fields: [
            "col": String(col),
            "durationMs": String(elapsedMilliseconds(since: oscStart))
        ])
        return value
    }
}
