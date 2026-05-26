// Tests/Standalone/CoordinateKitLogicTests.swift
// Verification: QuartzRect geometry, DisplayIdentifier/SpaceIdentifier descriptions,
//               CoordinateKit.framesMatch tolerance logic
// Mirrors: Sources/Space/CoordinateKit.swift:11-91, 200-207
// Run: swift Tests/Standalone/CoordinateKitLogicTests.swift

import Foundation
import CoreGraphics

// MARK: - Mirrored types

enum DisplayIdentifier: Equatable, CustomStringConvertible {
    case yabaiIndex(Int)
    case screenArrayIndex(Int)
    case cgDirectDisplayID(UInt32)

    var description: String {
        switch self {
        case .yabaiIndex(let i): return "yabai(\(i))"
        case .screenArrayIndex(let i): return "screen[\(i)]"
        case .cgDirectDisplayID(let id): return "cgDisplay(\(id))"
        }
    }

    var yabaiIndex: Int? { if case .yabaiIndex(let i) = self { return i } else { return nil } }
}

enum SpaceIdentifier: Equatable, CustomStringConvertible {
    case yabaiIndex(Int)
    case nativeID(Int64)

    var description: String {
        switch self {
        case .yabaiIndex(let i): return "yabai_space(\(i))"
        case .nativeID(let id): return "native_space(\(id))"
        }
    }

    var yabaiIndex: Int? { if case .yabaiIndex(let i) = self { return i } else { return nil } }
}

struct QuartzRect: Equatable, CustomStringConvertible {
    let origin: CGPoint
    let size: CGSize

    var x: CGFloat { origin.x }
    var y: CGFloat { origin.y }
    var width: CGFloat { size.width }
    var height: CGFloat { size.height }
    var midX: CGFloat { origin.x + size.width / 2 }
    var midY: CGFloat { origin.y + size.height / 2 }
    var maxX: CGFloat { origin.x + size.width }
    var maxY: CGFloat { origin.y + size.height }

    init(_ cgRect: CGRect) {
        self.origin = cgRect.origin
        self.size = cgRect.size
    }

    init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.origin = CGPoint(x: x, y: y)
        self.size = CGSize(width: width, height: height)
    }

    var cgRect: CGRect { CGRect(origin: origin, size: size) }

    var description: String { "\(Int(x)),\(Int(y)) \(Int(width))x\(Int(height))" }

    func centerIsInside(_ screenFrame: CGRect) -> Bool {
        screenFrame.contains(CGPoint(x: midX, y: midY))
    }
}

