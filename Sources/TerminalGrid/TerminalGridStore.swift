import Foundation

// MARK: - 终端网格偏好
enum TerminalGridPreferences {

    static let rowsKey = "terminalGridRows"
    static let colsKey = "terminalGridCols"
    static let displayModeKey = "terminalGridDisplayMode"
    static let targetKey = "terminalGridTarget"
    static let appPreferenceKey = "terminalGridApp"
    static let launchCommandKey = "terminalGridLaunchCommand"
    static let gapKey = "terminalGridGap"
    static let autoRestoreEnabledKey = "terminalGridAutoRestoreEnabled"
    static let autoRestoreSnapshotIDKey = "terminalGridAutoRestoreSnapshotID"

    enum AppPreference: String {
        case auto          // iTerm2 在运行则用 iTerm2，否则 Terminal.app
        case terminal      // Terminal.app
        case iterm2        // iTerm2

        /// 「终端应用」行的说明文案（三分支，Runner 穷尽锁定）
        var selectionDetailText: String {
            switch self {
            case .auto:
                return "自动识别你最常用的终端（优先当前在运行者）；也可手动指定。"
            case .terminal:
                return "手动指定 Terminal.app（完整支持：建窗/注入/tty/精确恢复）。"
            case .iterm2:
                return "手动指定 iTerm2（部分支持：无 tty 映射，自动恢复降级为只重建缺失格）。"
            }
        }
    }

    static var rows: Int {
        get { min(max(UserDefaults.standard.integer(forKey: rowsKey) == 0 ? 2 : UserDefaults.standard.integer(forKey: rowsKey), 1), TerminalGridPlanner.maxGridSize) }
        set { UserDefaults.standard.set(min(max(newValue, 1), TerminalGridPlanner.maxGridSize), forKey: rowsKey) }
    }

    static var cols: Int {
        get { min(max(UserDefaults.standard.integer(forKey: colsKey) == 0 ? 2 : UserDefaults.standard.integer(forKey: colsKey), 1), TerminalGridPlanner.maxGridSize) }
        set { UserDefaults.standard.set(min(max(newValue, 1), TerminalGridPlanner.maxGridSize), forKey: colsKey) }
    }

    /// 编排目标（"main"/"focused"/"d<displayID>"/"d<displayID>s<space>"）。
    /// 旧 displayMode（main/focused）在 target 未设置过时自动迁移；
    /// 显式目标失效（屏断开等）由控制器回落并在结果里说明。
    static var target: String {
        get {
            if let raw = UserDefaults.standard.string(forKey: targetKey), GridTargetCode.parse(raw) != nil {
                return raw
            }
            if UserDefaults.standard.string(forKey: displayModeKey) == "focused" {
                return GridTargetCode.focused.code
            }
            return GridTargetCode.main.code
        }
        set { UserDefaults.standard.set(newValue, forKey: targetKey) }
    }

    static var appPreference: AppPreference {
        get { AppPreference(rawValue: UserDefaults.standard.string(forKey: appPreferenceKey) ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: appPreferenceKey) }
    }

    /// 每格启动命令（空 = 纯 shell）。有 session 的格子恢复时优先 --resume。
    static var launchCommand: String {
        get { UserDefaults.standard.string(forKey: launchCommandKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: launchCommandKey) }
    }

    /// 重启 / 登录后自动恢复勾选布局
    static var autoRestoreEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoRestoreEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoRestoreEnabledKey) }
    }

    /// 指定自动恢复的快照；nil = 启动时取最新一份
    static var autoRestoreSnapshotID: String? {
        get {
            let raw = UserDefaults.standard.string(forKey: autoRestoreSnapshotIDKey)
            return (raw?.isEmpty ?? true) ? nil : raw
        }
        set { UserDefaults.standard.set(newValue, forKey: autoRestoreSnapshotIDKey) }
    }

    /// 格子间距（px，Quartz）。默认 0 = Rectangle 式无缝铺满；显式设 0 同样持久
    /// （旧实现 `== 0 ? 8` 把未设置与显式 0 混为一谈，0 永远不生效——已修）。
    static var gap: CGFloat {
        get {
            let raw = UserDefaults.standard.object(forKey: gapKey) as? Double
            return CGFloat(min(max(raw ?? 0, 0), 40))
        }
        set { UserDefaults.standard.set(Double(min(max(newValue, 0), 40)), forKey: gapKey) }
    }
}

// MARK: - 快照持久化
/// 快照列表存 WindowStateStore preferences KV（JSON 数组；ScreenIndexPreferences 模式，
/// 零 migration 成本）。
@MainActor
final class TerminalGridStore {

    static let shared = TerminalGridStore()

    private let store: WindowStateStore
    private static let preferenceKey = "terminalGridSnapshots"

    init(store: WindowStateStore = .shared) {
        self.store = store
    }

    func snapshots() -> [TerminalGridSnapshot] {
        guard let json = store.loadPreference(key: Self.preferenceKey),
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([TerminalGridSnapshot].self, from: data) else {
            return []
        }
        return list
    }

    func upsert(_ snapshot: TerminalGridSnapshot) {
        var list = snapshots()
        if let index = list.firstIndex(where: { $0.id == snapshot.id }) {
            list[index] = snapshot
        } else {
            list.append(snapshot)
        }
        save(list)
    }

    func remove(id: String) {
        save(snapshots().filter { $0.id != id })
    }

    func latest() -> TerminalGridSnapshot? {
        snapshots().max { $0.capturedAt < $1.capturedAt }
    }

    private func save(_ list: [TerminalGridSnapshot]) {
        guard let data = try? JSONEncoder().encode(list),
              let json = String(data: data, encoding: .utf8) else {
            log("[TerminalGrid] snapshot encode failed", level: .error)
            return
        }
        store.savePreference(key: Self.preferenceKey, value: json)
    }
}
