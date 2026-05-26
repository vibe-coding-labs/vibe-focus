// Tests/Standalone/HotKeyDisplayTests.swift
// Verification: HotKey displayKey mapping, modifier symbol display, HotKeyConfiguration Codable
// Mirrors: Sources/HotKey/HotKeyConfiguration.swift:15-151
// Run: swift Tests/Standalone/HotKeyDisplayTests.swift

import Foundation

// MARK: - Mirrored types and constants

// Carbon key constants (fixed macOS virtual key codes)
let kVK_ANSI_A: Int = 0x00
let kVK_ANSI_S: Int = 0x01
let kVK_ANSI_D: Int = 0x02
let kVK_ANSI_F: Int = 0x03
let kVK_ANSI_H: Int = 0x04
let kVK_ANSI_G: Int = 0x05
let kVK_ANSI_Z: Int = 0x06
let kVK_ANSI_X: Int = 0x07
let kVK_ANSI_C: Int = 0x08
let kVK_ANSI_V: Int = 0x09
let kVK_ANSI_B: Int = 0x0B
let kVK_ANSI_Q: Int = 0x0C
let kVK_ANSI_W: Int = 0x0D
let kVK_ANSI_E: Int = 0x0E
let kVK_ANSI_R: Int = 0x0F
let kVK_ANSI_Y: Int = 0x10
let kVK_ANSI_T: Int = 0x11
let kVK_ANSI_1: Int = 0x12
let kVK_ANSI_2: Int = 0x13
let kVK_ANSI_3: Int = 0x14
let kVK_ANSI_4: Int = 0x15
let kVK_ANSI_6: Int = 0x16
let kVK_ANSI_5: Int = 0x17
let kVK_ANSI_Equal: Int = 0x18
let kVK_ANSI_9: Int = 0x19
let kVK_ANSI_7: Int = 0x1A
let kVK_ANSI_Minus: Int = 0x1B
let kVK_ANSI_8: Int = 0x1C
let kVK_ANSI_0: Int = 0x1D
let kVK_ANSI_RightBracket: Int = 0x1E
let kVK_ANSI_O: Int = 0x1F
let kVK_ANSI_U: Int = 0x20
let kVK_ANSI_LeftBracket: Int = 0x21
let kVK_ANSI_I: Int = 0x22
let kVK_ANSI_P: Int = 0x23
let kVK_ANSI_L: Int = 0x25
let kVK_ANSI_J: Int = 0x26
let kVK_ANSI_Quote: Int = 0x27
let kVK_ANSI_K: Int = 0x28
let kVK_ANSI_Semicolon: Int = 0x29
let kVK_ANSI_Backslash: Int = 0x2A
let kVK_ANSI_Comma: Int = 0x2B
let kVK_ANSI_Slash: Int = 0x2C
let kVK_ANSI_N: Int = 0x2D
let kVK_ANSI_M: Int = 0x2E
let kVK_ANSI_Period: Int = 0x2F
let kVK_ANSI_Grave: Int = 0x32
let kVK_Space: Int = 0x31
let kVK_Delete: Int = 0x33
let kVK_Tab: Int = 0x30
let kVK_Return: Int = 0x24
let kVK_Escape: Int = 0x35
let kVK_ForwardDelete: Int = 0x75
let kVK_LeftArrow: Int = 0x7B
let kVK_RightArrow: Int = 0x7C
let kVK_UpArrow: Int = 0x7E
let kVK_DownArrow: Int = 0x7D
let kVK_F1: Int = 0x7A
let kVK_F2: Int = 0x78
let kVK_F3: Int = 0x63
let kVK_F4: Int = 0x76
let kVK_F5: Int = 0x60
let kVK_F6: Int = 0x61
let kVK_F7: Int = 0x62
let kVK_F8: Int = 0x64
let kVK_F9: Int = 0x65
let kVK_F10: Int = 0x6D
let kVK_F11: Int = 0x67
let kVK_F12: Int = 0x6F

// Carbon modifier key constants
let cmdKey: UInt32 = 0x0100
let shiftKey: UInt32 = 0x0200
let optionKey: UInt32 = 0x0800
let controlKey: UInt32 = 0x1000

struct HotKeyConfiguration: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
}

