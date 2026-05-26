import Testing
import Foundation
import Carbon
@testable import VibeFocusKit

@Suite("Preferences Consistency")
struct PreferencesSyncTests {

    // MARK: - configFilePath

    @Test("configFilePath ends with .vibefocus/config.json")
    func configFilePath() {
        #expect(PreferencesSync.configFilePath.hasSuffix(".vibefocus/config.json"))
    }

    @Test("configFilePath starts with home directory")
    func configFilePathHome() {
        #expect(PreferencesSync.configFilePath.hasPrefix(NSHomeDirectory()))
    }

    // MARK: - ClaudeHookPreferences default value consistency

    @Test("ClaudeHookPreferences default values match expected constants")
    func claudeHookDefaults() {
        #expect(ClaudeHookPreferences.defaultEnabled == false)
        #expect(ClaudeHookPreferences.defaultPort == 39277)
        #expect(ClaudeHookPreferences.defaultAutoFocusOnSessionEnd == true)
        #expect(ClaudeHookPreferences.defaultTriggerOnStop == true)
        #expect(ClaudeHookPreferences.defaultTriggerOnSessionEnd == true)
        #expect(ClaudeHookPreferences.defaultAutoRestoreOnPromptSubmit == true)
    }

    @Test("ClaudeHookPreferences keys are stable strings")
    func claudeHookKeys() {
        #expect(ClaudeHookPreferences.enabledKey == "claudeHookEnabled")
        #expect(ClaudeHookPreferences.portKey == "claudeHookPort")
        #expect(ClaudeHookPreferences.autoFocusOnSessionEndKey == "claudeHookAutoFocusOnSessionEnd")
        #expect(ClaudeHookPreferences.triggerOnStopKey == "claudeHookTriggerOnStop")
        #expect(ClaudeHookPreferences.triggerOnSessionEndKey == "claudeHookTriggerOnSessionEnd")
        #expect(ClaudeHookPreferences.autoRestoreOnPromptSubmitKey == "claudeHookAutoRestoreOnPromptSubmit")
    }

    // MARK: - SpacePreferences default consistency

    @Test("SpacePreferences default values")
    func spacePreferencesDefaults() {
        #expect(SpacePreferences.defaultIntegrationEnabled == true)
        #expect(SpacePreferences.defaultRestoreStrategy == .switchToOriginal)
        #expect(SpacePreferences.integrationEnabledKey == "spaceIntegrationEnabled")
        #expect(SpacePreferences.restoreStrategyKey == "spaceRestoreStrategy")
    }

    // MARK: - LANHookPreferences defaults

    @Test("LANHookPreferences default values")
    func lanHookDefaults() {
        #expect(LANHookPreferences.defaultLanMode == false)
        #expect(LANHookPreferences.lanModeKey == "claudeHookLanMode")
    }

    // MARK: - HotKeyConfiguration defaults

    @Test("HotKeyConfiguration default exists")
    func hotKeyDefaults() {
        let config = HotKeyConfiguration.default
        #expect(config.keyCode == UInt32(kVK_ANSI_Q))
        #expect(config.modifiers == UInt32(controlKey))
    }

    @Test("HotKeyConfiguration userDefaultsKey is stable")
    func hotKeyKey() {
        #expect(HotKeyConfiguration.userDefaultsKey == "hotKeyConfiguration")
    }

    // MARK: - PreferenceValue type detection

    @Test("PreferenceValue writeToUserDefaults/readFromUserDefaults roundtrip for bool")
    func preferenceValueBoolRoundtrip() {
        let key = "test_pref_bool_roundtrip"
        UserDefaults.standard.removeObject(forKey: key)
        PreferenceValue.bool(true).writeToUserDefaults(key: key)
        let read = PreferenceValue.readFromUserDefaults(key: key)
        if case .bool(let v) = read {
            #expect(v == true)
        } else {
            Issue.record("Expected .bool, got \(String(describing: read))")
        }
        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test("PreferenceValue writeToUserDefaults/readFromUserDefaults roundtrip for int")
    func preferenceValueIntRoundtrip() {
        let key = "test_pref_int_roundtrip"
        UserDefaults.standard.removeObject(forKey: key)
        PreferenceValue.int(42).writeToUserDefaults(key: key)
        let read = PreferenceValue.readFromUserDefaults(key: key)
        if case .int(let v) = read {
            #expect(v == 42)
        } else {
            Issue.record("Expected .int, got \(String(describing: read))")
        }
        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test("PreferenceValue writeToUserDefaults/readFromUserDefaults roundtrip for string")
    func preferenceValueStringRoundtrip() {
        let key = "test_pref_string_roundtrip"
        UserDefaults.standard.removeObject(forKey: key)
        PreferenceValue.string("hello").writeToUserDefaults(key: key)
        let read = PreferenceValue.readFromUserDefaults(key: key)
        if case .string(let v) = read {
            #expect(v == "hello")
        } else {
            Issue.record("Expected .string, got \(String(describing: read))")
        }
        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test("PreferenceValue readFromUserDefaults returns nil for missing key")
    func preferenceValueMissingKey() {
        let key = "test_pref_nonexistent_key_\(UUID().uuidString)"
        let read = PreferenceValue.readFromUserDefaults(key: key)
        #expect(read == nil)
    }
}
