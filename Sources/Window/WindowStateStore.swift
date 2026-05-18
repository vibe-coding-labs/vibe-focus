import Foundation
import Csqlite3

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
    }
}
