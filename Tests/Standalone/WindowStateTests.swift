// Tests/Standalone/WindowStateTests.swift
// Verification: WindowState toggle state validation logic
// Run: swift Tests/Standalone/WindowStateTests.swift

import Foundation
import CoreGraphics

let mainScreenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)

struct WindowState {
    var origX: CGFloat?
    var origY: CGFloat?
    var origW: CGFloat?
    var origH: CGFloat?
    var targetX: CGFloat?
    var targetY: CGFloat?
    var targetW: CGFloat?
    var targetH: CGFloat?

    var hasToggleState: Bool {
        origX != nil && targetX != nil
    }

    var originalFrame: CGRect? {
        guard let x = origX, let y = origY, let w = origW, let h = origH else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    var targetFrame: CGRect? {
        guard let x = targetX, let y = targetY, let w = targetW, let h = targetH else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    func isCorrupted(mainScreenFrame: CGRect) -> Bool {
        guard let orig = originalFrame, let tgt = targetFrame else { return false }
        let origCenter = CGPoint(x: orig.midX, y: orig.midY)
        let tgtCenter = CGPoint(x: tgt.midX, y: tgt.midY)
        return mainScreenFrame.contains(origCenter) && mainScreenFrame.contains(tgtCenter)
    }

    func isNearTarget(currentFrame: CGRect, tolerance: CGFloat = 150) -> Bool {
        guard let tgt = targetFrame else { return true }
        return abs(currentFrame.origin.x - tgt.origin.x) <= tolerance &&
               abs(currentFrame.origin.y - tgt.origin.y) <= tolerance
    }
}

func makeState() -> WindowState {
    WindowState()
}

// --- Tests ---

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

print("Test 1: hasToggleState — both present")
do {
    var state = makeState()
    state.origX = 100; state.targetX = 200
    check("both present", state.hasToggleState)
}

print("Test 2: hasToggleState — missing orig")
do {
    var state = makeState()
    state.origX = nil; state.targetX = 200
    check("missing orig", !state.hasToggleState)
}

print("Test 3: hasToggleState — missing target")
do {
    var state = makeState()
    state.origX = 100; state.targetX = nil
    check("missing target", !state.hasToggleState)
}

print("Test 4: hasToggleState — neither")
do {
    let state = makeState()
    check("neither set", !state.hasToggleState)
}

print("Test 5: isCorrupted — both on main screen")
do {
    var state = makeState()
    state.origX = 100; state.origY = 100; state.origW = 500; state.origH = 500
    state.targetX = 200; state.targetY = 200; state.targetW = 600; state.targetH = 600
    check("both on main screen = corrupted", state.isCorrupted(mainScreenFrame: mainScreenFrame))
}

print("Test 6: isCorrupted — orig off screen")
do {
    var state = makeState()
    state.origX = 1480; state.origY = -710; state.origW = 1145; state.origH = 710
    state.targetX = 75; state.targetY = 38; state.targetW = 1656; state.targetH = 1070
    check("orig off screen = not corrupted", !state.isCorrupted(mainScreenFrame: mainScreenFrame))
}

print("Test 7: isCorrupted — missing frames")
do {
    let state = makeState()
    check("no frames = not corrupted", !state.isCorrupted(mainScreenFrame: mainScreenFrame))
}

print("Test 8: isNearTarget — within tolerance")
do {
    var state = makeState()
    state.targetX = 75; state.targetY = 38; state.targetW = 1656; state.targetH = 1070
    let currentFrame = CGRect(x: 100, y: 50, width: 1656, height: 1070)
    check("25px offset within 150 tolerance", state.isNearTarget(currentFrame: currentFrame))
}

print("Test 9: isNearTarget — outside tolerance")
do {
    var state = makeState()
    state.targetX = 75; state.targetY = 38; state.targetW = 1656; state.targetH = 1070
    let currentFrame = CGRect(x: 500, y: 500, width: 1656, height: 1070)
    check("425px offset outside 150 tolerance", !state.isNearTarget(currentFrame: currentFrame))
}

print("Test 10: isNearTarget — no target frame returns true")
do {
    let state = makeState()
    let currentFrame = CGRect(x: 500, y: 500, width: 1656, height: 1070)
    check("no target frame = true (safe fallback)", state.isNearTarget(currentFrame: currentFrame))
}

// Summary
print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
