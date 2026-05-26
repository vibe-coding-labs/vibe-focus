// Tests/Standalone/ScreenIndexPreferencesTests.swift
// Verification: IndexPosition Codable, CodableColor Codable, legacy migration, per-screen enforcement
// Mirrors: Sources/Overlay/ScreenIndexPreferences.swift:5-191
// Run: swift Tests/Standalone/ScreenIndexPreferencesTests.swift

import Foundation

// MARK: - Mirrored types

enum IndexPosition: String, CaseIterable, Codable {
    case topLeft = "topLeft"
    case topCenter = "topCenter"
    case topRight = "topRight"
    case bottomLeft = "bottomLeft"
    case bottomCenter = "bottomCenter"
    case bottomRight = "bottomRight"
}

struct CodableColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double
}

struct ScreenIndexPreferences: Codable, Equatable {
    var isEnabled: Bool
    var position: IndexPosition
    var fontSize: CGFloat
    var opacity: CGFloat
    var textColor: CodableColor
    var backgroundColor: CodableColor
    var panelScale: CGFloat
    var panelMargin: CGFloat
    var yabaiPath: String?
    var usePerScreenSpaceIndexing: Bool
}

// Legacy struct without panelScale, panelMargin, yabaiPath, usePerScreenSpaceIndexing
struct LegacyPreferences: Codable {
    var isEnabled: Bool
    var position: IndexPosition
    var fontSize: CGFloat
    var opacity: CGFloat
    var textColor: CodableColor
    var backgroundColor: CodableColor
    var panelScale: CGFloat?
    var panelMargin: CGFloat?
    var yabaiPath: String?
}

// Mirrors enforcePerScreenSpaceIndexingIfNeeded
func enforcePerScreenSpaceIndexing(_ prefs: ScreenIndexPreferences) -> ScreenIndexPreferences {
    guard !prefs.usePerScreenSpaceIndexing else { return prefs }
    var migrated = prefs
    migrated.usePerScreenSpaceIndexing = true
    return migrated
}

