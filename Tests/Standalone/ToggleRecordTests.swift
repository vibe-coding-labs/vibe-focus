// Tests/Standalone/ToggleRecordTests.swift
// Verification: ToggleRecord validation logic
// Run: swift Tests/Standalone/ToggleRecordTests.swift
//
// NOTE: isValid() here mirrors Sources/Hook/ClaudeHookModels.swift:147-152
// which does Quartz→Cocoa coordinate conversion. If the source code changes,
// update this file to match.

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

    /// Mirrors ClaudeHookModels.swift:147-152
    /// Converts Quartz coords to Cocoa coords before checking mainScreenFrame.
    func isValid(mainScreenFrame: CGRect) -> Bool {
        let mainScreenHeight = mainScreenFrame.height
        let origCocoaCenter = CGPoint(x: origFrame.midX, y: mainScreenHeight - origFrame.midY)
        let tgtCocoaCenter = CGPoint(x: targetFrame.midX, y: mainScreenHeight - targetFrame.midY)
        return !mainScreenFrame.contains(origCocoaCenter) && mainScreenFrame.contains(tgtCocoaCenter)
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

print("Test 1: isValid with correct data (orig on secondary above, target on main)")
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

print("Test 4: isValid with orig on secondary below main screen")
do {
    let record = makeRecord(origX: 500, origY: 1400, origW: 1920, origH: 1080,
                            targetX: 75, targetY: 38, targetW: 1656, targetH: 1070)
    check("secondary below main", record.isValid(mainScreenFrame: mainScreenFrame))
}

print("Test 5: isValid with orig on secondary right of main screen")
do {
    let record = makeRecord(origX: 2500, origY: 200, origW: 2000, origH: 1200,
                            targetX: 75, targetY: 38, targetW: 1656, targetH: 1070)
    check("secondary right of main", record.isValid(mainScreenFrame: mainScreenFrame))
}

print("Test 6: isValid with orig on secondary left of main screen")
do {
    let record = makeRecord(origX: -1500, origY: 100, origW: 1920, origH: 1080,
                            targetX: 75, targetY: 38, targetW: 1656, targetH: 1070)
    check("secondary left of main", record.isValid(mainScreenFrame: mainScreenFrame))
}

// Summary
print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
