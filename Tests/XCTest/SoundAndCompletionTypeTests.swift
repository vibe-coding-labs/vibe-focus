import Testing
import Foundation
@testable import VibeFocusKit

@Suite("Sound and CompletionSoundType")
struct SoundAndCompletionTypeTests {

    // MARK: - CompletionSoundType

    @Test("CompletionSoundType: has 7 cases")
    func caseCount() {
        #expect(CompletionSoundType.allCases.count == 7)
    }

    @Test("CompletionSoundType: raw values")
    func rawValues() {
        #expect(CompletionSoundType.none.rawValue == "none")
        #expect(CompletionSoundType.systemDefault.rawValue == "system_default")
        #expect(CompletionSoundType.builtinDing.rawValue == "builtin_ding")
        #expect(CompletionSoundType.builtinPing.rawValue == "builtin_ping")
        #expect(CompletionSoundType.builtinComplete.rawValue == "builtin_complete")
        #expect(CompletionSoundType.builtinAreYouOk.rawValue == "builtin_are_you_ok")
        #expect(CompletionSoundType.custom.rawValue == "custom")
    }

    @Test("CompletionSoundType: isBuiltin returns true for built-in types")
    func isBuiltinTrue() {
        #expect(CompletionSoundType.builtinDing.isBuiltin)
        #expect(CompletionSoundType.builtinPing.isBuiltin)
        #expect(CompletionSoundType.builtinComplete.isBuiltin)
        #expect(CompletionSoundType.builtinAreYouOk.isBuiltin)
    }

    @Test("CompletionSoundType: isBuiltin returns false for non-built-in types")
    func isBuiltinFalse() {
        #expect(!CompletionSoundType.none.isBuiltin)
        #expect(!CompletionSoundType.systemDefault.isBuiltin)
        #expect(!CompletionSoundType.custom.isBuiltin)
    }

    @Test("CompletionSoundType: displayName is non-empty for all cases")
    func displayNamesNonEmpty() {
        for soundType in CompletionSoundType.allCases {
            #expect(!soundType.displayName.isEmpty)
        }
    }

    @Test("CompletionSoundType: Codable roundtrip")
    func codableRoundtrip() throws {
        for soundType in CompletionSoundType.allCases {
            let data = try JSONEncoder().encode(soundType)
            let decoded = try JSONDecoder().decode(CompletionSoundType.self, from: data)
            #expect(decoded == soundType)
        }
    }

    // MARK: - SoundPreferences

    @Test("SoundPreferences: default values")
    func defaultValues() {
        let prefs = SoundPreferences.default
        #expect(prefs.soundType == .none)
        #expect(prefs.customSoundPath == nil)
        #expect(prefs.volume == 0.7)
    }

    @Test("SoundPreferences: Codable roundtrip")
    func preferencesCodable() throws {
        let prefs = SoundPreferences(soundType: .builtinDing, customSoundPath: "/path/to/sound.wav", volume: 0.5)
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(SoundPreferences.self, from: data)
        #expect(decoded.soundType == .builtinDing)
        #expect(decoded.customSoundPath == "/path/to/sound.wav")
        #expect(decoded.volume == 0.5)
    }
}
