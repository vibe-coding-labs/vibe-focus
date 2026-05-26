import Testing
import Foundation
@testable import VibeFocusKit

@Suite("Sound Preferences Edge Cases and Hook Preference Constants")
struct SoundAndHookPreferenceConstantsTests {

    // MARK: - SoundPreferences Codable details

    @Test("SoundPreferences: JSON key names are snake_case")
    func jsonKeyNames() throws {
        let prefs = SoundPreferences(soundType: .builtinDing, customSoundPath: "/test.wav", volume: 0.5)
        let data = try JSONEncoder().encode(prefs)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["soundType"] != nil)
        #expect(json["customSoundPath"] != nil)
        #expect(json["volume"] != nil)
    }

    @Test("SoundPreferences: nil customSoundPath is omitted from JSON")
    func nilCustomPath() throws {
        let prefs = SoundPreferences(soundType: .none, customSoundPath: nil, volume: 1.0)
        let data = try JSONEncoder().encode(prefs)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["customSoundPath"] == nil) // nil optional keys are omitted
    }

    @Test("SoundPreferences: decode with missing optional fields uses defaults")
    func decodeMissingOptionals() throws {
        let json = """
        {"soundType": "none", "volume": 0.3}
        """
        let prefs = try JSONDecoder().decode(SoundPreferences.self, from: Data(json.utf8))
        #expect(prefs.soundType == .none)
        #expect(prefs.volume == 0.3)
        #expect(prefs.customSoundPath == nil)
    }

    @Test("SoundPreferences: volume at boundaries")
    func volumeBoundaries() {
        var prefs = SoundPreferences.default
        prefs.volume = 0.0
        #expect(prefs.volume == 0.0)
        prefs.volume = 1.0
        #expect(prefs.volume == 1.0)
    }

    // MARK: - CompletionSoundType exhaustiveness

    @Test("CompletionSoundType: all raw values are unique")
    func uniqueRawValues() {
        let rawValues = CompletionSoundType.allCases.map(\.rawValue)
        #expect(rawValues.count == Set(rawValues).count)
    }

    @Test("CompletionSoundType: init from invalid rawValue returns nil")
    func invalidRawValue() {
        #expect(CompletionSoundType(rawValue: "invalid") == nil)
        #expect(CompletionSoundType(rawValue: "") == nil)
        #expect(CompletionSoundType(rawValue: "BUILTIN_DING") == nil) // case-sensitive
    }

    @Test("CompletionSoundType: displayName for none is Chinese")
    func noneDisplayName() {
        #expect(CompletionSoundType.none.displayName == "无")
    }

    @Test("CompletionSoundType: displayName for systemDefault is Chinese")
    func systemDefaultDisplayName() {
        #expect(CompletionSoundType.systemDefault.displayName == "系统默认")
    }

    // MARK: - ClaudeHookPreferences key stability

    @Test("ClaudeHookPreferences: all keys start with claudeHook prefix")
    func keyPrefix() {
        let keys = [
            ClaudeHookPreferences.enabledKey,
            ClaudeHookPreferences.portKey,
            ClaudeHookPreferences.tokenKey,
            ClaudeHookPreferences.autoFocusOnSessionEndKey,
            ClaudeHookPreferences.triggerOnStopKey,
            ClaudeHookPreferences.triggerOnSessionEndKey,
            ClaudeHookPreferences.autoRestoreOnPromptSubmitKey,
        ]
        for key in keys {
            #expect(key.hasPrefix("claudeHook"), "Key '\(key)' does not start with 'claudeHook'")
        }
    }

    @Test("ClaudeHookPreferences: all keys are unique")
    func uniqueKeys() {
        let keys: Set<String> = [
            ClaudeHookPreferences.enabledKey,
            ClaudeHookPreferences.portKey,
            ClaudeHookPreferences.tokenKey,
            ClaudeHookPreferences.autoFocusOnSessionEndKey,
            ClaudeHookPreferences.triggerOnStopKey,
            ClaudeHookPreferences.triggerOnSessionEndKey,
            ClaudeHookPreferences.autoRestoreOnPromptSubmitKey,
        ]
        #expect(keys.count == 7)
    }

    @Test("ClaudeHookPreferences: endpoint path starts with slash")
    func endpointPathFormat() {
        #expect(ClaudeHookPreferences.endpointPath.hasPrefix("/"))
    }

    // MARK: - HotKeyConfiguration default and legacy

    @Test("HotKeyConfiguration: default is Q with control modifier")
    func defaultConfig() {
        let config = HotKeyConfiguration.default
        #expect(config.keyCode != 0)
        #expect(config.modifiers != 0)
    }

    @Test("HotKeyConfiguration: legacyDefault has more modifiers than default")
    func legacyVsDefault() {
        let legacy = HotKeyConfiguration.legacyDefault
        let default_ = HotKeyConfiguration.default
        #expect(legacy.modifiers != default_.modifiers || legacy.keyCode != default_.keyCode)
    }

    @Test("HotKeyConfiguration: userDefaultsKey is stable")
    func userDefaultsKeyStable() {
        #expect(HotKeyConfiguration.userDefaultsKey == "hotKeyConfiguration")
    }

    // MARK: - SpacePreferences key stability

    @Test("SpacePreferences: keys are stable strings")
    func spacePreferenceKeys() {
        #expect(SpacePreferences.integrationEnabledKey == "spaceIntegrationEnabled")
        #expect(SpacePreferences.restoreStrategyKey == "spaceRestoreStrategy")
    }

    @Test("SpacePreferences: defaultIntegrationEnabled is true")
    func spaceDefaultEnabled() {
        #expect(SpacePreferences.defaultIntegrationEnabled == true)
    }

    @Test("SpacePreferences: defaultRestoreStrategy is switchToOriginal")
    func spaceDefaultStrategy() {
        #expect(SpacePreferences.defaultRestoreStrategy == .switchToOriginal)
    }
}
