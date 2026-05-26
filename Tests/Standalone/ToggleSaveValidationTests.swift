// Tests/Standalone/ToggleSaveValidationTests.swift
// Verification: ToggleEngine.save() origFrame validation, AX frame tolerance matching,
//               shouldRestoreCurrentWindow decision chain
// Mirrors: Sources/Toggle/ToggleEngine.swift:41-59, Sources/Window/WindowManager+AXHelpers.swift:158-178,
//          Sources/Window/WindowManager+Toggle.swift:313-373
// Run: swift Tests/Standalone/ToggleSaveValidationTests.swift

import Foundation
import CoreGraphics

// MARK: - Extracted pure logic

/// Mirrors ToggleEngine.save() validation: rejects origFrame whose center is on main screen
/// ToggleEngine.swift:41-59
func shouldRejectOrigFrame(origFrame: CGRect, mainScreenFrame: CGRect?) -> Bool {
    guard let mainScreenFrame = mainScreenFrame else { return false }
    let origCenter = CGPoint(x: origFrame.midX, y: origFrame.midY)
    return mainScreenFrame.contains(origCenter)
}

/// Mirrors AX frame tolerance matching (WindowManager+AXHelpers.swift:158-178)
/// Returns true if applied frame is close enough to target
func frameWithinTolerance(applied: CGRect, target: CGRect, tolerance: CGFloat) -> Bool {
    let positionMatches = abs(applied.origin.x - target.origin.x) <= tolerance &&
                         abs(applied.origin.y - target.origin.y) <= tolerance
    let sizeCloseEnough = abs(applied.width - target.width) <= tolerance * 2 &&
                         abs(applied.height - target.height) <= tolerance * 2
    return positionMatches && sizeCloseEnough
}

/// Mirrors the shouldRestoreCurrentWindow decision chain (WindowManager+Toggle.swift:313-373)
/// Pure logic: focusedOnMain + hasRecord + isValid → should restore
struct RestoreDecision {
    let focusedOnMain: Bool
    let hasToggleRecord: Bool
    let recordIsValid: Bool

    /// The pure decision logic extracted from shouldRestoreCurrentWindow
    var shouldRestore: Bool {
        // Step 1: If focused window is NOT on main screen → false (it's on secondary, needs move not restore)
        guard focusedOnMain else { return false }
        // Step 2: Must have a toggle record
        guard hasToggleRecord else { return false }
        // Step 3: Record must pass validation (orig off-screen, target on-screen)
        guard recordIsValid else { return false }
        return true
    }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

// MARK: - shouldRejectOrigFrame

print("1. shouldRejectOrigFrame — orig center on main screen → reject")
do {
    let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1117)
    let origFrame = CGRect(x: 500, y: 300, width: 800, height: 600) // center (900, 600) is on main
    check("orig on main → reject", shouldRejectOrigFrame(origFrame: origFrame, mainScreenFrame: mainScreen))
}

print("\n2. shouldRejectOrigFrame — orig center off main screen → accept")
do {
    let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1117)
    // Secondary above: negative Y in Quartz
    let origFrame = CGRect(x: 100, y: -800, width: 800, height: 600) // center (500, -500) off main
    check("orig above main → accept (not rejected)", !shouldRejectOrigFrame(origFrame: origFrame, mainScreenFrame: mainScreen))

    // Secondary right
    let origRight = CGRect(x: 2000, y: 100, width: 800, height: 600) // center (2400, 400) off main
    check("orig right of main → accept", !shouldRejectOrigFrame(origFrame: origRight, mainScreenFrame: mainScreen))

    // Secondary below
    let origBelow = CGRect(x: 100, y: 1200, width: 800, height: 600)
    check("orig below main → accept", !shouldRejectOrigFrame(origFrame: origBelow, mainScreenFrame: mainScreen))
}

print("\n3. shouldRejectOrigFrame — orig at exact boundary of main screen")
do {
    let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1117)
    // Center exactly at right edge
    let atRightEdge = CGRect(x: 1520, y: 300, width: 800, height: 600) // midX=1920
    // CGRect.contains is exclusive of max edge
    check("center at exact right edge → not contained (CGRect excludes max)", !mainScreen.contains(CGPoint(x: 1920, y: 300)))

    // Center just inside
    let justInside = CGRect(x: 1519, y: 300, width: 800, height: 600) // midX=1919
    check("center just inside right edge → contained", mainScreen.contains(CGPoint(x: 1919, y: 300)))
}

print("\n4. shouldRejectOrigFrame — nil main screen → never reject")
do {
    let origFrame = CGRect(x: 500, y: 300, width: 800, height: 600)
    check("nil mainScreen → never reject", !shouldRejectOrigFrame(origFrame: origFrame, mainScreenFrame: nil))
}

