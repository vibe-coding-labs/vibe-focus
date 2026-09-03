import Foundation

// MARK: - 终端网格偏好
enum TerminalGridPreferences {

    static let rowsKey = "terminalGridRows"
    static let colsKey = "terminalGridCols"
    static let displayModeKey = "terminalGridDisplayMode"
    static let appPreferenceKey = "terminalGridApp"
    static let launchCommandKey = "terminalGridLaunchCommand"
    static let gapKey = "terminalGridGap"

    enum DisplayMode: String {
        case main          // 主屏
        case focused       // 焦点窗口所在屏
    }

    enum AppPreference: String {
        case auto          // iTerm2 在运行则用 iTerm2，否则 Terminal.app
        case terminal      // Terminal.app
        case iterm2        // iTerm2
    }

    static var rows: Int {
        get { min(max(UserDefaults.standard.integer(forKey: rowsKey) == 0 ? 2 : UserDefaults.standard.integer(forKey: rowsKey), 1), TerminalGridPlanner.maxGridSize) }
        set { UserDefaults.standard.set(min(max(newValue, 1), TerminalGridPlanner.maxGridSize), forKey: rowsKey) }
    }

    static var cols: Int {
        get { min(max(UserDefaults.standard.integer(forKey: colsKey) == 0 ? 2 : UserDefaults.standard.integer(forKey: colsKey), 1), TerminalGridPlanner.maxGridSize) }
        set { UserDefaults.standard.set(min(max(newValue, 1), TerminalGridPlanner.maxGridSize), forKey: colsKey) }
    }

    static var displayMode: DisplayMode {
        get { DisplayMode(rawValue: UserDefaults.standard.string(forKey: displayModeKey) ?? "") ?? .main }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: displayModeKey) }
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

    static var gap: CGFloat {
        get { CGFloat(min(max(UserDefaults.standard.double(forKey: gapKey) == 0 ? 8 : UserDefaults.standard.double(forKey: gapKey), 0), 40)) }
        set { UserDefaults.standard.set(Double(newValue), forKey: gapKey) }
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
