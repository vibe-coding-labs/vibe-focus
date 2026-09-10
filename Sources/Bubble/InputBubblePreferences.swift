import Foundation

/// 输入气泡功能开关（默认开）。热键三通道（CGEventTap/Carbon/fallback monitor）
/// 都在此闸门后；设置 UI 接入留后续批次，先保证 default 可用 + 可关。
enum InputBubblePreferences {
    private static let enabledKey = "inputBubbleEnabled"

    static var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: enabledKey) != nil
                ? UserDefaults.standard.bool(forKey: enabledKey)
                : true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }
}
