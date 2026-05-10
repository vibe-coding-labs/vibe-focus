// Tests/Standalone/ToggleRecordTests.swift
// Verification: ToggleRecord validation logic
// Run: swift Tests/Standalone/ToggleRecordTests.swift

import Foundation
import CoreGraphics

let mainScreenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)

struct ToggleRecord: Equatable {
    let windowID: UInt32
    let pid: Int32
    let bundleIdentifier: String?
    let appName: String?
    let origFrame: CGRect
    let sourceSpace: Int
    let sourceDisplay: Int
    let sourceYabaiDisp: Int
    let sourceDispSpace: Int
    let targetFrame: CGRect
    let targetDisplay: Int
    let toggledAt: Date
    let sessionID: String?

    func isValid(mainScreenFrame: CGRect) -> Bool {
        let origCenter = CGPoint(x: origFrame.midX, y: origFrame.midY)
        let tgtCenter = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        return !mainScreenFrame.contains(origCenter) && mainScreenFrame.contains(tgtCenter)
    }

    func isNearTarget(currentFrame: CGRect, tolerance: CGFloat = 200) -> Bool {
        abs(currentFrame.origin.x - targetFrame.origin.x) <= tolerance &&
        abs(currentFrame.origin.y - targetFrame.origin.y) <= tolerance
    }
}

func makeRecord(origX: CGFloat, origY: CGFloat, origW: CGFloat, origH: CGFloat,
                targetX: CGFloat, targetY: CGFloat, targetW: CGFloat, targetH: CGFloat) -> ToggleRecord {
    ToggleRecord(
        windowID: 100, pid: 409, bundleIdentifier: nil, appName: nil,
        origFrame: CGRect(x: origX, y: origY, width: origW, height: origH),
        sourceSpace: 4, sourceDisplay: 2, sourceYabaiDisp: 2, sourceDispSpace: 3,
        targetFrame: CGRect(x: targetX, y: targetY, width: targetW, height: targetH),
        targetDisplay: 0, toggledAt: Date(), sessionID: nil
    )
}

// --- Tests ---

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

print("Test 1: isValid with correct data (orig off-screen, target on-screen)")
do {
    let record = makeRecord(origX: 1480, origY: -710, origW: 1145, origH: 710,
                            targetX: 75, targetY: 38, targetW: 1656, targetH: 1070)
    check("valid toggle record", record.isValid(mainScreenFrame: mainScreenFrame))
}

print("Test 2: isValid with corrupted orig (on main screen)")
do {
    let record = makeRecord(origX: 100, origY: 100, origW: 500, origH: 500,
                            targetX: 75, targetY: 38, targetW: 1656, targetH: 1070)
    check("corrupted orig on main screen", !record.isValid(mainScreenFrame: mainScreenFrame))
}

print("Test 3: isValid with target off-screen")
do {
    let record = makeRecord(origX: 1480, origY: -710, origW: 1145, origH: 710,
                            targetX: -2000, targetY: -2000, targetW: 1656, targetH: 1070)
    check("target off-screen", !record.isValid(mainScreenFrame: mainScreenFrame))
}

print("Test 4: isNearTarget within default tolerance (200px)")
do {
    let record = makeRecord(origX: 1480, origY: -710, origW: 1145, origH: 710,
                            targetX: 75, targetY: 38, targetW: 1656, targetH: 1070)
    let currentFrame = CGRect(x: 100, y: 50, width: 1656, height: 1070)
    check("25px offset within tolerance", record.isNearTarget(currentFrame: currentFrame))
}

print("Test 5: isNearTarget outside tolerance")
do {
    let record = makeRecord(origX: 1480, origY: -710, origW: 1145, origH: 710,
                            targetX: 75, targetY: 38, targetW: 1656, targetH: 1070)
    let currentFrame = CGRect(x: 500, y: 500, width: 1656, height: 1070)
    check("425px offset outside tolerance", !record.isNearTarget(currentFrame: currentFrame))
}

print("Test 6: isNearTarget with custom tolerance")
do {
    let record = makeRecord(origX: 1480, origY: -710, origW: 1145, origH: 710,
                            targetX: 75, targetY: 38, targetW: 1656, targetH: 1070)
    let currentFrame = CGRect(x: 250, y: 50, width: 1656, height: 1070)
    check("175px offset within 200 tolerance", record.isNearTarget(currentFrame: currentFrame, tolerance: 200))
    check("175px offset outside 100 tolerance", !record.isNearTarget(currentFrame: currentFrame, tolerance: 100))
}

print("Test 7: Edge case - exact match at target")
do {
    let record = makeRecord(origX: 1480, origY: -710, origW: 1145, origH: 710,
                            targetX: 75, targetY: 38, targetW: 1656, targetH: 1070)
    let currentFrame = CGRect(x: 75, y: 38, width: 1656, height: 1070)
    check("exact match", record.isNearTarget(currentFrame: currentFrame))
}

// Summary
print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
