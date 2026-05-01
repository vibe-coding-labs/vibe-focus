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
    var panelMargin: CGFloat  // 新增：面板到屏幕边缘的边距
    var yabaiPath: String?
    var usePerScreenSpaceIndexing: Bool  // 新增：使用屏幕级别的工作区索引

    static let `default` = ScreenIndexPreferences(
        isEnabled: false,
        position: .topRight,
        fontSize: 48,
        opacity: 0.8,
        textColor: CodableColor(.white),
        backgroundColor: CodableColor(.black.opacity(0.6)),
        panelScale: 1.0,  // 默认不缩放
        panelMargin: 20,  // 默认边距 20pt
        yabaiPath: nil,
        usePerScreenSpaceIndexing: true  // 默认使用屏幕级别空间索引
    )

    static let userDefaultsKey = "screenIndexPreferences"

    static func load() -> ScreenIndexPreferences {
        log("ScreenIndexPreferences.load() entered", level: .debug)
        // 使用 CFPreferences API 读取设置
        let bundleId = Bundle.main.bundleIdentifier ?? "com.openai.vibe-focus"
        log("ScreenIndexPreferences.load() reading from CFPreferences", level: .debug, fields: ["bundleId": bundleId])
        if let value = CFPreferencesCopyAppValue(userDefaultsKey as CFString, bundleId as CFString),
           let jsonString = value as? String,
           let data = jsonString.data(using: .utf8) {
            do {
                let prefs = try JSONDecoder().decode(ScreenIndexPreferences.self, from: data)
                let migrated = enforcePerScreenSpaceIndexingIfNeeded(prefs)
                log("ScreenIndexPreferences loaded: isEnabled=\(prefs.isEnabled)")
                log("ScreenIndexPreferences.load() decoded from CFPreferences", level: .debug, fields: [
                    "isEnabled": String(prefs.isEnabled),
                    "position": prefs.position.rawValue
                ])
                return migrated
            } catch {
                log("ScreenIndexPreferences decode error: \(error)")
                log("ScreenIndexPreferences.load() CFPreferences decode failed, trying legacy", level: .debug, fields: ["error": error.localizedDescription])
                // 尝试加载旧版本设置（向后兼容）
                if let oldPrefs = loadLegacyPreferences(from: data) {
                    log("ScreenIndexPreferences: Loaded legacy preferences with migration")
                    oldPrefs.save()
                    return oldPrefs
                }
            }
        }
        // 回退到 UserDefaults.standard
        log("ScreenIndexPreferences.load() falling back to UserDefaults.standard", level: .debug)
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey) {
            do {
                let prefs = try JSONDecoder().decode(ScreenIndexPreferences.self, from: data)
                let migrated = enforcePerScreenSpaceIndexingIfNeeded(prefs)
                log("ScreenIndexPreferences loaded from standard: isEnabled=\(prefs.isEnabled)")
                log("ScreenIndexPreferences.load() decoded from UserDefaults", level: .debug, fields: [
                    "isEnabled": String(prefs.isEnabled),
                    "position": prefs.position.rawValue
                ])
                return migrated
            } catch {
                log("ScreenIndexPreferences decode error from standard: \(error)")
                log("ScreenIndexPreferences.load() UserDefaults decode failed, trying legacy", level: .debug, fields: ["error": error.localizedDescription])
                // 尝试加载旧版本设置（向后兼容）
                if let oldPrefs = loadLegacyPreferences(from: data) {
                    log("ScreenIndexPreferences: Loaded legacy preferences from standard with migration")
                    oldPrefs.save()
                    return oldPrefs
                }
            }
        }
        log("ScreenIndexPreferences: Using defaults (isEnabled=false)")
        log("ScreenIndexPreferences.load() returning defaults", level: .debug)
        return .default
    }

    // 向后兼容：加载旧版本设置并迁移到新版本
    private static func loadLegacyPreferences(from data: Data) -> ScreenIndexPreferences? {
        log("ScreenIndexPreferences.loadLegacyPreferences() entered", level: .debug)
        struct LegacyPreferences: Codable {
            var isEnabled: Bool
            var position: IndexPosition
            var fontSize: CGFloat
            var opacity: CGFloat
            var textColor: CodableColor
            var backgroundColor: CodableColor
            var panelScale: CGFloat?
            var panelMargin: CGFloat?
            var yabaiPath: String?
        }

        do {
            let legacy = try JSONDecoder().decode(LegacyPreferences.self, from: data)
            log("ScreenIndexPreferences.loadLegacyPreferences() decoded legacy format", level: .debug, fields: [
                "isEnabled": String(legacy.isEnabled),
                "position": legacy.position.rawValue,
                "hasPanelScale": String(legacy.panelScale != nil),
                "hasPanelMargin": String(legacy.panelMargin != nil)
            ])
            return ScreenIndexPreferences(
                isEnabled: legacy.isEnabled,
                position: legacy.position,
                fontSize: legacy.fontSize,
                opacity: legacy.opacity,
                textColor: legacy.textColor,
                backgroundColor: legacy.backgroundColor,
                panelScale: legacy.panelScale ?? 1.0,
                panelMargin: legacy.panelMargin ?? 20,
                yabaiPath: legacy.yabaiPath,
                usePerScreenSpaceIndexing: true
            )
        } catch {
            log("ScreenIndexPreferences: Failed to load legacy preferences: \(error)")
            return nil
        }
    }

    private static func enforcePerScreenSpaceIndexingIfNeeded(_ preferences: ScreenIndexPreferences) -> ScreenIndexPreferences {
        log("ScreenIndexPreferences.enforcePerScreenSpaceIndexingIfNeeded() checking", level: .debug, fields: [
            "usePerScreenSpaceIndexing": String(preferences.usePerScreenSpaceIndexing)
        ])
        guard !preferences.usePerScreenSpaceIndexing else {
            log("ScreenIndexPreferences.enforcePerScreenSpaceIndexingIfNeeded() already per-screen, no migration needed", level: .debug)
            return preferences
        }

        var migrated = preferences
        migrated.usePerScreenSpaceIndexing = true
        log("ScreenIndexPreferences: Migrating global workspace index mode to per-screen mode")
        migrated.save()
        log("ScreenIndexPreferences.enforcePerScreenSpaceIndexingIfNeeded() migration completed", level: .debug)
        return migrated
    }

    func save() {
        log("ScreenIndexPreferences.save() entered", level: .debug, fields: [
            "isEnabled": String(isEnabled),
            "position": position.rawValue
        ])
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
