import Foundation

/// Persistent preferences for the terminal window title editor feature.
struct TitleEditorPreferences {
    static let enabledKey = "titleEditorEnabled"
    static let hotKeyEnabledKey = "titleEditorHotKeyEnabled"

    static var isEnabled: Bool {
        get {
            // P-INST-147: title editor enabled UserDefaults 读耗时（object(forKey:) + bool(forKey:) 双读；hotkey 回调 handleFallbackEvent:132 + Carbon handleHotKeyEvent triggerTitleEditor + 设置 UI 读取）。
            let iegStart = Date()
            let value = UserDefaults.standard.object(forKey: enabledKey) != nil ? UserDefaults.standard.bool(forKey: enabledKey) : true
            log("[TitleEditorPreferences] isEnabled get finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: iegStart)),
                "value": String(value)
            ])
            return value
        }
        set {
            // P-INST-147: title editor enabled UserDefaults 写耗时（CFPreferences 同步写；设置 UI toggle）。
            let iesStart = Date()
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            log("[TitleEditorPreferences] isEnabled set finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: iesStart))
            ])
        }
    }

    static var isHotKeyEnabled: Bool {
        get {
            // P-INST-148: title editor hotkey enabled UserDefaults 读耗时（object(forKey:) + bool(forKey:) 双读；hotkey 回调 handleFallbackEvent:133 + 设置 UI 读取）。
            let ihgStart = Date()
            let value = UserDefaults.standard.object(forKey: hotKeyEnabledKey) != nil ? UserDefaults.standard.bool(forKey: hotKeyEnabledKey) : true
            log("[TitleEditorPreferences] isHotKeyEnabled get finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: ihgStart)),
                "value": String(value)
            ])
            return value
        }
        set {
            // P-INST-148: title editor hotkey enabled UserDefaults 写耗时（CFPreferences 同步写；设置 UI toggle）。
            let ihsStart = Date()
            UserDefaults.standard.set(newValue, forKey: hotKeyEnabledKey)
            log("[TitleEditorPreferences] isHotKeyEnabled set finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: ihsStart))
            ])
        }
    }
}