// Mirrors displayKey (HotKeyConfiguration.swift:74-136)
func displayKey(for keyCode: UInt32) -> String {
    switch Int(keyCode) {
    case kVK_ANSI_A: return "A"
    case kVK_ANSI_B: return "B"
    case kVK_ANSI_C: return "C"
    case kVK_ANSI_D: return "D"
    case kVK_ANSI_E: return "E"
    case kVK_ANSI_F: return "F"
    case kVK_ANSI_G: return "G"
    case kVK_ANSI_H: return "H"
    case kVK_ANSI_I: return "I"
    case kVK_ANSI_J: return "J"
    case kVK_ANSI_K: return "K"
    case kVK_ANSI_L: return "L"
    case kVK_ANSI_M: return "M"
    case kVK_ANSI_N: return "N"
    case kVK_ANSI_O: return "O"
    case kVK_ANSI_P: return "P"
    case kVK_ANSI_Q: return "Q"
    case kVK_ANSI_R: return "R"
    case kVK_ANSI_S: return "S"
    case kVK_ANSI_T: return "T"
    case kVK_ANSI_U: return "U"
    case kVK_ANSI_V: return "V"
    case kVK_ANSI_W: return "W"
    case kVK_ANSI_X: return "X"
    case kVK_ANSI_Y: return "Y"
    case kVK_ANSI_Z: return "Z"
    case kVK_ANSI_0: return "0"
    case kVK_ANSI_1: return "1"
    case kVK_ANSI_2: return "2"
    case kVK_ANSI_3: return "3"
    case kVK_ANSI_4: return "4"
    case kVK_ANSI_5: return "5"
    case kVK_ANSI_6: return "6"
    case kVK_ANSI_7: return "7"
    case kVK_ANSI_8: return "8"
    case kVK_ANSI_9: return "9"
    case kVK_Space: return "Space"
    case kVK_Return: return "Return"
    case kVK_Escape: return "Esc"
    case kVK_Delete: return "Delete"
    case kVK_ForwardDelete: return "Fn⌫"
    case kVK_Tab: return "Tab"
    case kVK_LeftArrow: return "←"
    case kVK_RightArrow: return "→"
    case kVK_UpArrow: return "↑"
    case kVK_DownArrow: return "↓"
    case kVK_F1: return "F1"
    case kVK_F2: return "F2"
    case kVK_F3: return "F3"
    case kVK_F4: return "F4"
    case kVK_F5: return "F5"
    case kVK_F6: return "F6"
    case kVK_F7: return "F7"
    case kVK_F8: return "F8"
    case kVK_F9: return "F9"
    case kVK_F10: return "F10"
    case kVK_F11: return "F11"
    case kVK_F12: return "F12"
    default: return "?"
    }
}

// Mirrors modifierDisplay (HotKeyConfiguration.swift:45-52)
func modifierDisplay(modifiers: UInt32) -> String {
    var output = ""
    if modifiers & controlKey != 0 { output += "⌃" }
    if modifiers & optionKey != 0 { output += "⌥" }
    if modifiers & shiftKey != 0 { output += "⇧" }
    if modifiers & cmdKey != 0 { output += "⌘" }
    return output
}

