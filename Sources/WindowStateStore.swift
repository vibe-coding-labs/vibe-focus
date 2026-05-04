import Foundation
import Csqlite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

@MainActor
final class WindowStateStore {
    static let shared = WindowStateStore()

    private var db: OpaquePointer?
    private let dbPath: String

    private init() {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".vibefocus")
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        dbPath = (dir as NSString).appendingPathComponent("vibefocus.db")
        openDatabase()
        createTables()
    }

    // MARK: - Database Setup

    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            log("[WindowStateStore] failed to open database at \(dbPath)", level: .error)
            db = nil
            return
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA journal_mode=WAL;", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else {
            log("[WindowStateStore] failed to set WAL mode", level: .error)
            return
        }
        sqlite3_finalize(stmt)
        log("[WindowStateStore] database opened with WAL mode at \(dbPath)")
    }

    private func runSchema(_ sql: String) {
        guard let db else { return }
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            log("[WindowStateStore] schema error: \(msg)", level: .error)
        }
    }

    private func createTables() {
        runSchema("""
            CREATE TABLE IF NOT EXISTS window_states (
                id TEXT PRIMARY KEY,
                data TEXT NOT NULL,
                window_id INTEGER,
                pid INTEGER,
                app_name TEXT,
                session_id TEXT,
                saved_at REAL NOT NULL,
                created_at REAL NOT NULL DEFAULT (strftime('%s','now'))
            );
            """)
        runSchema("CREATE INDEX IF NOT EXISTS idx_window_states_window_id ON window_states(window_id);")
        runSchema("CREATE INDEX IF NOT EXISTS idx_window_states_session_id ON window_states(session_id);")
        runSchema("""
            CREATE TABLE IF NOT EXISTS session_bindings (
                session_id TEXT PRIMARY KEY,
                data TEXT NOT NULL,
                is_completed INTEGER NOT NULL DEFAULT 0,
                last_seen_at REAL NOT NULL,
                created_at REAL NOT NULL DEFAULT (strftime('%s','now'))
            );
            """)
        runSchema("CREATE INDEX IF NOT EXISTS idx_session_bindings_last_seen ON session_bindings(last_seen_at);")
        log("[WindowStateStore] tables created/verified")
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
        let sql: String
        if let sessionID, !sessionID.isEmpty {
            sql = "SELECT data FROM window_states WHERE window_id = ? AND session_id = ? ORDER BY saved_at DESC LIMIT 1;"
        } else {
            sql = "SELECT data FROM window_states WHERE window_id = ? ORDER BY saved_at DESC LIMIT 1;"
        }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(windowID))
        if let sessionID, !sessionID.isEmpty {
            sqlite3_bind_text(stmt, 2, sessionID, -1, SQLITE_TRANSIENT)
        }

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

    // MARK: - Session Bindings

    func saveBinding(_ binding: SessionWindowBinding) {
        guard let db, let data = try? JSONEncoder().encode(binding) else { return }
        let jsonString = String(data: data, encoding: .utf8) ?? "{}"
        var stmt: OpaquePointer?
        let sql = """
            INSERT OR REPLACE INTO session_bindings (session_id, data, is_completed, last_seen_at)
            VALUES (?, ?, ?, ?);
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, binding.sessionID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, jsonString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, binding.isCompleted ? 1 : 0)
        sqlite3_bind_double(stmt, 4, binding.lastSeenAt.timeIntervalSince1970)

        if sqlite3_step(stmt) != SQLITE_DONE {
            log("[WindowStateStore] saveBinding failed", level: .error)
        }
    }

    func loadBindings() -> [String: SessionWindowBinding] {
        guard let db else { return [:] }
        var stmt: OpaquePointer?
        let sql = "SELECT data FROM session_bindings;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        var results: [String: SessionWindowBinding] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cStr = sqlite3_column_text(stmt, 0) else { continue }
            let jsonString = String(cString: cStr)
            guard let data = jsonString.data(using: .utf8),
                  let binding = try? JSONDecoder().decode(SessionWindowBinding.self, from: data) else {
                continue
            }
            results[binding.sessionID] = binding
        }
        return results
    }

    func deleteBinding(sessionID: String) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = "DELETE FROM session_bindings WHERE session_id = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionID, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    func deleteAllBindings() {
        guard let db else { return }
        runSchema("DELETE FROM session_bindings;")
    }

    func pruneExpiredBindings(activeRetention: TimeInterval, completedRetention: TimeInterval) -> Int {
        guard let db else { return 0 }
        let now = Date().timeIntervalSince1970
        let activeCutoff = now - activeRetention
        let completedCutoff = now - completedRetention

        let sql = """
            DELETE FROM session_bindings
            WHERE (is_completed = 0 AND last_seen_at < ?)
               OR (is_completed = 1 AND last_seen_at < ?);
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, activeCutoff)
        sqlite3_bind_double(stmt, 2, completedCutoff)
        sqlite3_step(stmt)
        return Int(sqlite3_changes(db))
    }

    var bindingsCount: Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM session_bindings;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }
}