/// Mirrors CoordinateKit.framesMatch (CoordinateKit.swift:200-207)
func framesMatch(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 10, heightTolerance: CGFloat? = nil) -> Bool {
    let ht = heightTolerance ?? tolerance * 2
    let positionMatches = abs(a.origin.x - b.origin.x) <= tolerance &&
                         abs(a.origin.y - b.origin.y) <= tolerance
    let sizeMatches = abs(a.width - b.width) <= tolerance * 2 &&
                     abs(a.height - b.height) <= ht
    return positionMatches && sizeMatches
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

// MARK: - DisplayIdentifier

print("1. DisplayIdentifier — description")
do {
    checkEqual("yabaiIndex", DisplayIdentifier.yabaiIndex(1).description, "yabai(1)")
    checkEqual("yabaiIndex 2", DisplayIdentifier.yabaiIndex(3).description, "yabai(3)")
    checkEqual("screenArrayIndex", DisplayIdentifier.screenArrayIndex(0).description, "screen[0]")
    checkEqual("cgDirectDisplayID", DisplayIdentifier.cgDirectDisplayID(12345).description, "cgDisplay(12345)")
}

print("\n2. DisplayIdentifier — equality")
do {
    check("same yabai equal", DisplayIdentifier.yabaiIndex(1) == DisplayIdentifier.yabaiIndex(1))
    check("different yabai not equal", DisplayIdentifier.yabaiIndex(1) != DisplayIdentifier.yabaiIndex(2))
    check("different types not equal", DisplayIdentifier.yabaiIndex(1) != DisplayIdentifier.screenArrayIndex(0))
    check("cgDisplay equal", DisplayIdentifier.cgDirectDisplayID(42) == DisplayIdentifier.cgDirectDisplayID(42))
    check("cgDisplay not equal", DisplayIdentifier.cgDirectDisplayID(42) != DisplayIdentifier.cgDirectDisplayID(43))
}

print("\n3. DisplayIdentifier — yabaiIndex accessor")
do {
    checkEqual("yabaiIndex accessor", DisplayIdentifier.yabaiIndex(5).yabaiIndex, 5)
    check("screenArrayIndex has no yabaiIndex", DisplayIdentifier.screenArrayIndex(0).yabaiIndex == nil)
    check("cgDisplay has no yabaiIndex", DisplayIdentifier.cgDirectDisplayID(42).yabaiIndex == nil)
}

// MARK: - SpaceIdentifier

print("\n4. SpaceIdentifier — description")
do {
    checkEqual("yabaiIndex", SpaceIdentifier.yabaiIndex(1).description, "yabai_space(1)")
    checkEqual("yabaiIndex 10", SpaceIdentifier.yabaiIndex(10).description, "yabai_space(10)")
    checkEqual("nativeID", SpaceIdentifier.nativeID(12345).description, "native_space(12345)")
}

print("\n5. SpaceIdentifier — equality")
do {
    check("same yabai equal", SpaceIdentifier.yabaiIndex(1) == SpaceIdentifier.yabaiIndex(1))
    check("different yabai not equal", SpaceIdentifier.yabaiIndex(1) != SpaceIdentifier.yabaiIndex(2))
    check("different types not equal", SpaceIdentifier.yabaiIndex(1) != SpaceIdentifier.nativeID(1))
    check("same nativeID equal", SpaceIdentifier.nativeID(99) == SpaceIdentifier.nativeID(99))
}

print("\n6. SpaceIdentifier — yabaiIndex accessor")
do {
    checkEqual("yabaiIndex accessor", SpaceIdentifier.yabaiIndex(3).yabaiIndex, 3)
    check("nativeID has no yabaiIndex", SpaceIdentifier.nativeID(99).yabaiIndex == nil)
}

// MARK: - QuartzRect

print("\n7. QuartzRect — basic properties")
do {
    let r = QuartzRect(x: 100, y: 200, width: 800, height: 600)
    checkEqual("x", r.x, 100.0)
    checkEqual("y", r.y, 200.0)
    checkEqual("width", r.width, 800.0)
    checkEqual("height", r.height, 600.0)
}

print("\n8. QuartzRect — computed mid/max")
do {
    let r = QuartzRect(x: 100, y: 200, width: 800, height: 600)
    checkEqual("midX", r.midX, 500.0)
    checkEqual("midY", r.midY, 500.0)
    checkEqual("maxX", r.maxX, 900.0)
    checkEqual("maxY", r.maxY, 800.0)
}

print("\n9. QuartzRect — mid/max with zero origin")
do {
    let r = QuartzRect(x: 0, y: 0, width: 1920, height: 1117)
    checkEqual("midX", r.midX, 960.0)
    checkEqual("midY", r.midY, 558.5)
    checkEqual("maxX", r.maxX, 1920.0)
    checkEqual("maxY", r.maxY, 1117.0)
}

print("\n10. QuartzRect — init from CGRect")
do {
    let cg = CGRect(x: 50, y: 75, width: 640, height: 480)
    let r = QuartzRect(cg)
    checkEqual("x from CGRect", r.x, 50.0)
    checkEqual("y from CGRect", r.y, 75.0)
    checkEqual("width from CGRect", r.width, 640.0)
    checkEqual("height from CGRect", r.height, 480.0)
}

print("\n11. QuartzRect — roundtrip to CGRect")
do {
    let r = QuartzRect(x: 100, y: 200, width: 800, height: 600)
    let cg = r.cgRect
    checkEqual("cgRect.origin.x", cg.origin.x, 100.0)
    checkEqual("cgRect.origin.y", cg.origin.y, 200.0)
    checkEqual("cgRect.width", cg.size.width, 800.0)
    checkEqual("cgRect.height", cg.size.height, 600.0)
}

print("\n12. QuartzRect — description format")
do {
    let r = QuartzRect(x: 100, y: 200, width: 1920, height: 1117)
    checkEqual("description", r.description, "100,200 1920x1117")
    checkEqual("zero origin", QuartzRect(x: 0, y: 0, width: 800, height: 600).description, "0,0 800x600")
}

print("\n13. QuartzRect — equality")
do {
    let a = QuartzRect(x: 100, y: 200, width: 800, height: 600)
    let b = QuartzRect(x: 100, y: 200, width: 800, height: 600)
    let c = QuartzRect(x: 101, y: 200, width: 800, height: 600)
    check("same rect equal", a == b)
    check("different x not equal", a != c)
}

print("\n14. QuartzRect — centerIsInside (main screen)")
do {
    let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1117)
    let window = QuartzRect(x: 500, y: 300, width: 800, height: 600)
    check("center on main screen", window.centerIsInside(mainScreen))
}

print("\n15. QuartzRect — centerIsInside (off screen)")
do {
    let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1117)
    let aboveScreen = QuartzRect(x: 100, y: -800, width: 800, height: 600)
    check("center above main → false", !aboveScreen.centerIsInside(mainScreen))

    let rightScreen = QuartzRect(x: 2000, y: 100, width: 800, height: 600)
    check("center right of main → false", !rightScreen.centerIsInside(mainScreen))

    let belowScreen = QuartzRect(x: 100, y: 1200, width: 800, height: 600)
    check("center below main → false", !belowScreen.centerIsInside(mainScreen))
}

