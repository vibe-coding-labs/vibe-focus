import SwiftUI
import AppKit
import Carbon
import ApplicationServices.HIServices
import CoreFoundation
import Foundation

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ out: UnsafeMutablePointer<CGWindowID>) -> AXError

// 全局日志函数
func log(_ message: String) {
    NSLog("[VibeFocus] %@", message)
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    let logURL = URL(fileURLWithPath: "/tmp/vibefocus.log")
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

extension Notification.Name {
    static let hotKeyConfigurationDidChange = Notification.Name("HotKeyConfigurationDidChange")
}

struct HotKeyConflict: Equatable {
    let configuration: HotKeyConfiguration
    let reason: String
}

struct HotKeyConfiguration: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let userDefaultsKey = "hotKeyConfiguration"
    static let legacyDefault = HotKeyConfiguration(
        keyCode: UInt32(kVK_ANSI_M),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )
    static let `default` = HotKeyConfiguration(
        keyCode: UInt32(kVK_ANSI_M),
        modifiers: UInt32(controlKey)
    )

    static let knownConflicts: [HotKeyConflict] = [
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey)), reason: "与 Spotlight 冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | optionKey)), reason: "与 Finder 搜索冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_Tab), modifiers: UInt32(cmdKey)), reason: "与应用切换器冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_Tab), modifiers: UInt32(cmdKey | shiftKey)), reason: "与反向应用切换冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey)), reason: "与退出应用冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey)), reason: "与关闭窗口冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey)), reason: "与最小化窗口冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey)), reason: "与隐藏应用冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(cmdKey | controlKey)), reason: "与许多应用的全屏快捷键冲突")
    ]

    var displayString: String {
        modifierDisplay + Self.displayKey(for: keyCode)
    }

    private var modifierDisplay: String {
        var output = ""
        if modifiers & UInt32(controlKey) != 0 { output += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { output += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { output += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { output += "⌘" }
        return output
    }

    func matches(event: NSEvent) -> Bool {
        UInt32(event.keyCode) == keyCode &&
        event.modifierFlags.intersection(.hotKeyRelevantFlags).carbonHotKeyModifiers == modifiers
    }

    static func from(event: NSEvent) -> HotKeyConfiguration? {
        let modifiers = event.modifierFlags.intersection(.hotKeyRelevantFlags).carbonHotKeyModifiers
        guard modifiers != 0 else {
            return nil
        }

        let keyCode = UInt32(event.keyCode)
        guard displayKey(for: keyCode) != "?" else {
            return nil
        }

        return HotKeyConfiguration(keyCode: keyCode, modifiers: modifiers)
    }

    static func displayKey(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case Int(kVK_ANSI_A): return "A"
        case Int(kVK_ANSI_B): return "B"
        case Int(kVK_ANSI_C): return "C"
        case Int(kVK_ANSI_D): return "D"
        case Int(kVK_ANSI_E): return "E"
        case Int(kVK_ANSI_F): return "F"
        case Int(kVK_ANSI_G): return "G"
        case Int(kVK_ANSI_H): return "H"
        case Int(kVK_ANSI_I): return "I"
        case Int(kVK_ANSI_J): return "J"
        case Int(kVK_ANSI_K): return "K"
        case Int(kVK_ANSI_L): return "L"
        case Int(kVK_ANSI_M): return "M"
        case Int(kVK_ANSI_N): return "N"
        case Int(kVK_ANSI_O): return "O"
        case Int(kVK_ANSI_P): return "P"
        case Int(kVK_ANSI_Q): return "Q"
        case Int(kVK_ANSI_R): return "R"
        case Int(kVK_ANSI_S): return "S"
        case Int(kVK_ANSI_T): return "T"
        case Int(kVK_ANSI_U): return "U"
        case Int(kVK_ANSI_V): return "V"
        case Int(kVK_ANSI_W): return "W"
        case Int(kVK_ANSI_X): return "X"
        case Int(kVK_ANSI_Y): return "Y"
        case Int(kVK_ANSI_Z): return "Z"
        case Int(kVK_ANSI_0): return "0"
        case Int(kVK_ANSI_1): return "1"
        case Int(kVK_ANSI_2): return "2"
        case Int(kVK_ANSI_3): return "3"
        case Int(kVK_ANSI_4): return "4"
        case Int(kVK_ANSI_5): return "5"
        case Int(kVK_ANSI_6): return "6"
        case Int(kVK_ANSI_7): return "7"
        case Int(kVK_ANSI_8): return "8"
        case Int(kVK_ANSI_9): return "9"
        case Int(kVK_Space): return "Space"
        case Int(kVK_Return): return "Return"
        case Int(kVK_Escape): return "Esc"
        case Int(kVK_Delete): return "Delete"
        case Int(kVK_ForwardDelete): return "Fn⌫"
        case Int(kVK_Tab): return "Tab"
        case Int(kVK_LeftArrow): return "←"
        case Int(kVK_RightArrow): return "→"
        case Int(kVK_UpArrow): return "↑"
        case Int(kVK_DownArrow): return "↓"
        case Int(kVK_F1): return "F1"
        case Int(kVK_F2): return "F2"
        case Int(kVK_F3): return "F3"
        case Int(kVK_F4): return "F4"
        case Int(kVK_F5): return "F5"
        case Int(kVK_F6): return "F6"
        case Int(kVK_F7): return "F7"
        case Int(kVK_F8): return "F8"
        case Int(kVK_F9): return "F9"
        case Int(kVK_F10): return "F10"
        case Int(kVK_F11): return "F11"
        case Int(kVK_F12): return "F12"
        default: return "?"
        }
    }
}

extension NSEvent.ModifierFlags {
    static let hotKeyRelevantFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var carbonHotKeyModifiers: UInt32 {
        var result: UInt32 = 0
        if contains(.command) { result |= UInt32(cmdKey) }
        if contains(.option) { result |= UInt32(optionKey) }
        if contains(.control) { result |= UInt32(controlKey) }
        if contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
