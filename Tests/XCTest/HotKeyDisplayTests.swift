import Testing
import Foundation
import Carbon
@testable import VibeFocusKit

@Suite("HotKeyConfiguration Display")
struct HotKeyDisplayTests {

    // MARK: - displayKey letter mapping

    @Test("displayKey maps kVK_ANSI_A to 'A'")
    func displayKeyA() {
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_ANSI_A)) == "A")
    }

    @Test("displayKey maps kVK_ANSI_Z to 'Z'")
    func displayKeyZ() {
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_ANSI_Z)) == "Z")
    }

    @Test("displayKey maps kVK_ANSI_M to 'M'")
    func displayKeyM() {
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_ANSI_M)) == "M")
    }

    @Test("displayKey maps kVK_ANSI_Q to 'Q'")
    func displayKeyQ() {
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_ANSI_Q)) == "Q")
    }

    // MARK: - displayKey number mapping

    @Test("displayKey maps kVK_ANSI_0 to '0'")
    func displayKey0() {
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_ANSI_0)) == "0")
    }

    @Test("displayKey maps kVK_ANSI_9 to '9'")
    func displayKey9() {
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_ANSI_9)) == "9")
    }

    // MARK: - displayKey special keys

    @Test("displayKey maps kVK_Space to 'Space'")
    func displayKeySpace() {
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_Space)) == "Space")
    }

    @Test("displayKey maps kVK_Return to 'Return'")
    func displayKeyReturn() {
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_Return)) == "Return")
    }

    @Test("displayKey maps kVK_Escape to 'Esc'")
    func displayKeyEscape() {
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_Escape)) == "Esc")
    }

    @Test("displayKey maps kVK_Delete to 'Delete'")
    func displayKeyDelete() {
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_Delete)) == "Delete")
    }

    @Test("displayKey maps kVK_ForwardDelete to 'Fn⌫'")
    func displayKeyForwardDelete() {
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_ForwardDelete)) == "Fn⌫")
    }

    @Test("displayKey maps kVK_Tab to 'Tab'")
    func displayKeyTab() {
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_Tab)) == "Tab")
    }

    // MARK: - displayKey arrow keys

    @Test("displayKey maps arrow keys to Unicode arrows")
    func displayKeyArrows() {
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_LeftArrow)) == "←")
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_RightArrow)) == "→")
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_UpArrow)) == "↑")
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_DownArrow)) == "↓")
    }

    // MARK: - displayKey F-keys

    @Test("displayKey maps F1 through F12")
    func displayKeyFKeys() {
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_F1)) == "F1")
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_F2)) == "F2")
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_F3)) == "F3")
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_F4)) == "F4")
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_F5)) == "F5")
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_F6)) == "F6")
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_F7)) == "F7")
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_F8)) == "F8")
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_F9)) == "F9")
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_F10)) == "F10")
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_F11)) == "F11")
        #expect(HotKeyConfiguration.displayKey(for: UInt32(kVK_F12)) == "F12")
    }

    // MARK: - displayKey unknown

    @Test("displayKey returns '?' for unknown key code")
    func displayKeyUnknown() {
        #expect(HotKeyConfiguration.displayKey(for: UInt32(200)) == "?")
    }

    @Test("displayKey returns '?' for key code 0")
    func displayKeyZero() {
        // kVK_ANSI_A is 0 — so key code 0 is actually 'A'
        #expect(HotKeyConfiguration.displayKey(for: UInt32(0)) == "A")
    }

    // MARK: - modifierDisplay

    @Test("modifierDisplay: control only shows ⌃")
    func modifierControlOnly() {
        let config = HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey))
        #expect(config.displayString == "⌃A")
    }

    @Test("modifierDisplay: option only shows ⌥")
    func modifierOptionOnly() {
        let config = HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey))
        #expect(config.displayString == "⌥A")
    }

    @Test("modifierDisplay: shift only shows ⇧")
    func modifierShiftOnly() {
        let config = HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(shiftKey))
        #expect(config.displayString == "⇧A")
    }

    @Test("modifierDisplay: cmd only shows ⌘")
    func modifierCmdOnly() {
        let config = HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey))
        #expect(config.displayString == "⌘A")
    }

    @Test("modifierDisplay: control+option shows ⌃⌥ in correct order")
    func modifierControlOption() {
        let config = HotKeyConfiguration(
            keyCode: UInt32(kVK_ANSI_Q),
            modifiers: UInt32(controlKey | optionKey)
        )
        #expect(config.displayString == "⌃⌥Q")
    }

    @Test("modifierDisplay: all modifiers shows ⌃⌥⇧⌘ in correct order")
    func modifierAll() {
        let config = HotKeyConfiguration(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey)
        )
        #expect(config.displayString == "⌃⌥⇧⌘Space")
    }

    @Test("modifierDisplay: no modifiers shows only key")
    func modifierNone() {
        let config = HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_M), modifiers: 0)
        #expect(config.displayString == "M")
    }

    @Test("modifierDisplay: default config shows ⌃Q")
    func defaultConfigDisplay() {
        let config = HotKeyConfiguration.default
        #expect(config.displayString == "⌃Q")
    }

    // MARK: - HotKeyConfiguration Codable

    @Test("HotKeyConfiguration Codable roundtrip")
    func hotKeyCodableRoundtrip() throws {
        let config = HotKeyConfiguration(
            keyCode: UInt32(kVK_ANSI_M),
            modifiers: UInt32(controlKey | optionKey)
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(HotKeyConfiguration.self, from: data)
        #expect(decoded.keyCode == config.keyCode)
        #expect(decoded.modifiers == config.modifiers)
    }

    @Test("HotKeyConfiguration Codable roundtrip for default")
    func hotKeyCodableDefault() throws {
        let config = HotKeyConfiguration.default
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(HotKeyConfiguration.self, from: data)
        #expect(decoded == config)
    }

    @Test("HotKeyConfiguration Codable roundtrip for legacy default")
    func hotKeyCodableLegacy() throws {
        let config = HotKeyConfiguration.legacyDefault
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(HotKeyConfiguration.self, from: data)
        #expect(decoded == config)
    }

    // MARK: - HotKeyConfiguration Equatable

    @Test("HotKeyConfiguration equality")
    func hotKeyEquality() {
        let a = HotKeyConfiguration(keyCode: 12, modifiers: 4096)
        let b = HotKeyConfiguration(keyCode: 12, modifiers: 4096)
        #expect(a == b)
    }

    @Test("HotKeyConfiguration inequality by keyCode")
    func hotKeyInequalityKeyCode() {
        let a = HotKeyConfiguration(keyCode: 12, modifiers: 4096)
        let b = HotKeyConfiguration(keyCode: 13, modifiers: 4096)
        #expect(a != b)
    }

    @Test("HotKeyConfiguration inequality by modifiers")
    func hotKeyInequalityModifiers() {
        let a = HotKeyConfiguration(keyCode: 12, modifiers: 4096)
        let b = HotKeyConfiguration(keyCode: 12, modifiers: 2048)
        #expect(a != b)
    }

    // MARK: - knownConflicts

    @Test("knownConflicts contains expected entries")
    func knownConflictsNotEmpty() {
        #expect(!HotKeyConfiguration.knownConflicts.isEmpty)
        // Check a specific conflict: Cmd+Space conflicts with Spotlight
        let spotlightConflict = HotKeyConfiguration.knownConflicts.first {
            $0.configuration.keyCode == UInt32(kVK_Space) &&
            $0.configuration.modifiers == UInt32(cmdKey)
        }
        #expect(spotlightConflict != nil)
        #expect(spotlightConflict?.reason.contains("Spotlight") == true)
    }

    // MARK: - userDefaultsKey

    @Test("userDefaultsKey is set")
    func userDefaultsKey() {
        #expect(HotKeyConfiguration.userDefaultsKey == "hotKeyConfiguration")
    }
}
