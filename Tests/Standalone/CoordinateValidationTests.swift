// Tests/Standalone/CoordinateValidationTests.swift
// Verification: ToggleRecord.isValid() with Quartz↔Cocoa coordinate conversion
// and all multi-monitor screen arrangements that have historically caused bugs.
//
// Run: swift Tests/Standalone/CoordinateValidationTests.swift
//
// WHY THIS FILE EXISTS:
// The isValid() method converts Quartz coordinates (origin top-left, Y down) to
// Cocoa coordinates (origin bottom-left, Y up) before checking mainScreenFrame.contains().
// This conversion has been the root cause of dozens of bugs because:
// - Secondary screens can have negative Y coordinates in Quartz space
// - After conversion, these negative Y values map to valid Cocoa coordinates
// - But the conversion itself (mainScreenHeight - quartzY) can produce unexpected results
// - Any "safety validation" in the restore path will reject valid coordinates for some layout

import Foundation
import CoreGraphics

// MARK: - ToggleRecord (mirrors Sources/Hook/ClaudeHookModels.swift:122-153)

struct TestToggleRecord: Equatable {
    let windowID: UInt32
    let pid: Int32
    let origFrame: CGRect
    let sourceSpace: Int
    let sourceDisplay: Int
    let sourceYabaiDisp: Int
    let sourceDispSpace: Int
    let targetFrame: CGRect
    let targetDisplay: Int
    let toggledAt: Date
    let sessionID: String?

    /// Exact copy of ToggleRecord.isValid() from ClaudeHookModels.swift:147-152
    func isValid(mainScreenFrame: CGRect) -> Bool {
        let mainScreenHeight = mainScreenFrame.height
        let origCocoaCenter = CGPoint(x: origFrame.midX, y: mainScreenHeight - origFrame.midY)
        let tgtCocoaCenter = CGPoint(x: targetFrame.midX, y: mainScreenHeight - targetFrame.midY)
        return !mainScreenFrame.contains(origCocoaCenter) && mainScreenFrame.contains(tgtCocoaCenter)
    }
}

func makeRecord(origX: CGFloat, origY: CGFloat, origW: CGFloat, origH: CGFloat,
                targetX: CGFloat, targetY: CGFloat, targetW: CGFloat, targetH: CGFloat) -> TestToggleRecord {
    TestToggleRecord(
        windowID: 100, pid: 409,
        origFrame: CGRect(x: origX, y: origY, width: origW, height: origH),
        sourceSpace: 4, sourceDisplay: 2, sourceYabaiDisp: 2, sourceDispSpace: 3,
        targetFrame: CGRect(x: targetX, y: targetY, width: targetW, height: targetH),
        targetDisplay: 0, toggledAt: Date(), sessionID: nil
    )
}

// MARK: - Test harness

var passed = 0
var failed = 0
var currentGroup = ""

func group(_ name: String) { currentGroup = name; print("\n\(name)") }

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

// MARK: - Screen Layout Definitions
// These represent real macOS screen configurations (Quartz coordinates, origin top-left)

/// MacBook Pro 14" internal display
let mainScreenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)

/// Typical external monitor ABOVE MacBook (Quartz: y is negative above main screen)
/// In Quartz: main screen origin is (0,0), screens above have y < 0
let secondaryAboveFrame = CGRect(x: 360, y: -1440, width: 2560, height: 1440)

/// External monitor BELOW MacBook (Quartz: y > mainScreenHeight)
let secondaryBelowFrame = CGRect(x: 200, y: 1117, width: 1920, height: 1080)

/// External monitor to the LEFT (Quartz: x is negative)
let secondaryLeftFrame = CGRect(x: -1920, y: 0, width: 1920, height: 1080)

/// External monitor to the RIGHT (Quartz: x > mainScreenWidth)
let secondaryRightFrame = CGRect(x: 1728, y: 0, width: 2560, height: 1440)

/// Ultra-wide monitor (very wide, placed right of MacBook)
let ultrawideRightFrame = CGRect(x: 1728, y: -161, width: 3440, height: 1440)

// MARK: - Tests

group("1. isValid() — Quartz↔Cocoa conversion correctness")
do {
    // The actual coordinate conversion in isValid():
    // cocoaY = mainScreenHeight - quartzY
    // For mainScreenHeight = 1117:
    //   quartzY=0     → cocoaY=1117 (bottom of main screen in Cocoa)
    //   quartzY=1117  → cocoaY=0    (top of main screen in Cocoa)
    //   quartzY=-720  → cocoaY=1837 (above main screen in Cocoa)
    //   quartzY=1500  → cocoaY=-383 (below main screen in Cocoa)

    // Verify the math directly
    let h = mainScreenFrame.height // 1117
    check("quartzY=558 (mid main) → cocoaY=559 (mid main)",
           h - 558 == 559)
    check("quartzY=0 (top main) → cocoaY=1117 (bottom main)",
           h - 0 == 1117)
    check("quartzY=-720 (above) → cocoaY=1837 (above in Cocoa)",
           h - (-720) == 1837)
}

