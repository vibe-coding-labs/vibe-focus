import Testing
import Foundation
@testable import VibeFocusKit

@Suite("TitleEditorPreferences", .serialized)
struct TitleEditorPreferencesTests {

    private let enabledKey = "titleEditorEnabled"
    private let hotKeyEnabledKey = "titleEditorHotKeyEnabled"

    @Test("TitleEditorPreferences: defaults to true when not set")
    func defaultsTrue() {
        UserDefaults.standard.removeObject(forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: hotKeyEnabledKey)
        #expect(TitleEditorPreferences.isEnabled)
        #expect(TitleEditorPreferences.isHotKeyEnabled)
    }

    @Test("TitleEditorPreferences: reads and writes isEnabled")
    func isEnabledRoundtrip() {
        UserDefaults.standard.removeObject(forKey: enabledKey)

        TitleEditorPreferences.isEnabled = false
        #expect(UserDefaults.standard.object(forKey: enabledKey) != nil)
        #expect(!TitleEditorPreferences.isEnabled)

        TitleEditorPreferences.isEnabled = true
        #expect(TitleEditorPreferences.isEnabled)

        UserDefaults.standard.removeObject(forKey: enabledKey)
    }

    @Test("TitleEditorPreferences: reads and writes isHotKeyEnabled")
    func isHotKeyEnabledRoundtrip() {
        UserDefaults.standard.removeObject(forKey: hotKeyEnabledKey)

        TitleEditorPreferences.isHotKeyEnabled = false
        #expect(!TitleEditorPreferences.isHotKeyEnabled)

        TitleEditorPreferences.isHotKeyEnabled = true
        #expect(TitleEditorPreferences.isHotKeyEnabled)

        UserDefaults.standard.removeObject(forKey: hotKeyEnabledKey)
    }

    @Test("TitleEditorPreferences: key constants are correct")
    func keyConstants() {
        #expect(TitleEditorPreferences.enabledKey == "titleEditorEnabled")
        #expect(TitleEditorPreferences.hotKeyEnabledKey == "titleEditorHotKeyEnabled")
    }

    @Test("TitleEditorPreferences: explicitly set to false persists")
    func explicitFalse() {
        UserDefaults.standard.removeObject(forKey: enabledKey)
        TitleEditorPreferences.isEnabled = false
        #expect(UserDefaults.standard.object(forKey: enabledKey) != nil)
        #expect(!TitleEditorPreferences.isEnabled)

        UserDefaults.standard.removeObject(forKey: enabledKey)
    }
}
