// Tests/Standalone/CGWindowEntryTests.swift
// Verification: CGWindowEntry dictionary parsing
// Mirrors: Sources/Support/CGWindowEntry.swift:4-36
// Run: swift Tests/Standalone/CGWindowEntryTests.swift

import Foundation
import CoreGraphics

// kCGWindow constants — these are CFString keys, we use string values directly
let kCGWindowNumber = "kCGWindowNumber"
let kCGWindowOwnerPID = "kCGWindowOwnerPID"
let kCGWindowOwnerName = "kCGWindowOwnerName"
let kCGWindowLayer = "kCGWindowLayer"
let kCGWindowBounds = "kCGWindowBounds"
let kCGWindowIsOnscreen = "kCGWindowIsOnscreen"

// MARK: - CGWindowEntry (mirrors CGWindowEntry.swift:4-36)

struct CGWindowEntry: Equatable {
    let windowID: UInt32
    let ownerPID: pid_t
    let ownerName: String?
    let layer: Int
    let bounds: CGRect?
    let name: String?
    let isOnScreen: Bool

    init?(from dict: [String: Any]) {
        guard let windowID = dict[kCGWindowNumber] as? UInt32,
              let ownerPID = dict[kCGWindowOwnerPID] as? pid_t else {
            return nil
        }
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.ownerName = dict[kCGWindowOwnerName] as? String
        self.layer = dict[kCGWindowLayer] as? Int ?? 0
        self.name = dict["kCGWindowName"] as? String ?? dict["name"] as? String
        self.isOnScreen = dict[kCGWindowIsOnscreen] as? Bool ?? true

        if let boundsDict = dict[kCGWindowBounds] as? [String: CGFloat] {
            self.bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
        } else {
            self.bounds = nil
        }
    }
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

// MARK: - Complete dictionary

print("1. CGWindowEntry — complete dictionary")
do {
    let dict: [String: Any] = [
        kCGWindowNumber: UInt32(42),
        kCGWindowOwnerPID: pid_t(1234),
        kCGWindowOwnerName: "Terminal",
        kCGWindowLayer: Int(0),
        kCGWindowBounds: ["X": CGFloat(100), "Y": CGFloat(200), "Width": CGFloat(800), "Height": CGFloat(600)],
        "kCGWindowName": "bash — 80x24",
        kCGWindowIsOnscreen: true,
    ]
    let entry = CGWindowEntry(from: dict)!
    checkEqual("windowID", entry.windowID, UInt32(42))
    checkEqual("ownerPID", entry.ownerPID, pid_t(1234))
    checkEqual("ownerName", entry.ownerName, "Terminal")
    checkEqual("layer", entry.layer, 0)
    checkEqual("name", entry.name, "bash — 80x24")
    check("isOnScreen", entry.isOnScreen)
    checkEqual("bounds.x", entry.bounds!.origin.x, 100.0)
    checkEqual("bounds.y", entry.bounds!.origin.y, 200.0)
    checkEqual("bounds.width", entry.bounds!.width, 800.0)
    checkEqual("bounds.height", entry.bounds!.height, 600.0)
}

// MARK: - Minimal dictionary

print("\n2. CGWindowEntry — minimal dictionary (only required fields)")
do {
    let dict: [String: Any] = [
        kCGWindowNumber: UInt32(99),
        kCGWindowOwnerPID: pid_t(5678),
    ]
    let entry = CGWindowEntry(from: dict)!
    checkEqual("windowID", entry.windowID, UInt32(99))
    checkEqual("ownerPID", entry.ownerPID, pid_t(5678))
    check("ownerName is nil", entry.ownerName == nil)
    checkEqual("layer defaults to 0", entry.layer, 0)
    check("name is nil", entry.name == nil)
    check("isOnScreen defaults to true", entry.isOnScreen)
    check("bounds is nil", entry.bounds == nil)
}

// MARK: - Missing required fields → nil

print("\n3. CGWindowEntry — missing required fields")
do {
    let noWindowID: [String: Any] = [kCGWindowOwnerPID: pid_t(100)]
    check("missing windowID → nil", CGWindowEntry(from: noWindowID) == nil)

    let noPID: [String: Any] = [kCGWindowNumber: UInt32(1)]
    check("missing ownerPID → nil", CGWindowEntry(from: noPID) == nil)

    let empty: [String: Any] = [:]
    check("empty dict → nil", CGWindowEntry(from: empty) == nil)
}

// MARK: - Wrong types → nil

print("\n4. CGWindowEntry — wrong types for required fields")
do {
    let wrongWindowIDType: [String: Any] = [
        kCGWindowNumber: "not-a-number",
        kCGWindowOwnerPID: pid_t(100),
    ]
    check("windowID is string → nil", CGWindowEntry(from: wrongWindowIDType) == nil)

    let wrongPIDType: [String: Any] = [
        kCGWindowNumber: UInt32(1),
        kCGWindowOwnerPID: "not-a-pid",
    ]
    check("ownerPID is string → nil", CGWindowEntry(from: wrongPIDType) == nil)
}

// MARK: - Bounds edge cases

print("\n5. CGWindowEntry — bounds parsing")
do {
    let zeroBounds: [String: Any] = [
        kCGWindowNumber: UInt32(1),
        kCGWindowOwnerPID: pid_t(1),
        kCGWindowBounds: ["X": CGFloat(0), "Y": CGFloat(0), "Width": CGFloat(0), "Height": CGFloat(0)],
    ]
    let entry1 = CGWindowEntry(from: zeroBounds)!
    check("zero bounds parsed", entry1.bounds == CGRect(x: 0, y: 0, width: 0, height: 0))

    let partialBounds: [String: Any] = [
        kCGWindowNumber: UInt32(1),
        kCGWindowOwnerPID: pid_t(1),
        kCGWindowBounds: ["X": CGFloat(100), "Width": CGFloat(500)],
    ]
    let entry2 = CGWindowEntry(from: partialBounds)!
    checkEqual("partial bounds: X preserved", entry2.bounds!.origin.x, 100.0)
    checkEqual("partial bounds: Y defaults to 0", entry2.bounds!.origin.y, 0.0)
    checkEqual("partial bounds: Width preserved", entry2.bounds!.width, 500.0)
    checkEqual("partial bounds: Height defaults to 0", entry2.bounds!.height, 0.0)
}

// MARK: - isOnScreen false

print("\n6. CGWindowEntry — isOnScreen false")
do {
    let dict: [String: Any] = [
        kCGWindowNumber: UInt32(1),
        kCGWindowOwnerPID: pid_t(1),
        kCGWindowIsOnscreen: false,
    ]
    let entry = CGWindowEntry(from: dict)!
    check("isOnScreen false preserved", !entry.isOnScreen)
}

// MARK: - Name key fallback

print("\n7. CGWindowEntry — name key fallback")
do {
    let kCGWindowName: [String: Any] = [
        kCGWindowNumber: UInt32(1),
        kCGWindowOwnerPID: pid_t(1),
        "kCGWindowName": "via-kCGWindowName",
    ]
    check("kCGWindowName key", CGWindowEntry(from: kCGWindowName)?.name == "via-kCGWindowName")

    let nameKey: [String: Any] = [
        kCGWindowNumber: UInt32(1),
        kCGWindowOwnerPID: pid_t(1),
        "name": "via-name-key",
    ]
    check("name key fallback", CGWindowEntry(from: nameKey)?.name == "via-name-key")
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