func displayString(keyCode: UInt32, modifiers: UInt32) -> String {
    modifierDisplay(modifiers: modifiers) + displayKey(for: keyCode)
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

func checkEqual<T: Equatable>(_ name: String, _ a: T, _ b: T) {
    if a == b { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name) — expected \(b), got \(a)") }
}

// MARK: - displayKey — letters

print("1. displayKey — letter keys")
do {
    checkEqual("A", displayKey(for: UInt32(kVK_ANSI_A)), "A")
    checkEqual("Q", displayKey(for: UInt32(kVK_ANSI_Q)), "Q")
    checkEqual("Z", displayKey(for: UInt32(kVK_ANSI_Z)), "Z")
    checkEqual("M", displayKey(for: UInt32(kVK_ANSI_M)), "M")
}

print("\n2. displayKey — number keys")
do {
    checkEqual("0", displayKey(for: UInt32(kVK_ANSI_0)), "0")
    checkEqual("5", displayKey(for: UInt32(kVK_ANSI_5)), "5")
    checkEqual("9", displayKey(for: UInt32(kVK_ANSI_9)), "9")
}

print("\n3. displayKey — special keys")
do {
    checkEqual("Space", displayKey(for: UInt32(kVK_Space)), "Space")
    checkEqual("Return", displayKey(for: UInt32(kVK_Return)), "Return")
    checkEqual("Esc", displayKey(for: UInt32(kVK_Escape)), "Esc")
    checkEqual("Delete", displayKey(for: UInt32(kVK_Delete)), "Delete")
    checkEqual("Tab", displayKey(for: UInt32(kVK_Tab)), "Tab")
}

print("\n4. displayKey — arrow keys")
do {
    checkEqual("Left", displayKey(for: UInt32(kVK_LeftArrow)), "←")
    checkEqual("Right", displayKey(for: UInt32(kVK_RightArrow)), "→")
    checkEqual("Up", displayKey(for: UInt32(kVK_UpArrow)), "↑")
    checkEqual("Down", displayKey(for: UInt32(kVK_DownArrow)), "↓")
}

print("\n5. displayKey — function keys")
do {
    for i in 1...12 {
        let expected = "F\(i)"
        let kVKs = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        checkEqual(expected, displayKey(for: UInt32(kVKs[i-1])), expected)
    }
}

print("\n6. displayKey — unknown key code")
do {
    checkEqual("unknown → ?", displayKey(for: UInt32(0xFF)), "?")
    checkEqual("0 → ?", displayKey(for: UInt32(0xFE)), "?")
}

// MARK: - modifierDisplay

print("\n7. modifierDisplay — single modifiers")
do {
    checkEqual("cmd", modifierDisplay(modifiers: cmdKey), "⌘")
    checkEqual("shift", modifierDisplay(modifiers: shiftKey), "⇧")
    checkEqual("option", modifierDisplay(modifiers: optionKey), "⌥")
    checkEqual("control", modifierDisplay(modifiers: controlKey), "⌃")
}

print("\n8. modifierDisplay — no modifiers")
do {
    checkEqual("none", modifierDisplay(modifiers: 0), "")
}

print("\n9. modifierDisplay — modifier order is control, option, shift, cmd")
do {
    let all = cmdKey | shiftKey | optionKey | controlKey
    checkEqual("all modifiers", modifierDisplay(modifiers: all), "⌃⌥⇧⌘")

    let cmdCtrl = cmdKey | controlKey
    checkEqual("cmd+ctrl", modifierDisplay(modifiers: cmdCtrl), "⌃⌘")

    let cmdOptShift = cmdKey | optionKey | shiftKey
    checkEqual("cmd+opt+shift", modifierDisplay(modifiers: cmdOptShift), "⌥⇧⌘")
}

// MARK: - displayString (combined)

print("\n10. displayString — Ctrl+Q")
do {
    checkEqual("Ctrl+Q", displayString(keyCode: UInt32(kVK_ANSI_Q), modifiers: controlKey), "⌃Q")
}

print("\n11. displayString — Cmd+Space")
do {
    checkEqual("Cmd+Space", displayString(keyCode: UInt32(kVK_Space), modifiers: cmdKey), "⌘Space")
}

print("\n12. displayString — Cmd+Ctrl+F")
do {
    checkEqual("Cmd+Ctrl+F", displayString(keyCode: UInt32(kVK_ANSI_F), modifiers: cmdKey | controlKey), "⌃⌘F")
}

print("\n13. displayString — all modifiers + Esc")
do {
    checkEqual("all+Esc", displayString(keyCode: UInt32(kVK_Escape), modifiers: cmdKey | shiftKey | optionKey | controlKey), "⌃⌥⇧⌘Esc")
}

// MARK: - HotKeyConfiguration Codable

print("\n14. HotKeyConfiguration — Codable roundtrip")
do {
    let config = HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_Q), modifiers: controlKey)
    let encoded = try! JSONEncoder().encode(config)
    let decoded = try! JSONDecoder().decode(HotKeyConfiguration.self, from: encoded)
    checkEqual("keyCode", decoded.keyCode, UInt32(kVK_ANSI_Q))
    checkEqual("modifiers", decoded.modifiers, controlKey)
}

print("\n15. HotKeyConfiguration — JSON structure")
do {
    let config = HotKeyConfiguration(keyCode: 0x0C, modifiers: 0x1000)
    let encoded = try! JSONEncoder().encode(config)
    let json = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    check("has keyCode", json["keyCode"] != nil)
    check("has modifiers", json["modifiers"] != nil)
}

print("\n16. HotKeyConfiguration — equality")
do {
    let a = HotKeyConfiguration(keyCode: 1, modifiers: 2)
    let b = HotKeyConfiguration(keyCode: 1, modifiers: 2)
    let c = HotKeyConfiguration(keyCode: 1, modifiers: 3)
    check("same config is equal", a == b)
    check("different modifiers not equal", a != c)
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
