import Foundation

extension Notification.Name {
    static let layoutHotKeyTableDidChange = Notification.Name("LayoutHotKeyTableDidChange")
}

// MARK: - 摆位热键绑定表
/// action→热键 的多热键表。持久化在 UserDefaults（JSON）；缺失项回落
/// `LayoutAction.defaultBindings`，与主 toggle 键的存储互不干扰。
struct LayoutHotKeyTable: Codable, Equatable {
    var bindings: [String: HotKeyConfiguration]

    static let userDefaultsKey = "layoutHotKeyTable"

    static var withDefaults: LayoutHotKeyTable {
        LayoutHotKeyTable(
            bindings: Dictionary(
                uniqueKeysWithValues: LayoutAction.defaultBindings.map { ($0.key.rawValue, $0.value) }
            )
        )
    }

    func hotKey(for action: LayoutAction) -> HotKeyConfiguration? {
        bindings[action.rawValue] ?? LayoutAction.defaultBindings[action]
    }

    /// 组合键在表内被两个 action 重复占用（录制校验用）
    static func duplicateBinding(in table: LayoutHotKeyTable) -> (actions: [LayoutAction], hotKey: HotKeyConfiguration)? {
        var seen: [HotKeyConfiguration: LayoutAction] = [:]
        for action in LayoutAction.allCases {
            guard let hotKey = table.hotKey(for: action) else { continue }
            if let first = seen[hotKey] {
                return ([first, action], hotKey)
            }
            seen[hotKey] = action
        }
        return nil
    }

    /// 与主 toggle 键撞车检测（共存/录制校验用）
    static func collidesWithToggleHotKey(_ table: LayoutHotKeyTable, toggleHotKey: HotKeyConfiguration) -> LayoutAction? {
        LayoutAction.allCases.first { table.hotKey(for: $0) == toggleHotKey }
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) -> LayoutHotKeyTable? {
        try? JSONDecoder().decode(LayoutHotKeyTable.self, from: data)
    }
}