// Mirrors loadLegacyPreferences migration logic
func loadLegacyPreferences(from data: Data) -> ScreenIndexPreferences? {
    guard let legacy = try? JSONDecoder().decode(LegacyPreferences.self, from: data) else {
        return nil
    }
    return ScreenIndexPreferences(
        isEnabled: legacy.isEnabled,
        position: legacy.position,
        fontSize: legacy.fontSize,
        opacity: legacy.opacity,
        textColor: legacy.textColor,
        backgroundColor: legacy.backgroundColor,
        panelScale: legacy.panelScale ?? 1.0,
        panelMargin: legacy.panelMargin ?? 20,
        yabaiPath: legacy.yabaiPath,
        usePerScreenSpaceIndexing: true
    )
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

// MARK: - IndexPosition

print("1. IndexPosition — all cases")
do {
    checkEqual("6 cases", IndexPosition.allCases.count, 6)
    checkEqual("topLeft raw", IndexPosition.topLeft.rawValue, "topLeft")
    checkEqual("topCenter raw", IndexPosition.topCenter.rawValue, "topCenter")
    checkEqual("topRight raw", IndexPosition.topRight.rawValue, "topRight")
    checkEqual("bottomLeft raw", IndexPosition.bottomLeft.rawValue, "bottomLeft")
    checkEqual("bottomCenter raw", IndexPosition.bottomCenter.rawValue, "bottomCenter")
    checkEqual("bottomRight raw", IndexPosition.bottomRight.rawValue, "bottomRight")
}

print("\n2. IndexPosition — Codable roundtrip")
do {
    for pos in IndexPosition.allCases {
        let encoded = try! JSONEncoder().encode(pos)
        let decoded = try! JSONDecoder().decode(IndexPosition.self, from: encoded)
        check("roundtrip \(pos.rawValue)", decoded == pos)
    }
}

print("\n3. IndexPosition — decode from JSON string")
do {
    let json = "\"topRight\"".data(using: .utf8)!
    let decoded = try! JSONDecoder().decode(IndexPosition.self, from: json)
    checkEqual("decode from string", decoded, .topRight)
}

print("\n4. IndexPosition — invalid value rejected")
do {
    let badJson = "\"center\"".data(using: .utf8)!
    check("invalid position → nil", (try? JSONDecoder().decode(IndexPosition.self, from: badJson)) == nil)
}

// MARK: - CodableColor

print("\n5. CodableColor — Codable roundtrip")
do {
    let white = CodableColor(red: 1.0, green: 1.0, blue: 1.0, opacity: 1.0)
    let encoded = try! JSONEncoder().encode(white)
    let decoded = try! JSONDecoder().decode(CodableColor.self, from: encoded)
    checkEqual("white roundtrip", decoded, white)

    let black = CodableColor(red: 0, green: 0, blue: 0, opacity: 0.6)
    let encoded2 = try! JSONEncoder().encode(black)
    let decoded2 = try! JSONDecoder().decode(CodableColor.self, from: encoded2)
    checkEqual("black with opacity roundtrip", decoded2, black)
}

print("\n6. CodableColor — JSON structure")
do {
    let color = CodableColor(red: 0.5, green: 0.25, blue: 0.75, opacity: 0.8)
    let encoded = try! JSONEncoder().encode(color)
    let json = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    checkEqual("red", json["red"] as? Double, 0.5)
    checkEqual("green", json["green"] as? Double, 0.25)
    checkEqual("blue", json["blue"] as? Double, 0.75)
    checkEqual("opacity", json["opacity"] as? Double, 0.8)
}

// MARK: - ScreenIndexPreferences Codable

print("\n7. ScreenIndexPreferences — full Codable roundtrip")
do {
    let prefs = ScreenIndexPreferences(
        isEnabled: true,
        position: .bottomRight,
        fontSize: 64,
        opacity: 0.9,
        textColor: CodableColor(red: 1, green: 1, blue: 0, opacity: 1),
        backgroundColor: CodableColor(red: 0, green: 0, blue: 0, opacity: 0.5),
        panelScale: 1.5,
        panelMargin: 30,
        yabaiPath: "/opt/homebrew/bin/yabai",
        usePerScreenSpaceIndexing: true
    )
    let encoded = try! JSONEncoder().encode(prefs)
    let decoded = try! JSONDecoder().decode(ScreenIndexPreferences.self, from: encoded)
    checkEqual("isEnabled", decoded.isEnabled, true)
    checkEqual("position", decoded.position, .bottomRight)
    checkEqual("fontSize", decoded.fontSize, 64.0)
    checkEqual("opacity", decoded.opacity, 0.9)
    checkEqual("panelScale", decoded.panelScale, 1.5)
    checkEqual("panelMargin", decoded.panelMargin, 30.0)
    checkEqual("yabaiPath", decoded.yabaiPath, "/opt/homebrew/bin/yabai")
    checkEqual("usePerScreenSpaceIndexing", decoded.usePerScreenSpaceIndexing, true)
    check("textColor matches", decoded.textColor == prefs.textColor)
    check("backgroundColor matches", decoded.backgroundColor == prefs.backgroundColor)
}

print("\n8. ScreenIndexPreferences — nil yabaiPath roundtrip")
do {
    let prefs = ScreenIndexPreferences(
        isEnabled: false,
        position: .topLeft,
        fontSize: 48,
        opacity: 0.8,
        textColor: CodableColor(red: 1, green: 1, blue: 1, opacity: 1),
        backgroundColor: CodableColor(red: 0, green: 0, blue: 0, opacity: 0.6),
        panelScale: 1.0,
        panelMargin: 20,
        yabaiPath: nil,
        usePerScreenSpaceIndexing: false
    )
    let encoded = try! JSONEncoder().encode(prefs)
    let decoded = try! JSONDecoder().decode(ScreenIndexPreferences.self, from: encoded)
    check("yabaiPath nil roundtrip", decoded.yabaiPath == nil)
    checkEqual("usePerScreenSpaceIndexing preserved", decoded.usePerScreenSpaceIndexing, false)
}

// MARK: - Legacy migration

print("\n9. loadLegacyPreferences — full legacy data")
do {
    let legacyJSON = """
    {
        "isEnabled": true,
        "position": "topRight",
        "fontSize": 36,
        "opacity": 0.7,
        "textColor": {"red": 1, "green": 0.5, "blue": 0, "opacity": 1},
        "backgroundColor": {"red": 0, "green": 0, "blue": 0, "opacity": 0.8}
    }
    """
    let data = legacyJSON.data(using: .utf8)!
    let migrated = loadLegacyPreferences(from: data)
    check("migration succeeds", migrated != nil)
    checkEqual("isEnabled", migrated!.isEnabled, true)
    checkEqual("position", migrated!.position, .topRight)
    checkEqual("fontSize", migrated!.fontSize, 36.0)
    checkEqual("panelScale defaults to 1.0", migrated!.panelScale, 1.0)
    checkEqual("panelMargin defaults to 20", migrated!.panelMargin, 20.0)
    check("yabaiPath defaults to nil", migrated!.yabaiPath == nil)
    checkEqual("usePerScreenSpaceIndexing forced to true", migrated!.usePerScreenSpaceIndexing, true)
}

print("\n10. loadLegacyPreferences — legacy with partial optional fields")
do {
    let legacyJSON = """
    {
        "isEnabled": false,
        "position": "bottomLeft",
        "fontSize": 24,
        "opacity": 0.5,
        "textColor": {"red": 1, "green": 1, "blue": 1, "opacity": 1},
        "backgroundColor": {"red": 0, "green": 0, "blue": 0, "opacity": 1},
        "panelScale": 2.0,
        "yabaiPath": "/usr/local/bin/yabai"
    }
    """
    let data = legacyJSON.data(using: .utf8)!
    let migrated = loadLegacyPreferences(from: data)
    check("migration succeeds", migrated != nil)
    checkEqual("panelScale preserved", migrated!.panelScale, 2.0)
    checkEqual("panelMargin defaults to 20 (not in JSON)", migrated!.panelMargin, 20.0)
    checkEqual("yabaiPath preserved", migrated!.yabaiPath, "/usr/local/bin/yabai")
}

print("\n11. loadLegacyPreferences — invalid data returns nil")
do {
    let badJSON = "not json at all".data(using: .utf8)!
    check("invalid JSON → nil", loadLegacyPreferences(from: badJSON) == nil)

    let emptyData = Data()
    check("empty data → nil", loadLegacyPreferences(from: emptyData) == nil)
}

print("\n12. loadLegacyPreferences — missing required field")
do {
    let incompleteJSON = """
    {"isEnabled": true}
    """
    let data = incompleteJSON.data(using: .utf8)!
    check("missing fields → nil", loadLegacyPreferences(from: data) == nil)
}

// MARK: - enforcePerScreenSpaceIndexing

print("\n13. enforcePerScreenSpaceIndexing — already true")
do {
    let prefs = ScreenIndexPreferences(
        isEnabled: true, position: .topRight, fontSize: 48, opacity: 0.8,
        textColor: CodableColor(red: 1, green: 1, blue: 1, opacity: 1),
        backgroundColor: CodableColor(red: 0, green: 0, blue: 0, opacity: 0.6),
        panelScale: 1.0, panelMargin: 20, yabaiPath: nil, usePerScreenSpaceIndexing: true
    )
    let result = enforcePerScreenSpaceIndexing(prefs)
    checkEqual("unchanged when already true", result.usePerScreenSpaceIndexing, true)
    checkEqual("position preserved", result.position, .topRight)
}

print("\n14. enforcePerScreenSpaceIndexing — migrates false to true")
do {
    let prefs = ScreenIndexPreferences(
        isEnabled: true, position: .bottomCenter, fontSize: 48, opacity: 0.8,
        textColor: CodableColor(red: 1, green: 1, blue: 1, opacity: 1),
        backgroundColor: CodableColor(red: 0, green: 0, blue: 0, opacity: 0.6),
        panelScale: 1.0, panelMargin: 20, yabaiPath: nil, usePerScreenSpaceIndexing: false
    )
    let result = enforcePerScreenSpaceIndexing(prefs)
    checkEqual("migrated to true", result.usePerScreenSpaceIndexing, true)
    checkEqual("position preserved", result.position, .bottomCenter)
    checkEqual("isEnabled preserved", result.isEnabled, true)
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
