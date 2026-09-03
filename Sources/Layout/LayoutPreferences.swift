import CoreGraphics
import Foundation

// MARK: - 摆位功能偏好
/// UserDefaults 简单 KV；摆位快照类大数据不走这里（归 TerminalGridStore/SQLite）。
enum LayoutPreferences {

    static let enabledKey = "layoutActionsEnabled"
    static let coexistenceChoiceKey = "layoutCoexistenceChoice"
    static let snapGapKey = "layoutSnapGap"

    enum CoexistenceChoice: String {
        case unspecified
        case keepDisabled
        case enableAnyway
    }

    /// 摆位总开关。默认开；共存探测发现竞品运行且用户未做显式选择时会被
    /// CoexistencePolicy 自动置 false（见 WindowLayoutManagerProbe 使用方）。
    static var isEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: enabledKey) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var coexistenceChoice: CoexistenceChoice {
        get {
            guard let raw = UserDefaults.standard.string(forKey: coexistenceChoiceKey) else {
                return .unspecified
            }
            return CoexistenceChoice(rawValue: raw) ?? .unspecified
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: coexistenceChoiceKey) }
    }

    /// 摆位留白（0…40px；0 = Rectangle 默认无缝）
    static var snapGap: CGFloat {
        get {
            let raw = UserDefaults.standard.double(forKey: snapGapKey)
            return CGFloat(min(max(raw, 0), 40))
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: snapGapKey) }
    }
}
