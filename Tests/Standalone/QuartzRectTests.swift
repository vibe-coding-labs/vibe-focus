// Tests/Standalone/QuartzRectTests.swift
// Verification: QuartzRect geometry and CoordinateKit math functions
// Mirrors: Sources/Space/CoordinateKit.swift:61-91 (QuartzRect), 156-162 (coord conversion), 200-207 (framesMatch)
// Run: swift Tests/Standalone/QuartzRectTests.swift

import Foundation
import CoreGraphics

// MARK: - QuartzRect (mirrors CoordinateKit.swift:61-91)

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

// MARK: - framesMatch (mirrors CoordinateKit.swift:200-207)

func framesMatch(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 10, heightTolerance: CGFloat? = nil) -> Bool {
    let ht = heightTolerance ?? tolerance * 2
    let positionMatches = abs(a.origin.x - b.origin.x) <= tolerance &&
                         abs(a.origin.y - b.origin.y) <= tolerance
    let sizeMatches = abs(a.width - b.width) <= tolerance * 2 &&
                     abs(a.height - b.height) <= ht
    return positionMatches && sizeMatches
}

// MARK: - Coordinate conversion (mirrors CoordinateKit.swift:156-162)

func cocoaY(fromQuartzY quartzY: CGFloat, mainScreenHeight: CGFloat) -> CGFloat {
    mainScreenHeight - quartzY
}

func quartzY(fromCocoaY cocoaY: CGFloat, mainScreenHeight: CGFloat) -> CGFloat {
    mainScreenHeight - cocoaY
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

let mainScreenHeight: CGFloat = 1117

// MARK: - QuartzRect basics

print("1. QuartzRect init and properties")
do {
    let r = QuartzRect(x: 100, y: 200, width: 800, height: 600)
    checkEqual("x", r.x, 100.0)
    checkEqual("y", r.y, 200.0)
    checkEqual("width", r.width, 800.0)
    checkEqual("height", r.height, 600.0)
    checkEqual("midX", r.midX, 500.0)
    checkEqual("midY", r.midY, 500.0)
    checkEqual("maxX", r.maxX, 900.0)
    checkEqual("maxY", r.maxY, 800.0)
}

print("\n2. QuartzRect from CGRect")
do {
    let cg = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let r = QuartzRect(cg)
    checkEqual("cgRect roundtrip", r.cgRect, cg)
    checkEqual("midX of main screen", r.midX, 864.0)
    checkEqual("midY of main screen", r.midY, 558.5)
}

print("\n3. QuartzRect description")
do {
    let r = QuartzRect(x: 1480, y: -707, width: 1146, height: 707)
    checkEqual("description", r.description, "1480,-707 1146x707")
}

// MARK: - centerIsInside

print("\n4. QuartzRect.centerIsInside")
do {
    let mainScreen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    let onMain = QuartzRect(x: 500, y: 300, width: 800, height: 600)
    check("center on main screen", onMain.centerIsInside(mainScreen))

    let offScreen = QuartzRect(x: 1480, y: -710, width: 1145, height: 710)
    check("center off-screen (secondary above)", !offScreen.centerIsInside(mainScreen))

    let edgeCase = QuartzRect(x: 0, y: 0, width: 1, height: 1)
    check("1x1 at origin on main screen", edgeCase.centerIsInside(mainScreen))
}

// MARK: - framesMatch

print("\n5. framesMatch — exact match")
do {
    let a = CGRect(x: 100, y: 200, width: 800, height: 600)
    check("exact match", framesMatch(a, a))
}

print("\n6. framesMatch — within tolerance")
do {
    let a = CGRect(x: 100, y: 200, width: 800, height: 600)
    let b = CGRect(x: 105, y: 205, width: 815, height: 615)
    check("5px offset within 10px tolerance", framesMatch(a, b))
    check("reversed", framesMatch(b, a))
}

print("\n7. framesMatch — outside tolerance")
do {
    let a = CGRect(x: 100, y: 200, width: 800, height: 600)
    let b = CGRect(x: 115, y: 200, width: 800, height: 600)
    check("15px x-offset outside 10px tolerance", !framesMatch(a, b))
}

print("\n8. framesMatch — heightTolerance")
do {
    let a = CGRect(x: 100, y: 200, width: 800, height: 600)
    let b = CGRect(x: 100, y: 200, width: 800, height: 615)
    check("15px height diff within 20px heightTolerance", framesMatch(a, b))

    let c = CGRect(x: 100, y: 200, width: 800, height: 625)
    check("25px height diff outside 20px heightTolerance", !framesMatch(a, c))

    check("25px height within 30px custom heightTolerance", framesMatch(a, c, heightTolerance: 30))
}

// MARK: - Coordinate conversion symmetry

print("\n9. Coordinate conversion symmetry")
do {
    let testYValues: [CGFloat] = [0, 1117, 558.5, -720, 1500, -10000, 100000]
    for y in testYValues {
        let cocoa = cocoaY(fromQuartzY: y, mainScreenHeight: mainScreenHeight)
        let back = quartzY(fromCocoaY: cocoa, mainScreenHeight: mainScreenHeight)
        checkEqual("quartzY(\(y)) → cocoaY(\(cocoa)) → back", back, y)
    }
}

print("\n10. Coordinate conversion known values")
do {
    checkEqual("quartzY=0 → cocoaY=1117", cocoaY(fromQuartzY: 0, mainScreenHeight: mainScreenHeight), 1117.0)
    checkEqual("quartzY=1117 → cocoaY=0", cocoaY(fromQuartzY: 1117, mainScreenHeight: mainScreenHeight), 0.0)
    checkEqual("quartzY=-720 → cocoaY=1837", cocoaY(fromQuartzY: -720, mainScreenHeight: mainScreenHeight), 1837.0)
    checkEqual("cocoaY=0 → quartzY=1117", quartzY(fromCocoaY: 0, mainScreenHeight: mainScreenHeight), 1117.0)
    checkEqual("cocoaY=1117 → quartzY=0", quartzY(fromCocoaY: 1117, mainScreenHeight: mainScreenHeight), 0.0)
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
