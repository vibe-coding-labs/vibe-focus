import Testing
import Foundation
@testable import VibeFocusKit

@Suite("SoundManager Types")
struct SoundAndTitleTests {

    // MARK: - CompletionSoundType allCases

    @Test("CompletionSoundType has 7 cases")
    func allCasesCount() {
        #expect(CompletionSoundType.allCases.count == 7)
    }

    @Test("CompletionSoundType allCases contains all variants")
    func allCasesContainsAll() {
        let all = Set(CompletionSoundType.allCases)
        #expect(all.contains(.none))
        #expect(all.contains(.systemDefault))
        #expect(all.contains(.builtinDing))
        #expect(all.contains(.builtinPing))
        #expect(all.contains(.builtinComplete))
        #expect(all.contains(.builtinAreYouOk))
        #expect(all.contains(.custom))
    }

    // MARK: - CompletionSoundType rawValues

    @Test("CompletionSoundType rawValue for none")
    func rawValueNone() {
        #expect(CompletionSoundType.none.rawValue == "none")
    }

    @Test("CompletionSoundType rawValue for systemDefault")
    func rawValueSystemDefault() {
        #expect(CompletionSoundType.systemDefault.rawValue == "system_default")
    }

    @Test("CompletionSoundType rawValue for builtinDing")
    func rawValueBuiltinDing() {
        #expect(CompletionSoundType.builtinDing.rawValue == "builtin_ding")
    }

    @Test("CompletionSoundType rawValue for builtinPing")
    func rawValueBuiltinPing() {
        #expect(CompletionSoundType.builtinPing.rawValue == "builtin_ping")
    }

    @Test("CompletionSoundType rawValue for builtinComplete")
    func rawValueBuiltinComplete() {
        #expect(CompletionSoundType.builtinComplete.rawValue == "builtin_complete")
    }

    @Test("CompletionSoundType rawValue for builtinAreYouOk")
    func rawValueBuiltinAreYouOk() {
        #expect(CompletionSoundType.builtinAreYouOk.rawValue == "builtin_are_you_ok")
    }

    @Test("CompletionSoundType rawValue for custom")
    func rawValueCustom() {
        #expect(CompletionSoundType.custom.rawValue == "custom")
    }

    @Test("CompletionSoundType init from rawValue")
    func initFromRawValue() {
        let noneType: CompletionSoundType? = CompletionSoundType(rawValue: "none")
        #expect(noneType != nil)
        #expect(noneType == CompletionSoundType.none)
        #expect(CompletionSoundType(rawValue: "system_default") == .systemDefault)
        #expect(CompletionSoundType(rawValue: "builtin_ding") == .builtinDing)
        #expect(CompletionSoundType(rawValue: "custom") == .custom)
        #expect(CompletionSoundType(rawValue: "nonexistent") == nil)
    }

    // MARK: - CompletionSoundType displayName

    @Test("displayName for none")
    func displayNameNone() {
        #expect(CompletionSoundType.none.displayName == "无")
    }

    @Test("displayName for systemDefault")
    func displayNameSystemDefault() {
        #expect(CompletionSoundType.systemDefault.displayName == "系统默认")
    }

    @Test("displayName for builtinDing")
    func displayNameDing() {
        #expect(CompletionSoundType.builtinDing.displayName == "Ding")
    }

    @Test("displayName for builtinPing")
    func displayNamePing() {
        #expect(CompletionSoundType.builtinPing.displayName == "Ping")
    }

    @Test("displayName for builtinComplete")
    func displayNameComplete() {
        #expect(CompletionSoundType.builtinComplete.displayName == "Complete")
    }

    @Test("displayName for builtinAreYouOk")
    func displayNameAreYouOk() {
        #expect(CompletionSoundType.builtinAreYouOk.displayName == "Are You OK")
    }

    @Test("displayName for custom")
    func displayNameCustom() {
        #expect(CompletionSoundType.custom.displayName == "自定义文件")
    }

    // MARK: - CompletionSoundType isBuiltin

    @Test("isBuiltin returns true for builtin sounds")
    func isBuiltinTrue() {
        #expect(CompletionSoundType.builtinDing.isBuiltin)
        #expect(CompletionSoundType.builtinPing.isBuiltin)
        #expect(CompletionSoundType.builtinComplete.isBuiltin)
        #expect(CompletionSoundType.builtinAreYouOk.isBuiltin)
    }

    @Test("isBuiltin returns false for non-builtin sounds")
    func isBuiltinFalse() {
        #expect(!CompletionSoundType.none.isBuiltin)
        #expect(!CompletionSoundType.systemDefault.isBuiltin)
        #expect(!CompletionSoundType.custom.isBuiltin)
    }

    // MARK: - SoundPreferences Codable roundtrip

    @Test("SoundPreferences Codable roundtrip with defaults")
    func soundPreferencesCodableDefault() throws {
        let prefs = SoundPreferences.default
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(SoundPreferences.self, from: data)
        #expect(decoded.soundType == .none)
        #expect(decoded.customSoundPath == nil)
        #expect(decoded.volume == 0.7)
    }

    @Test("SoundPreferences Codable roundtrip with custom values")
    func soundPreferencesCodableCustom() throws {
        let prefs = SoundPreferences(
            soundType: .builtinDing,
            customSoundPath: "/path/to/sound.wav",
            volume: 0.5
        )
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(SoundPreferences.self, from: data)
        #expect(decoded.soundType == .builtinDing)
        #expect(decoded.customSoundPath == "/path/to/sound.wav")
        #expect(decoded.volume == 0.5)
    }

    @Test("SoundPreferences Codable roundtrip with custom type and nil path")
    func soundPreferencesCodableCustomNilPath() throws {
        let prefs = SoundPreferences(
            soundType: .custom,
            customSoundPath: nil,
            volume: 1.0
        )
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(SoundPreferences.self, from: data)
        #expect(decoded.soundType == .custom)
        #expect(decoded.customSoundPath == nil)
        #expect(decoded.volume == 1.0)
    }

    @Test("SoundPreferences default has correct values")
    func soundPreferencesDefaultValues() {
        #expect(SoundPreferences.default.soundType == .none)
        #expect(SoundPreferences.default.customSoundPath == nil)
        #expect(SoundPreferences.default.volume == 0.7)
    }

    @Test("SoundPreferences encoding includes all fields")
    func soundPreferencesEncodingFields() throws {
        let prefs = SoundPreferences(
            soundType: .systemDefault,
            customSoundPath: nil,
            volume: 0.3
        )
        let data = try JSONEncoder().encode(prefs)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["soundType"] as? String == "system_default")
        #expect(json["volume"] as? Double == 0.3)
        // customSoundPath should be nil/absent or null
        let path = json["customSoundPath"] as? String
        #expect(path == nil)
    }

    @Test("SoundPreferences volume at boundaries")
    func soundPreferencesVolumeBoundaries() throws {
        let zeroVol = SoundPreferences(soundType: .none, customSoundPath: nil, volume: 0.0)
        let data0 = try JSONEncoder().encode(zeroVol)
        let decoded0 = try JSONDecoder().decode(SoundPreferences.self, from: data0)
        #expect(decoded0.volume == 0.0)

        let maxVol = SoundPreferences(soundType: .none, customSoundPath: nil, volume: 1.0)
        let data1 = try JSONEncoder().encode(maxVol)
        let decoded1 = try JSONDecoder().decode(SoundPreferences.self, from: data1)
        #expect(decoded1.volume == 1.0)
    }
}
