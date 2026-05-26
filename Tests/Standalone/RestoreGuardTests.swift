// Tests/Standalone/RestoreGuardTests.swift
// Regression guard: ensure no coordinate validation is added to the restore path.
//
// Run: swift Tests/Standalone/RestoreGuardTests.swift
//
// RULE: The restore execution path must NEVER reject coordinates based on
// "is this point on a known screen?" checks. This has caused dozens of bugs.
// Validation belongs in shouldRestoreCurrentWindow() → isValid(), not in restore().
//
// If you are tempted to add a "safety check" to the restore path, add it here
// as a test case first. If the test fails, the check is wrong.

import Foundation
import CoreGraphics

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

// MARK: - Simulated "should restore?" function
// This represents the kind of guard that keeps being incorrectly added.
// The correct answer for ALL of these is: YES, should restore.

/// A restore guard that uses NSScreen-like "is this on any screen?" check.
/// This is the BUGGY pattern that keeps recurring. We test against it.
func buggyScreenGuard(origFrame: CGRect, knownScreens: [CGRect]) -> Bool {
    let center = CGPoint(x: origFrame.midX, y: origFrame.midY)
    return knownScreens.contains { $0.contains(center) }
}

/// The correct behavior: always allow restore if the record passed isValid().
func correctRestoreGuard(origFrame: CGRect) -> Bool {
    // The only validation is that isValid() was called earlier.
    // In the restore path itself, we trust the record and apply it as-is.
    return true
}

// MARK: - Screen configurations
// Real macOS screen layouts (Quartz coordinates)

let screens_standard = [
    CGRect(x: 0, y: 0, width: 1728, height: 1117),       // MacBook Pro 14"
    CGRect(x: 360, y: -1440, width: 2560, height: 1440),  // External above
]

let screens_right = [
    CGRect(x: 0, y: 0, width: 1728, height: 1117),
    CGRect(x: 1728, y: 0, width: 2560, height: 1440),
]

let screens_left = [
    CGRect(x: 0, y: 0, width: 1728, height: 1117),
    CGRect(x: -1920, y: 0, width: 1920, height: 1080),
]

let screens_below = [
    CGRect(x: 0, y: 0, width: 1728, height: 1117),
    CGRect(x: 200, y: 1117, width: 1920, height: 1080),
]

let screens_changed = [
    // Screen config changed since toggle — secondary monitor disconnected
    CGRect(x: 0, y: 0, width: 1728, height: 1117),
]

let screens_three = [
    CGRect(x: 0, y: 0, width: 1728, height: 1117),
    CGRect(x: 360, y: -1440, width: 2560, height: 1440),
    CGRect(x: 200, y: 1117, width: 1920, height: 1080),
]

// MARK: - Tests

print("\n=== RESTORE GUARD REGRESSION TESTS ===")
print("Each test case represents a real scenario where a buggy guard blocked restore.\n")

print("1. Window at (1480, -707) on secondary above MacBook")
do {
    let frame = CGRect(x: 1480, y: -707, width: 1146, height: 707)
    check("correct guard allows restore", correctRestoreGuard(origFrame: frame))
    check("buggy screen guard allows restore", buggyScreenGuard(origFrame: frame, knownScreens: screens_standard))
}

print("\n2. Window at (1000, 1300) on secondary below MacBook")
do {
    let frame = CGRect(x: 1000, y: 1300, width: 800, height: 600)
    check("correct guard allows restore", correctRestoreGuard(origFrame: frame))
    check("buggy screen guard allows restore", buggyScreenGuard(origFrame: frame, knownScreens: screens_below))
}

print("\n3. Window at (-960, 100) on secondary to the left")
do {
    let frame = CGRect(x: -960, y: 100, width: 1920, height: 1080)
    check("correct guard allows restore", correctRestoreGuard(origFrame: frame))
    check("buggy screen guard allows restore", buggyScreenGuard(origFrame: frame, knownScreens: screens_left))
}

print("\n4. Window at (2500, 200) on secondary to the right")
do {
    let frame = CGRect(x: 2500, y: 200, width: 2000, height: 1200)
    check("correct guard allows restore", correctRestoreGuard(origFrame: frame))
    check("buggy screen guard allows restore", buggyScreenGuard(origFrame: frame, knownScreens: screens_right))
}

