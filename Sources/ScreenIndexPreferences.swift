import Foundation
import SwiftUI

// MARK: - Screen Index Position
enum IndexPosition: String, CaseIterable, Codable {
    case topLeft = "topLeft"
    case topCenter = "topCenter"
    case topRight = "topRight"
    case bottomLeft = "bottomLeft"
    case bottomCenter = "bottomCenter"
    case bottomRight = "bottomRight"

    var displayName: String {
        switch self {
        case .topLeft: return "左上角"
        case .topCenter: return "正上方"
        case .topRight: return "右上角"
        case .bottomLeft: return "左下角"
        case .bottomCenter: return "正下方"
        case .bottomRight: return "右下角"
        }
    }

    var icon: String {
        switch self {
        case .topLeft: return "arrow.up.left"
        case .topCenter: return "arrow.up"
        case .topRight: return "arrow.up.right"
        case .bottomLeft: return "arrow.down.left"
        case .bottomCenter: return "arrow.down"
        case .bottomRight: return "arrow.down.right"
        }
    }
}

// MARK: - Screen Index Preferences
struct ScreenIndexPreferences: Codable {
    var isEnabled: Bool
    var position: IndexPosition
    var fontSize: CGFloat
    var opacity: CGFloat
    var textColor: CodableColor
    var backgroundColor: CodableColor
    var panelScale: CGFloat  // 新增：面板缩放比例
    var yabaiPath: String?

    static let `default` = ScreenIndexPreferences(
        isEnabled: false,
        position: .topRight,
        fontSize: 48,
        opacity: 0.8,
        textColor: CodableColor(.white),
        backgroundColor: CodableColor(.black.opacity(0.6)),
        panelScale: 1.0,  // 默认不缩放
        yabaiPath: nil
    )

    static let userDefaultsKey = "screenIndexPreferences"

    static func load() -> ScreenIndexPreferences {
        // 使用 CFPreferences API 读取设置
        let bundleId = Bundle.main.bundleIdentifier ?? "com.openai.vibe-focus"
        if let value = CFPreferencesCopyAppValue(userDefaultsKey as CFString, bundleId as CFString),
           let jsonString = value as? String,
           let data = jsonString.data(using: .utf8) {
            do {
                let prefs = try JSONDecoder().decode(ScreenIndexPreferences.self, from: data)
                log("ScreenIndexPreferences loaded: isEnabled=\(prefs.isEnabled)")
                return prefs
            } catch {
                log("ScreenIndexPreferences decode error: \(error)")
                // 尝试加载旧版本设置（向后兼容）
                if let oldPrefs = loadLegacyPreferences(from: data) {
                    log("ScreenIndexPreferences: Loaded legacy preferences with migration")
                    return oldPrefs
                }
            }
        }
        // 回退到 UserDefaults.standard
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey) {
            do {
                let prefs = try JSONDecoder().decode(ScreenIndexPreferences.self, from: data)
                log("ScreenIndexPreferences loaded from standard: isEnabled=\(prefs.isEnabled)")
                return prefs
            } catch {
                log("ScreenIndexPreferences decode error from standard: \(error)")
                // 尝试加载旧版本设置（向后兼容）
                if let oldPrefs = loadLegacyPreferences(from: data) {
                    log("ScreenIndexPreferences: Loaded legacy preferences from standard with migration")
                    return oldPrefs
                }
            }
        }
        log("ScreenIndexPreferences: Using defaults (isEnabled=false)")
        return .default
    }

    // 向后兼容：加载旧版本设置并迁移到新版本
    private static func loadLegacyPreferences(from data: Data) -> ScreenIndexPreferences? {
        struct LegacyPreferences: Codable {
            var isEnabled: Bool
            var position: IndexPosition
            var fontSize: CGFloat
            var opacity: CGFloat
            var textColor: CodableColor
            var backgroundColor: CodableColor
            var yabaiPath: String?
        }

        do {
            let legacy = try JSONDecoder().decode(LegacyPreferences.self, from: data)
            return ScreenIndexPreferences(
                isEnabled: legacy.isEnabled,
                position: legacy.position,
                fontSize: legacy.fontSize,
                opacity: legacy.opacity,
                textColor: legacy.textColor,
                backgroundColor: legacy.backgroundColor,
                panelScale: 1.0,  // 旧版本没有此字段，使用默认值
                yabaiPath: legacy.yabaiPath
            )
        } catch {
            log("ScreenIndexPreferences: Failed to load legacy preferences: \(error)")
            return nil
        }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self),
              let jsonString = String(data: data, encoding: .utf8) else {
            log("ScreenIndexPreferences: Failed to encode")
            return
        }
        let bundleId = Bundle.main.bundleIdentifier ?? "com.openai.vibe-focus"
        CFPreferencesSetAppValue(Self.userDefaultsKey as CFString, jsonString as CFString, bundleId as CFString)
        CFPreferencesAppSynchronize(bundleId as CFString)
        log("ScreenIndexPreferences: Saved successfully")
    }
}

// MARK: - Codable Color
struct CodableColor: Codable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double

    init(_ color: Color) {
        #if os(macOS)
        let nsColor = NSColor(color)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        nsColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.red = Double(r)
        self.green = Double(g)
        self.blue = Double(b)
        self.opacity = Double(a)
        #else
        self.red = 1
        self.green = 1
        self.blue = 1
        self.opacity = 1
        #endif
    }

    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue, opacity: opacity)
    }
}