group("2. isValid() — standard toggle (secondary → main)")
do {
    // Window on secondary screen above main, maximized on main screen
    let record = makeRecord(
        origX: 1480, origY: -710, origW: 1145, origH: 710,
        targetX: 75, targetY: 38, targetW: 1656, targetH: 1070
    )
    // origFrame center: (2052, -355) in Quartz
    // Cocoa origCenter: (2052, 1117-(-355)) = (2052, 1472) — outside mainScreenFrame ✓
    // targetFrame center: (903, 573) in Quartz
    // Cocoa tgtCenter: (903, 1117-573) = (903, 544) — inside mainScreenFrame ✓
    check("secondary above → main is valid", record.isValid(mainScreenFrame: mainScreenFrame))
}

group("3. isValid() — secondary screen BELOW main")
do {
    let record = makeRecord(
        origX: 500, origY: 1400, origW: 1920, origH: 1080,
        targetX: 75, targetY: 38, targetW: 1656, targetH: 1070
    )
    // origFrame center: (1460, 1940) in Quartz
    // Cocoa origCenter.y: 1117-1940 = -823 — outside mainScreenFrame ✓
    // targetFrame center: (903, 573) in Quartz
    // Cocoa tgtCenter.y: 1117-573 = 544 — inside mainScreenFrame ✓
    check("secondary below → main is valid", record.isValid(mainScreenFrame: mainScreenFrame))
}

group("4. isValid() — secondary screen LEFT of main")
do {
    let record = makeRecord(
        origX: -960, origY: 100, origW: 1920, origH: 1080,
        targetX: 75, targetY: 38, targetW: 1656, targetH: 1070
    )
    // origFrame center: (0, 640) in Quartz → Cocoa origCenter: (0, 477)
    // Cocoa mainScreenFrame is (0,0,1728,1117). (0,477) IS inside mainScreenFrame!
    // So this should be INVALID — orig is on main screen after Cocoa conversion
    // Wait, actually x=0 is the edge. Let's use a more clearly secondary position.
    check("secondary left center (0,640) → Cocoa (0,477) on main edge",
           mainScreenFrame.contains(CGPoint(x: 0, y: 477)))

    // Properly off-screen to the left
    let record2 = makeRecord(
        origX: -1500, origY: 100, origW: 1920, origH: 1080,
        targetX: 75, targetY: 38, targetW: 1656, targetH: 1070
    )
    // origFrame center: (-540, 640) in Quartz → Cocoa (-540, 477)
    // x=-540 is outside mainScreenFrame → valid
    check("secondary left (-540,640) → Cocoa (-540,477) is valid",
           record2.isValid(mainScreenFrame: mainScreenFrame))
}

group("5. isValid() — secondary screen RIGHT of main")
do {
    let record = makeRecord(
        origX: 2000, origY: 200, origW: 2560, origH: 1440,
        targetX: 75, targetY: 38, targetW: 1656, targetH: 1070
    )
    // origFrame center: (3280, 920) in Quartz → Cocoa (3280, 197)
    // x=3280 is outside mainScreenFrame → valid
    check("secondary right → main is valid", record.isValid(mainScreenFrame: mainScreenFrame))
}

group("6. isValid() — ultra-wide monitor with vertical offset")
do {
    let record = makeRecord(
        origX: 2500, origY: -500, origW: 3440, origH: 1440,
        targetX: 75, targetY: 38, targetW: 1656, targetH: 1070
    )
    // origFrame center: (4220, 220) in Quartz → Cocoa (4220, 897)
    // x=4220 is outside mainScreenFrame → valid
    check("ultra-wide right with negative Y → main is valid",
           record.isValid(mainScreenFrame: mainScreenFrame))
}

group("7. isValid() — corrupted data (orig on main screen)")
do {
    let record = makeRecord(
        origX: 100, origY: 100, origW: 500, origH: 500,
        targetX: 75, targetY: 38, targetW: 1656, targetH: 1070
    )
    // origFrame center: (350, 350) in Quartz → Cocoa (350, 767)
    // Both x=350 and y=767 are inside mainScreenFrame → orig IS on main → invalid
    check("orig on main screen is invalid", !record.isValid(mainScreenFrame: mainScreenFrame))
}

