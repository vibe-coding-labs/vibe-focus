import Foundation
import Csqlite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

@MainActor
final class WindowStateStore {
    static let shared = WindowStateStore()

    var db: OpaquePointer?
    let dbPath: String

    private init() {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".vibefocus")
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        dbPath = (dir as NSString).appendingPathComponent("vibefocus.db")
        openDatabase()
        createTables()
        cleanupLegacyTables()
    }

    // MARK: - Window States

    func saveState(_ state: WindowManager.SavedWindowState) {
        guard let db, let data = try? JSONEncoder().encode(state) else { return }
        let jsonString = String(data: data, encoding: .utf8) ?? "{}"
        var stmt: OpaquePointer?
        let sql = """
            INSERT OR REPLACE INTO window_states (id, data, window_id, pid, app_name, session_id, saved_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, state.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, jsonString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 3, Int64(state.windowID ?? 0))
        sqlite3_bind_int(stmt, 4, state.pid)
        sqlite3_bind_text(stmt, 5, state.appName ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, state.sessionID ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 7, state.savedAt.timeIntervalSince1970)

        if sqlite3_step(stmt) != SQLITE_DONE {
            log("[WindowStateStore] saveState failed", level: .error)
        }
    }

    func loadStates() -> [WindowManager.SavedWindowState] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        let sql = "SELECT data FROM window_states ORDER BY saved_at ASC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [WindowManager.SavedWindowState] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cStr = sqlite3_column_text(stmt, 0) else { continue }
            let jsonString = String(cString: cStr)
            guard let data = jsonString.data(using: .utf8),
                  let state = try? JSONDecoder().decode(WindowManager.SavedWindowState.self, from: data) else {
                continue
            }
            results.append(state)
        }
        return results
    }

    func deleteState(id: String) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = "DELETE FROM window_states WHERE id = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    func deleteAllStates() {
        guard let db else { return }
        runSchema("DELETE FROM window_states;")
    }

    func findState(windowID: UInt32, sessionID: String?) -> WindowManager.SavedWindowState? {
        guard let db else { return nil }
        var stmt: OpaquePointer?

        // 优先 windowID + sessionID 精确匹配
        if let sessionID, !sessionID.isEmpty {
            let sql = "SELECT data FROM window_states WHERE window_id = ? AND session_id = ? ORDER BY saved_at DESC LIMIT 1;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(windowID))
            sqlite3_bind_text(stmt, 2, sessionID, -1, SQLITE_TRANSIENT)

            if sqlite3_step(stmt) == SQLITE_ROW,
               let cStr = sqlite3_column_text(stmt, 0) {
                let jsonString = String(cString: cStr)
                if let data = jsonString.data(using: .utf8),
                   let state = try? JSONDecoder().decode(WindowManager.SavedWindowState.self, from: data) {
                    return state
                }
            }
            sqlite3_finalize(stmt)
            stmt = nil
        }

        // Fallback: 仅 windowID 匹配（session_id 为空或历史数据）
        let fallbackSQL = "SELECT data FROM window_states WHERE window_id = ? ORDER BY saved_at DESC LIMIT 1;"
        guard sqlite3_prepare_v2(db, fallbackSQL, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(windowID))

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        let jsonString = String(cString: cStr)
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WindowManager.SavedWindowState.self, from: data)
    }

    func findStateByApp(appName: String, sessionID: String?) -> WindowManager.SavedWindowState? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let sql: String
        if let sessionID, !sessionID.isEmpty {
            sql = "SELECT data FROM window_states WHERE app_name = ? AND session_id = ? ORDER BY saved_at DESC LIMIT 1;"
        } else {
            sql = "SELECT data FROM window_states WHERE app_name = ? ORDER BY saved_at DESC LIMIT 1;"
        }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, appName, -1, SQLITE_TRANSIENT)
        if let sessionID, !sessionID.isEmpty {
            sqlite3_bind_text(stmt, 2, sessionID, -1, SQLITE_TRANSIENT)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        let jsonString = String(cString: cStr)
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WindowManager.SavedWindowState.self, from: data)
    }

    func findStateByPID(pid: Int32, sessionID: String?) -> WindowManager.SavedWindowState? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let sql: String
        if let sessionID, !sessionID.isEmpty {
            sql = "SELECT data FROM window_states WHERE pid = ? AND session_id = ? ORDER BY saved_at DESC LIMIT 1;"
        } else {
            sql = "SELECT data FROM window_states WHERE pid = ? ORDER BY saved_at DESC LIMIT 1;"
        }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(pid))
        if let sessionID, !sessionID.isEmpty {
            sqlite3_bind_text(stmt, 2, sessionID, -1, SQLITE_TRANSIENT)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        let jsonString = String(cString: cStr)
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WindowManager.SavedWindowState.self, from: data)
    }

    func evictStatesOlderThan(maxAge: TimeInterval) -> Int {
        guard let db else { return 0 }
        let cutoff = Date().addingTimeInterval(-maxAge).timeIntervalSince1970
        var stmt: OpaquePointer?
        let sql = "DELETE FROM window_states WHERE saved_at < ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff)
        sqlite3_step(stmt)
        return Int(sqlite3_changes(db))
    }

    func cleanupStaleStates(existingWindowIDs: Set<UInt32>, gracePeriod: TimeInterval) -> Int {
        guard let db else { return 0 }
        let cutoff = Date().addingTimeInterval(-gracePeriod).timeIntervalSince1970
        var stmt: OpaquePointer?
        let sql = "SELECT id, window_id, data FROM window_states WHERE saved_at < ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff)

        var toDelete: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cStr = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: cStr)
            let windowID = UInt32(sqlite3_column_int64(stmt, 1))
            if !existingWindowIDs.contains(windowID) {
                toDelete.append(id)
            }
        }

        for id in toDelete {
            deleteState(id: id)
        }
        return toDelete.count
    }

    var statesCount: Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM window_states;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

}
