import Foundation

// MARK: - 会话快照持久化
/// v2 快照存独立 key；旧 TerminalGridSnapshot（单屏模型）不再生产（createGrid 的
/// 网格落账除外），存量经迁移视图并入列表：读 = v2 ∪ legacy 转换（同 id v2 优先），
/// 删 = 两库都删。旧 key 保留不写——旧版本二进制回滚后仍能看到自己的快照。
@MainActor
final class SessionRestoreStore {

    static let shared = SessionRestoreStore()

    private let store: WindowStateStore
    private static let preferenceKey = "sessionRestoreSnapshotsV2"

    init(store: WindowStateStore = .shared) {
        self.store = store
    }

    func snapshots() -> [SessionRestoreSnapshot] {
        var list = loadV2()
        let legacy = loadLegacy().map(SessionSnapshotMigrator.migrateLegacy)
        list = Self.merge(v2: list, legacyConverted: legacy)
        return list.sorted { $0.capturedAt < $1.capturedAt }
    }

    func upsert(_ snapshot: SessionRestoreSnapshot) {
        var list = loadV2()
        if let index = list.firstIndex(where: { $0.id == snapshot.id }) {
            list[index] = snapshot
        } else {
            list.append(snapshot)
        }
        save(list)
    }

    func remove(id: String) {
        save(loadV2().filter { $0.id != id })
        // 旧库同 id 一并清（迁移视图里就不会再出现）
        let legacyKey = "terminalGridSnapshots"
        if var legacy = loadLegacyRaw() {
            legacy = legacy.filter { $0.id != id }
            if let data = try? JSONEncoder().encode(legacy), let json = String(data: data, encoding: .utf8) {
                self.store.savePreference(key: legacyKey, value: json)
            }
        }
    }

    func latest() -> SessionRestoreSnapshot? {
        snapshots().max { $0.capturedAt < $1.capturedAt }
    }

    // MARK: 合并视图（纯函数，Runner 锁定）

    /// v2 优先的同 id 去重合并；稳定序：v2 在前按传入序，legacy 尾随按传入序
    nonisolated static func merge(v2: [SessionRestoreSnapshot], legacyConverted: [SessionRestoreSnapshot]) -> [SessionRestoreSnapshot] {
        var ids = Set(v2.map(\.id))
        var result = v2
        for entry in legacyConverted where ids.insert(entry.id).inserted {
            result.append(entry)
        }
        return result
    }

    // MARK: 底层 IO

    private func loadV2() -> [SessionRestoreSnapshot] {
        guard let json = store.loadPreference(key: Self.preferenceKey),
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([SessionRestoreSnapshot].self, from: data) else {
            return []
        }
        return list.filter { $0.formatVersion == SessionRestoreSnapshot.currentFormatVersion }
    }

    private func loadLegacy() -> [TerminalGridSnapshot] {
        guard let json = store.loadPreference(key: "terminalGridSnapshots"),
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([TerminalGridSnapshot].self, from: data) else {
            return []
        }
        return list
    }

    private func loadLegacyRaw() -> [TerminalGridSnapshot]? {
        guard let json = store.loadPreference(key: "terminalGridSnapshots"),
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([TerminalGridSnapshot].self, from: data) else {
            return nil
        }
        return list
    }

    private func save(_ list: [SessionRestoreSnapshot]) {
        guard let data = try? JSONEncoder().encode(list),
              let json = String(data: data, encoding: .utf8) else {
            log("[SessionRestore] snapshot encode failed", level: .error)
            return
        }
        store.savePreference(key: Self.preferenceKey, value: json)
    }
}