group("8. isValid() — both orig and target off-screen")
do {
    let record = makeRecord(
        origX: 1480, origY: -710, origW: 1145, origH: 710,
        targetX: -2000, targetY: -2000, targetW: 1656, targetH: 1070
    )
    check("target off-screen is invalid", !record.isValid(mainScreenFrame: mainScreenFrame))
}

group("9. isValid() — edge cases at main screen boundaries")
do {
    // Window center exactly at main screen edge
    let edgeRecord = makeRecord(
        origX: 1728, origY: 0, origW: 100, origH: 100,
        targetX: 75, targetY: 38, targetW: 1656, targetH: 1070
    )
    // origFrame center: (1778, 50) in Quartz → Cocoa (1778, 1067)
    // x=1778 is outside mainScreenFrame(width=1728) → orig is off-screen → valid
    check("orig center just past right edge of main screen is valid",
           edgeRecord.isValid(mainScreenFrame: mainScreenFrame))

    // Window center exactly at top-left corner of main screen
    let cornerRecord = makeRecord(
        origX: -100, origY: -100, origW: 100, origH: 100,
        targetX: 75, targetY: 38, targetW: 1656, targetH: 1070
    )
    // origFrame center: (-50, -50) in Quartz → Cocoa (-50, 1167)
    // x=-50 is outside mainScreenFrame → valid
    check("orig center just outside top-left corner is valid",
           cornerRecord.isValid(mainScreenFrame: mainScreenFrame))
}

group("10. isValid() — THE recurring bug scenario")
do {
    // This exact scenario has caused dozens of bugs:
    // Window was at (1480, -707) on a secondary screen ABOVE the MacBook.
    // A "safety validation" checked if origFrame was "on any screen" and rejected it.
    // But (1480, -707) is a perfectly valid position for a secondary screen above.
    let bugRecord = makeRecord(
        origX: 1480, origY: -707, origW: 1146, origH: 707,
        targetX: 75, targetY: 38, targetW: 1656, targetH: 1070
    )
    check("BUG FIX: (1480,-707) is valid secondary screen position",
           bugRecord.isValid(mainScreenFrame: mainScreenFrame))

    // Negative Y does NOT mean "off-screen" in Quartz coordinates.
    // It means "above the main screen" — which is where secondary monitors often are.
    // The Quartz coordinate system origin is at the TOP-LEFT of the main screen.
    // Screens physically above the MacBook have negative Y values.
    check("negative Y coordinates are legal in Quartz space",
           bugRecord.origFrame.origin.y < 0 &&
           bugRecord.isValid(mainScreenFrame: mainScreenFrame))
}

group("11. isValid() — different main screen sizes")
do {
    // 13" MacBook Air
    let smallMainFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let record = makeRecord(
        origX: 1600, origY: -450, origW: 1920, origH: 1080,
        targetX: 50, targetY: 25, targetW: 1380, targetH: 850
    )
    check("13\" MacBook Air + external above is valid",
           record.isValid(mainScreenFrame: smallMainFrame))

    // 16" MacBook Pro with ProMotion
    let largeMainFrame = CGRect(x: 0, y: 0, width: 1920, height: 1217)
    let record2 = makeRecord(
        origX: 2100, origY: -600, origW: 2560, origH: 1440,
        targetX: 80, targetY: 40, targetW: 1840, targetH: 1170
    )
    check("16\" MacBook Pro + external above is valid",
           record2.isValid(mainScreenFrame: largeMainFrame))

    // 4K external as main display
    let _4kMainFrame = CGRect(x: 0, y: 0, width: 3840, height: 2160)
    let record3 = makeRecord(
        origX: 100, origY: 2200, origW: 1728, origH: 1117,
        targetX: 50, targetY: 25, targetW: 3780, targetH: 2110
    )
    check("4K main + MacBook below is valid",
           record3.isValid(mainScreenFrame: _4kMainFrame))
}

group("12. isValid() — three-monitor setups")
do {
    // MacBook in middle, external above and below
    let recordAbove = makeRecord(
        origX: 360, origY: -1440, origW: 2560, origH: 1440,
        targetX: 75, targetY: 38, targetW: 1656, targetH: 1070
    )
    let recordBelow = makeRecord(
        origX: 200, origY: 1117, origW: 1920, origH: 1080,
        targetX: 75, targetY: 38, targetW: 1656, targetH: 1070
    )
    check("external above → main is valid",
           recordAbove.isValid(mainScreenFrame: mainScreenFrame))
    check("external below → main is valid",
           recordBelow.isValid(mainScreenFrame: mainScreenFrame))
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
if failed > 0 {
    print("\n⚠️  FAILURES DETECTED — these represent coordinates that would be")
    print("   incorrectly rejected by a buggy validation. Fix the code, not the test.")
}
exit(failed > 0 ? 1 : 0)
