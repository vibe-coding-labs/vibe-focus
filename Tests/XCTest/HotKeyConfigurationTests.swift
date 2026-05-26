import Testing
import Carbon
import Foundation
@testable import VibeFocusKit

@Suite("HotKeyConfiguration Display")
struct HotKeyConfigurationTests {

    // MARK: - displayKey

    @Test("displayKey: A-Z mapped correctly")
    func displayKeyLetters() {
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_ANSI_A)) == "A")
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_ANSI_Z)) == "Z")
    }

    @Test("displayKey: 0-9 mapped correctly")
    func displayKeyNumbers() {
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_ANSI_0)) == "0")
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_ANSI_9)) == "9")
    }

    @Test("displayKey: special keys mapped correctly")
    func displayKeySpecial() {
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_Space)) == "Space")
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_Return)) == "Return")
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_Escape)) == "Esc")
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_Delete)) == "Delete")
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_Tab)) == "Tab")
    }

    @Test("displayKey: arrow keys mapped")
    func displayKeyArrows() {
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_LeftArrow)) == "←")
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_RightArrow)) == "→")
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_UpArrow)) == "↑")
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_DownArrow)) == "↓")
    }

    @Test("displayKey: F-keys mapped")
    func displayKeyFunctionKeys() {
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_F1)) == "F1")
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_F12)) == "F12")
    }

    @Test("displayKey: unknown keyCode returns '?'")
    func displayKeyUnknown() {
        #expect(HotKeyConfiguration.displayKey(for: UInt32(255)) == "?")
    }

    @Test("displayKey: forward delete mapped to Fn⌫")
    func displayKeyForwardDelete() {
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_ForwardDelete)) == "Fn⌫")
    }

    // MARK: - displayString (modifier symbols + key)

    @Test("displayString: Ctrl+Q")
    func displayStringCtrlQ() {
        let config = HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(controlKey))
        #expect(config.displayString == "⌃Q")
    }

    @Test("displayString: Cmd+Opt+M")
    func displayStringCmdOptM() {
        let config = HotKeyConfiguration(
            keyCode: UInt32(kVK_ANSI_M),
            modifiers: UInt32(cmdKey | optionKey)
        )
        #expect(config.displayString == "⌥⌘M")
    }

    @Test("displayString: Ctrl+Cmd+Opt+M (legacy default)")
    func displayStringLegacyDefault() {
        let config = HotKeyConfiguration.legacyDefault
        #expect(config.displayString.contains("⌃"))
        #expect(config.displayString.contains("⌥"))
        #expect(config.displayString.contains("⌘"))
        #expect(config.displayString.contains("M"))
    }

    @Test("displayString: no modifiers shows only key")
    func displayStringNoModifiers() {
        let config = HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_A), modifiers: 0)
        #expect(config.displayString == "A")
    }

    @Test("displayString: Shift+Ctrl+Space")
    func displayStringShiftCtrlSpace() {
        let config = HotKeyConfiguration(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(shiftKey | controlKey)
        )
        #expect(config.displayString == "⌃⇧Space")
    }

    // MARK: - knownConflicts

    @Test("knownConflicts: includes Cmd+Space (Spotlight)")
    func knownConflictsSpotlight() {
        let spotlight = HotKeyConfiguration(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey)
        )
        let hasConflict = HotKeyConfiguration.knownConflicts.contains { $0.configuration == spotlight }
        #expect(hasConflict)
    }

    @Test("knownConflicts: includes Cmd+Tab")
    func knownConflictsTab() {
        let tab = HotKeyConfiguration(
            keyCode: UInt32(kVK_Tab),
            modifiers: UInt32(cmdKey)
        )
        let hasConflict = HotKeyConfiguration.knownConflicts.contains { $0.configuration == tab }
        #expect(hasConflict)
    }

    // MARK: - Codable roundtrip

    @Test("HotKeyConfiguration: Codable roundtrip")
    func codableRoundtrip() throws {
        let config = HotKeyConfiguration(keyCode: 42, modifiers: 7)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(HotKeyConfiguration.self, from: data)
        #expect(decoded.keyCode == 42)
        #expect(decoded.modifiers == 7)
    }

    @Test("HotKeyConfiguration: Equatable")
    func equatable() {
        let a = HotKeyConfiguration(keyCode: 10, modifiers: 5)
        let b = HotKeyConfiguration(keyCode: 10, modifiers: 5)
        let c = HotKeyConfiguration(keyCode: 11, modifiers: 5)
        #expect(a == b)
        #expect(a != c)
    }
}