print("\n16. QuartzRect — centerIsInside at boundary")
do {
    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1117)
    // Center at (960, 558.5) — clearly inside
    let inside = QuartzRect(x: 560, y: 258.5, width: 800, height: 600)
    check("center clearly inside", inside.centerIsInside(screen))

    // Center exactly at right edge (1920, 300) — CGRect.contains excludes max edge
    let atEdge = QuartzRect(x: 1520, y: 0, width: 800, height: 600)
    check("center at maxX → CGRect excludes max edge", !screen.contains(CGPoint(x: 1920, y: 300)))
}

print("\n17. QuartzRect — negative Y (secondary above)")
do {
    let r = QuartzRect(x: 0, y: -1440, width: 2560, height: 1440)
    checkEqual("negative y", r.y, -1440.0)
    checkEqual("midY negative", r.midY, -1440.0 + 720.0)
    checkEqual("description with negative", r.description, "0,-1440 2560x1440")
}

// MARK: - framesMatch

print("\n18. framesMatch — exact match")
do {
    let a = CGRect(x: 100, y: 200, width: 800, height: 600)
    check("exact match default tolerance", framesMatch(a, a))
    check("exact match tolerance 0", framesMatch(a, a, tolerance: 0))
}

print("\n19. framesMatch — default tolerance (10)")
do {
    let target = CGRect(x: 100, y: 200, width: 800, height: 600)
    let withinPos = CGRect(x: 105, y: 195, width: 800, height: 600)
    check("5px position offset within 10px tolerance", framesMatch(withinPos, target))

    let outsidePos = CGRect(x: 115, y: 200, width: 800, height: 600)
    check("15px position offset outside 10px tolerance", !framesMatch(outsidePos, target))
}

print("\n20. framesMatch — size tolerance is 2x position tolerance")
do {
    let target = CGRect(x: 100, y: 200, width: 800, height: 600)
    // width diff 15px, tolerance*2=20 → within
    let withinSize = CGRect(x: 100, y: 200, width: 815, height: 600)
    check("15px width diff within 10*2=20", framesMatch(withinSize, target))

    // width diff 25px, tolerance*2=20 → outside
    let outsideSize = CGRect(x: 100, y: 200, width: 825, height: 600)
    check("25px width diff outside 10*2=20", !framesMatch(outsideSize, target))
}

print("\n21. framesMatch — custom height tolerance")
do {
    let target = CGRect(x: 100, y: 200, width: 800, height: 600)
    // height diff 15px, default ht=20 → within
    check("15px height diff within default ht=20", framesMatch(CGRect(x: 100, y: 200, width: 800, height: 615), target))

    // height diff 15px, custom heightTolerance=10 → outside
    check("15px height diff outside custom ht=10", !framesMatch(CGRect(x: 100, y: 200, width: 800, height: 615), target, heightTolerance: 10))

    // height diff 5px, custom heightTolerance=10 → within
    check("5px height diff within custom ht=10", framesMatch(CGRect(x: 100, y: 200, width: 800, height: 605), target, heightTolerance: 10))
}

print("\n22. framesMatch — position OK but size not → fails")
do {
    let target = CGRect(x: 100, y: 200, width: 800, height: 600)
    let posOkSizeBad = CGRect(x: 100, y: 200, width: 900, height: 600)
    check("position exact but width 100px off", !framesMatch(posOkSizeBad, target))
}

print("\n23. framesMatch — size OK but position not → fails")
do {
    let target = CGRect(x: 100, y: 200, width: 800, height: 600)
    let sizeOkPosBad = CGRect(x: 200, y: 200, width: 800, height: 600)
    check("size exact but x 100px off", !framesMatch(sizeOkPosBad, target))
}

print("\n24. framesMatch — yabai tiling adjustment (realistic)")
do {
    let target = CGRect(x: 0, y: 0, width: 1920, height: 1117)
    let yabaiAdjusted = CGRect(x: 0, y: 25, width: 1920, height: 1092)
    // pos y diff 25px > 10 → position fails
    check("yabai 25px y-adjust fails default tolerance", !framesMatch(yabaiAdjusted, target))
    // With higher tolerance
    check("yabai 25px y-adjust passes with tolerance 30", framesMatch(yabaiAdjusted, target, tolerance: 30))
}

print("\n25. framesMatch — zero tolerance requires exact")
do {
    let a = CGRect(x: 100, y: 200, width: 800, height: 600)
    let b = CGRect(x: 100.0001, y: 200, width: 800, height: 600)
    check("0.0001px off with 0 tolerance → false", !framesMatch(a, b, tolerance: 0))
    check("exact with 0 tolerance → true", framesMatch(a, a, tolerance: 0))
}

print("\n26. framesMatch — secondary screen negative Y")
do {
    let a = CGRect(x: 0, y: -1440, width: 2560, height: 1440)
    let b = CGRect(x: 0, y: -1440, width: 2560, height: 1440)
    check("secondary screen exact match", framesMatch(a, b))

    let shifted = CGRect(x: 0, y: -1435, width: 2560, height: 1440)
    check("5px shift on negative Y within 10px", framesMatch(shifted, a))
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
