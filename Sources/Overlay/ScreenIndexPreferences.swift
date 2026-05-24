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
    var panelScale: CGFloat
    var panelMargin: CGFloat
    var yabaiPath: String?
    var usePerScreenSpaceIndexing: Bool

    static let `default` = ScreenIndexPreferences(
        isEnabled: false,
        position: .topRight,
        fontSize: 48,
        opacity: 0.8,
        textColor: CodableColor(.white),
        backgroundColor: CodableColor(.black.opacity(0.6)),
        panelScale: 1.0,
        panelMargin: 20,
        yabaiPath: nil,
        usePerScreenSpaceIndexing: true
    )

    static let userDefaultsKey = "screenIndexPreferences"

    static func load() -> ScreenIndexPreferences {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.vibefocus.app"
        if let value = CFPreferencesCopyAppValue(userDefaultsKey as CFString, bundleId as CFString),
           let jsonString = value as? String,
           let data = jsonString.data(using: .utf8) {
            do {
                let prefs = try JSONDecoder().decode(ScreenIndexPreferences.self, from: data)
                let migrated = enforcePerScreenSpaceIndexingIfNeeded(prefs)
                log("ScreenIndexPreferences loaded: isEnabled=\(prefs.isEnabled)")
                return migrated
            } catch {
                log("ScreenIndexPreferences decode error: \(error)")
                if let oldPrefs = loadLegacyPreferences(from: data) {
                    log("ScreenIndexPreferences: Loaded legacy preferences with migration")
                    oldPrefs.save()
                    return oldPrefs
                }
            }
        }
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey) {
            do {
                let prefs = try JSONDecoder().decode(ScreenIndexPreferences.self, from: data)
                let migrated = enforcePerScreenSpaceIndexingIfNeeded(prefs)
                log("ScreenIndexPreferences loaded from UserDefaults: isEnabled=\(prefs.isEnabled)")
                return migrated
            } catch {
                log("ScreenIndexPreferences decode error from UserDefaults: \(error)")
                if let oldPrefs = loadLegacyPreferences(from: data) {
                    log("ScreenIndexPreferences: Loaded legacy preferences from UserDefaults with migration")
                    oldPrefs.save()
                    return oldPrefs
                }
            }
        }
        return .default
    }

    private static func loadLegacyPreferences(from data: Data) -> ScreenIndexPreferences? {
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
        guard !preferences.usePerScreenSpaceIndexing else {
            return preferences
        }

        var migrated = preferences
        migrated.usePerScreenSpaceIndexing = true
        log("ScreenIndexPreferences: Migrating global workspace index mode to per-screen mode")
        migrated.save()
        return migrated
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self),
              let jsonString = String(data: data, encoding: .utf8) else {
            log("ScreenIndexPreferences: Failed to encode")
            return
        }
        let bundleId = Bundle.main.bundleIdentifier ?? "com.vibefocus.app"
        CFPreferencesSetAppValue(Self.userDefaultsKey as CFString, jsonString as CFString, bundleId as CFString)
        CFPreferencesAppSynchronize(bundleId as CFString)
        UserDefaults.standard.set(jsonString, forKey: Self.userDefaultsKey)
        PreferencesSync.persistToDisk()
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