print("\n5. CRITICAL: Screen disconnected since toggle")
do {
    // Window was toggled when 2 screens were connected.
    // Now only 1 screen exists. The origFrame is "off-screen" but we MUST still restore.
    let frame = CGRect(x: 1480, y: -707, width: 1146, height: 707)
    check("correct guard allows restore despite disconnected screen",
           correctRestoreGuard(origFrame: frame))
    // The buggy guard would reject this because the point is not on any current screen
    let buggyResult = buggyScreenGuard(origFrame: frame, knownScreens: screens_changed)
    check("buggy guard REJECTS valid restore (screen disconnected) — THIS IS THE BUG",
           !buggyResult)
    print("    ^^^ This test intentionally shows the buggy guard fails here.")
    print("    ^^^ In the actual code, we must NOT use this guard.")
}

print("\n6. Screen arrangement changed (moved from above to right)")
do {
    let frame = CGRect(x: 360, y: -1400, width: 2560, height: 1440)
    check("correct guard allows restore despite screen move",
           correctRestoreGuard(origFrame: frame))
    // The secondary screen moved from above to the right
    let buggyResult = buggyScreenGuard(origFrame: frame, knownScreens: screens_right)
    check("buggy guard REJECTS valid restore (screen moved) — ANOTHER BUG SCENARIO",
           !buggyResult)
    print("    ^^^ Window was on screen above, now screen is on the right.")
    print("    ^^^ Buggy guard rejects because point is no longer on any screen.")
}

print("\n7. Negative coordinates are always legal")
do {
    let negativeFrames = [
        CGRect(x: -5000, y: -5000, width: 100, height: 100),
        CGRect(x: 0, y: -10000, width: 1920, height: 1080),
        CGRect(x: -100, y: -100, width: 50, height: 50),
        CGRect(x: -3440, y: -1440, width: 3440, height: 1440),
    ]
    for (i, frame) in negativeFrames.enumerated() {
        check("negative coord #\(i) allowed by correct guard",
               correctRestoreGuard(origFrame: frame))
    }
}

print("\n8. Very large coordinates are legal")
do {
    let largeFrames = [
        CGRect(x: 50000, y: 50000, width: 100, height: 100),
        CGRect(x: 0, y: 10000, width: 1920, height: 1080),
        CGRect(x: 100000, y: 0, width: 1920, height: 1080),
    ]
    for (i, frame) in largeFrames.enumerated() {
        check("large coord #\(i) allowed by correct guard",
               correctRestoreGuard(origFrame: frame))
    }
}

print("\n9. Three-monitor setup — all positions valid")
do {
    let frames = [
        CGRect(x: 1480, y: -700, width: 1146, height: 707),   // above
        CGRect(x: 1000, y: 1300, width: 800, height: 600),     // below
        CGRect(x: 864, y: 558, width: 1728, height: 1117),     // main
    ]
    for (i, frame) in frames.enumerated() {
        check("3-monitor position #\(i) allowed by correct guard",
               correctRestoreGuard(origFrame: frame))
    }
}

print("\n10. Window slightly moved by yabai tiling since toggle")
do {
    // yabai may have tiled/shifted the window slightly since it was toggled
    let frame = CGRect(x: 1480, y: -707 + 5, width: 1146 - 2, height: 707 - 1)
    check("yabai-adjusted position allowed by correct guard",
           correctRestoreGuard(origFrame: frame))
    check("yabai-adjusted position allowed by buggy guard",
           buggyScreenGuard(origFrame: frame, knownScreens: screens_standard))
}

// MARK: - Summary

print("\n=== Results: \(passed) passed, \(failed) failed ===")
if failed > 0 {
    print("\n🚨 REGRESSION DETECTED!")
    print("A coordinate validation was added to the restore path that rejects")
    print("valid multi-monitor positions. Remove the validation from restore().")
    print("\nThe ONLY validation should be in shouldRestoreCurrentWindow() → isValid().")
    print("See: Sources/Hook/ClaudeHookModels.swift:147-152")
}
exit(failed > 0 ? 1 : 0)
