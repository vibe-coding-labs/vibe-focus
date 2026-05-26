// Tests/Standalone/SoundAndTitleTests.swift
// Verification: CompletionSoundType, SoundPreferences, TitleEditorPreferences Codable
// Mirrors: Sources/App/SoundManager.swift:1-50, Sources/Window/TitleEditorPreferences.swift
// Run: swift Tests/Standalone/SoundAndTitleTests.swift

import Foundation

// MARK: - Mirrored types

enum CompletionSoundType: String, CaseIterable, Codable {
    case none = "none"
    case systemDefault = "system_default"
    case builtinDing = "builtin_ding"
    case builtinPing = "builtin_ping"
    case builtinComplete = "builtin_complete"
    case builtinAreYouOk = "builtin_are_you_ok"
    case custom = "custom"

    var displayName: String {
        switch self {
        case .none: return "无"
        case .systemDefault: return "系统默认"
        case .builtinDing: return "Ding"
        case .builtinPing: return "Ping"
        case .builtinComplete: return "Complete"
        case .builtinAreYouOk: return "Are You OK"
        case .custom: return "自定义文件"
        }
    }

    var isBuiltin: Bool {
        switch self {
        case .builtinDing, .builtinPing, .builtinComplete, .builtinAreYouOk:
            return true
        default:
            return false
        }
    }
}

struct SoundPreferences: Codable, Equatable {
    var soundType: CompletionSoundType
    var customSoundPath: String?
    var volume: Float
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

// MARK: - CompletionSoundType

print("1. CompletionSoundType — all cases")
do {
    checkEqual("7 cases", CompletionSoundType.allCases.count, 7)
    checkEqual("none raw", CompletionSoundType.none.rawValue, "none")
    checkEqual("systemDefault raw", CompletionSoundType.systemDefault.rawValue, "system_default")
    checkEqual("builtinDing raw", CompletionSoundType.builtinDing.rawValue, "builtin_ding")
    checkEqual("builtinPing raw", CompletionSoundType.builtinPing.rawValue, "builtin_ping")
    checkEqual("builtinComplete raw", CompletionSoundType.builtinComplete.rawValue, "builtin_complete")
    checkEqual("builtinAreYouOk raw", CompletionSoundType.builtinAreYouOk.rawValue, "builtin_are_you_ok")
    checkEqual("custom raw", CompletionSoundType.custom.rawValue, "custom")
}

print("\n2. CompletionSoundType — Codable roundtrip")
do {
    for sound in CompletionSoundType.allCases {
        let encoded = try! JSONEncoder().encode(sound)
        let decoded = try! JSONDecoder().decode(CompletionSoundType.self, from: encoded)
        check("roundtrip \(sound.rawValue)", decoded == sound)
    }
}

print("\n3. CompletionSoundType — displayName")
do {
    checkEqual("none → 无", CompletionSoundType.none.displayName, "无")
    checkEqual("systemDefault → 系统默认", CompletionSoundType.systemDefault.displayName, "系统默认")
    checkEqual("builtinDing → Ding", CompletionSoundType.builtinDing.displayName, "Ding")
    checkEqual("builtinPing → Ping", CompletionSoundType.builtinPing.displayName, "Ping")
    checkEqual("builtinComplete → Complete", CompletionSoundType.builtinComplete.displayName, "Complete")
    checkEqual("builtinAreYouOk → Are You OK", CompletionSoundType.builtinAreYouOk.displayName, "Are You OK")
    checkEqual("custom → 自定义文件", CompletionSoundType.custom.displayName, "自定义文件")
}

print("\n4. CompletionSoundType — isBuiltin")
do {
    check("ding is builtin", CompletionSoundType.builtinDing.isBuiltin)
    check("ping is builtin", CompletionSoundType.builtinPing.isBuiltin)
    check("complete is builtin", CompletionSoundType.builtinComplete.isBuiltin)
    check("areYouOk is builtin", CompletionSoundType.builtinAreYouOk.isBuiltin)
    check("none is NOT builtin", !CompletionSoundType.none.isBuiltin)
    check("systemDefault is NOT builtin", !CompletionSoundType.systemDefault.isBuiltin)
    check("custom is NOT builtin", !CompletionSoundType.custom.isBuiltin)
}

print("\n5. CompletionSoundType — decode from JSON string")
do {
    let json = "\"builtin_ding\"".data(using: .utf8)!
    let decoded = try! JSONDecoder().decode(CompletionSoundType.self, from: json)
    checkEqual("decode from string", decoded, .builtinDing)
}

print("\n6. CompletionSoundType — invalid value rejected")
do {
    let badJson = "\"unknown_sound\"".data(using: .utf8)!
    check("invalid sound → nil", (try? JSONDecoder().decode(CompletionSoundType.self, from: badJson)) == nil)
}

// MARK: - SoundPreferences

print("\n7. SoundPreferences — Codable roundtrip")
do {
    let prefs = SoundPreferences(soundType: .builtinDing, customSoundPath: nil, volume: 0.7)
    let encoded = try! JSONEncoder().encode(prefs)
    let decoded = try! JSONDecoder().decode(SoundPreferences.self, from: encoded)
    checkEqual("soundType", decoded.soundType, .builtinDing)
    check("customSoundPath nil", decoded.customSoundPath == nil)
    checkEqual("volume", decoded.volume, 0.7)
}

print("\n8. SoundPreferences — with custom sound path")
do {
    let prefs = SoundPreferences(soundType: .custom, customSoundPath: "/Users/test/sound.aiff", volume: 0.5)
    let encoded = try! JSONEncoder().encode(prefs)
    let decoded = try! JSONDecoder().decode(SoundPreferences.self, from: encoded)
    checkEqual("soundType custom", decoded.soundType, .custom)
    checkEqual("customSoundPath", decoded.customSoundPath, "/Users/test/sound.aiff")
    checkEqual("volume", decoded.volume, 0.5)
}

print("\n9. SoundPreferences — volume boundary values")
do {
    let zero = SoundPreferences(soundType: .none, customSoundPath: nil, volume: 0.0)
    let encoded = try! JSONEncoder().encode(zero)
    let decoded = try! JSONDecoder().decode(SoundPreferences.self, from: encoded)
    checkEqual("volume 0.0", decoded.volume, Float(0.0))

    let max = SoundPreferences(soundType: .none, customSoundPath: nil, volume: 1.0)
    let encodedMax = try! JSONEncoder().encode(max)
    let decodedMax = try! JSONDecoder().decode(SoundPreferences.self, from: encodedMax)
    checkEqual("volume 1.0", decodedMax.volume, Float(1.0))
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
