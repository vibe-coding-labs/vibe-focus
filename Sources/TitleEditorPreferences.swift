import Foundation

struct TitleEditorPreferences {
    static let enabledKey = "titleEditorEnabled"
    static let hotKeyEnabledKey = "titleEditorHotKeyEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) != nil ? UserDefaults.standard.bool(forKey: enabledKey) : true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var isHotKeyEnabled: Bool {
        get { UserDefaults.standard.object(forKey: hotKeyEnabledKey) != nil ? UserDefaults.standard.bool(forKey: hotKeyEnabledKey) : true }
        set { UserDefaults.standard.set(newValue, forKey: hotKeyEnabledKey) }
    }
}