print("\n5. shouldRejectOrigFrame — different main screen sizes")
do {
    // MacBook Air 13" (2560x1600 logical)
    let macBookAir = CGRect(x: 0, y: 0, width: 2560, height: 1600)
    let origOnMacBook = CGRect(x: 800, y: 400, width: 900, height: 600) // center (1250, 700)
    check("13\" MacBook: orig on screen → reject", shouldRejectOrigFrame(origFrame: origOnMacBook, mainScreenFrame: macBookAir))

    // 4K external (3840x2160)
    let fourK = CGRect(x: 0, y: 0, width: 3840, height: 2160)
    let origOff4K = CGRect(x: -1000, y: 500, width: 800, height: 600) // center (-600, 800) off screen
    check("4K: orig off screen → accept", !shouldRejectOrigFrame(origFrame: origOff4K, mainScreenFrame: fourK))
}

// MARK: - frameWithinTolerance

print("\n6. frameWithinTolerance — exact match")
do {
    let frame = CGRect(x: 100, y: 200, width: 800, height: 600)
    check("exact match", frameWithinTolerance(applied: frame, target: frame, tolerance: 5))
}

print("\n7. frameWithinTolerance — within position tolerance")
do {
    let target = CGRect(x: 100, y: 200, width: 800, height: 600)
    let applied = CGRect(x: 103, y: 198, width: 800, height: 600)
    check("3px position offset within 5px tolerance", frameWithinTolerance(applied: applied, target: target, tolerance: 5))
}

print("\n8. frameWithinTolerance — outside position tolerance")
do {
    let target = CGRect(x: 100, y: 200, width: 800, height: 600)
    let applied = CGRect(x: 108, y: 200, width: 800, height: 600) // 8px off
    check("8px position offset outside 5px tolerance", !frameWithinTolerance(applied: applied, target: target, tolerance: 5))
}

print("\n9. frameWithinTolerance — size within tolerance (2x multiplier)")
do {
    let target = CGRect(x: 100, y: 200, width: 800, height: 600)
    // Size diff = 8px, tolerance*2 = 10px → within
    let applied = CGRect(x: 100, y: 200, width: 808, height: 592)
    check("8px size diff within 5*2=10 tolerance", frameWithinTolerance(applied: applied, target: target, tolerance: 5))
}

print("\n10. frameWithinTolerance — size outside tolerance")
do {
    let target = CGRect(x: 100, y: 200, width: 800, height: 600)
    // Size diff = 12px, tolerance*2 = 10px → outside
    let applied = CGRect(x: 100, y: 200, width: 812, height: 600)
    check("12px width diff outside 5*2=10 tolerance", !frameWithinTolerance(applied: applied, target: target, tolerance: 5))
}

print("\n11. frameWithinTolerance — position OK but size not")
do {
    let target = CGRect(x: 100, y: 200, width: 800, height: 600)
    let applied = CGRect(x: 102, y: 198, width: 825, height: 600) // pos OK, width 25px off
    check("position OK but size 25px off → fails", !frameWithinTolerance(applied: applied, target: target, tolerance: 5))
}

print("\n12. frameWithinTolerance — yabai tiling adjustment (typical)")
do {
    let target = CGRect(x: 0, y: 0, width: 1920, height: 1117)
    // yabai might adjust by ~30px for title bar
    let applied = CGRect(x: 0, y: 25, width: 1920, height: 1092)
    check("yabai 25px adjustment within 30px tolerance", frameWithinTolerance(applied: applied, target: target, tolerance: 30))
}

// MARK: - RestoreDecision

print("\n13. RestoreDecision — all conditions met → restore")
do {
    let decision = RestoreDecision(focusedOnMain: true, hasToggleRecord: true, recordIsValid: true)
    check("all true → should restore", decision.shouldRestore)
}

print("\n14. RestoreDecision — focused on secondary → no restore")
do {
    let decision = RestoreDecision(focusedOnMain: false, hasToggleRecord: true, recordIsValid: true)
    check("focused on secondary → no restore", !decision.shouldRestore)
}

print("\n15. RestoreDecision — no toggle record → no restore")
do {
    let decision = RestoreDecision(focusedOnMain: true, hasToggleRecord: false, recordIsValid: true)
    check("no record → no restore", !decision.shouldRestore)
}

print("\n16. RestoreDecision — corrupted record → no restore")
do {
    let decision = RestoreDecision(focusedOnMain: true, hasToggleRecord: true, recordIsValid: false)
    check("corrupted record → no restore", !decision.shouldRestore)
}

print("\n17. RestoreDecision — all false → no restore")
do {
    let decision = RestoreDecision(focusedOnMain: false, hasToggleRecord: false, recordIsValid: false)
    check("all false → no restore", !decision.shouldRestore)
}

print("\n18. RestoreDecision — only has record but not valid → no restore")
do {
    let decision = RestoreDecision(focusedOnMain: true, hasToggleRecord: true, recordIsValid: false)
    check("has record but invalid → no restore", !decision.shouldRestore)
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
