import Testing
import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

@Suite("HotKeyConfiguration Event Matching")
struct HotKeyEventMatchingTests {

    // MARK: - matches(event:)

    @Test("matches: matching keyCode and modifiers → true")
    func matchesExact() {
        let config = HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(controlKey))
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .control,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "q",
            charactersIgnoringModifiers: "q",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_Q)
        )!
        #expect(config.matches(event: event))
    }

    @Test("matches: wrong keyCode → false")
    func matchesWrongKey() {
        let config = HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(controlKey))
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .control,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "w",
            charactersIgnoringModifiers: "w",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_W)
        )!
        #expect(!config.matches(event: event))
    }

    @Test("matches: wrong modifiers → false")
    func matchesWrongModifiers() {
        let config = HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(controlKey))
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control, .command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "q",
            charactersIgnoringModifiers: "q",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_Q)
        )!
        #expect(!config.matches(event: event))
    }

    @Test("matches: extra irrelevant modifier flags (shift) → still matches when not in config")
    func matchesIgnoresIrrelevantFlags() {
        let config = HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(controlKey))
        // .control plus .function (caps lock indicator) — only hotKeyRelevantFlags should be checked
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control, .function],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "q",
            charactersIgnoringModifiers: "q",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_Q)
        )!
        #expect(config.matches(event: event))
    }

    // MARK: - from(event:)

    @Test("from(event:): creates configuration from valid key event")
    func fromValidEvent() {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control, .option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "m",
            charactersIgnoringModifiers: "m",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_M)
        )!
        let config = HotKeyConfiguration.from(event: event)
        #expect(config != nil)
        #expect(config?.keyCode == UInt32(kVK_ANSI_M))
        // control + option
        let expectedMods = UInt32(controlKey | optionKey)
        #expect(config?.modifiers == expectedMods)
    }

    @Test("from(event:): returns nil for event with no modifiers")
    func fromNoModifiers() {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_A)
        )!
        let config = HotKeyConfiguration.from(event: event)
        #expect(config == nil)
    }

    @Test("from(event:): returns nil for unknown keyCode")
    func fromUnknownKeyCode() {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .control,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{19}",
            charactersIgnoringModifiers: "\u{19}",
            isARepeat: false,
            keyCode: UInt16(255) // unknown key code → displayKey returns "?"
        )!
        let config = HotKeyConfiguration.from(event: event)
        #expect(config == nil)
    }

    @Test("from(event:): captures all four modifier flags")
    func fromAllModifiers() {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control, .option, .command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_A)
        )!
        let config = HotKeyConfiguration.from(event: event)
        let expectedMods = UInt32(controlKey | optionKey | cmdKey | shiftKey)
        #expect(config?.modifiers == expectedMods)
    }
}
