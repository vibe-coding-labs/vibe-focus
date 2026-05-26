import Testing
import Foundation
import CoreGraphics
@testable import VibeFocusKit

@Suite("CoordinateKit Types")
@MainActor
struct CoordinateKitTests {

    // MARK: - DisplayIdentifier

    @Test("DisplayIdentifier yabaiIndex equality")
    func displayIdentifierYabaiEquality() {
        let a = DisplayIdentifier.yabaiIndex(1)
        let b = DisplayIdentifier.yabaiIndex(1)
        let c = DisplayIdentifier.yabaiIndex(2)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("DisplayIdentifier different variants are not equal")
    func displayIdentifierVariantInequality() {
        let yabai = DisplayIdentifier.yabaiIndex(1)
        let screen = DisplayIdentifier.screenArrayIndex(0)
        let cg = DisplayIdentifier.cgDirectDisplayID(1)
        #expect(yabai != screen)
        #expect(yabai != cg)
        #expect(screen != cg)
    }

    @Test("DisplayIdentifier description for yabaiIndex")
    func displayIdentifierYabaiDescription() {
        let id = DisplayIdentifier.yabaiIndex(3)
        #expect(id.description == "yabai(3)")
    }

    @Test("DisplayIdentifier description for screenArrayIndex")
    func displayIdentifierScreenDescription() {
        let id = DisplayIdentifier.screenArrayIndex(0)
        #expect(id.description == "screen[0]")
    }

    @Test("DisplayIdentifier description for cgDirectDisplayID")
    func displayIdentifierCGDescription() {
        let id = DisplayIdentifier.cgDirectDisplayID(12345)
        #expect(id.description == "cgDisplay(12345)")
    }

    @Test("DisplayIdentifier yabaiIndex accessor returns value for yabaiIndex")
    func displayIdentifierYabaiAccessor() {
        let id = DisplayIdentifier.yabaiIndex(5)
        #expect(id.yabaiIndex == 5)
    }

    @Test("DisplayIdentifier yabaiIndex accessor returns nil for non-yabai variants")
    func displayIdentifierYabaiAccessorNil() {
        let screen = DisplayIdentifier.screenArrayIndex(0)
        #expect(screen.yabaiIndex == nil)

        let cg = DisplayIdentifier.cgDirectDisplayID(99)
        #expect(cg.yabaiIndex == nil)
    }

    @Test("DisplayIdentifier convenience constructors")
    func displayIdentifierConvenience() {
        let yabai = DisplayIdentifier.yabai(1)
        #expect(yabai == DisplayIdentifier.yabaiIndex(1))

        let screen = DisplayIdentifier.screenArray(2)
        #expect(screen == DisplayIdentifier.screenArrayIndex(2))

        let cg = DisplayIdentifier.cgDisplay(42)
        #expect(cg == DisplayIdentifier.cgDirectDisplayID(42))
    }

    // MARK: - SpaceIdentifier

    @Test("SpaceIdentifier yabaiIndex equality")
    func spaceIdentifierYabaiEquality() {
        let a = SpaceIdentifier.yabaiIndex(1)
        let b = SpaceIdentifier.yabaiIndex(1)
        let c = SpaceIdentifier.yabaiIndex(2)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("SpaceIdentifier different variants are not equal")
    func spaceIdentifierVariantInequality() {
        let yabai = SpaceIdentifier.yabaiIndex(1)
        let native = SpaceIdentifier.nativeID(100)
        #expect(yabai != native)
    }

    @Test("SpaceIdentifier description for yabaiIndex")
    func spaceIdentifierYabaiDescription() {
        let id = SpaceIdentifier.yabaiIndex(3)
        #expect(id.description == "yabai_space(3)")
    }

    @Test("SpaceIdentifier description for nativeID")
    func spaceIdentifierNativeDescription() {
        let id = SpaceIdentifier.nativeID(12345)
        #expect(id.description == "native_space(12345)")
    }

    @Test("SpaceIdentifier yabaiIndex accessor returns value for yabaiIndex")
    func spaceIdentifierYabaiAccessor() {
        let id = SpaceIdentifier.yabaiIndex(5)
        #expect(id.yabaiIndex == 5)
    }

    @Test("SpaceIdentifier yabaiIndex accessor returns nil for nativeID")
    func spaceIdentifierYabaiAccessorNil() {
        let native = SpaceIdentifier.nativeID(100)
        #expect(native.yabaiIndex == nil)
    }

    @Test("SpaceIdentifier convenience constructors")
    func spaceIdentifierConvenience() {
        let yabai = SpaceIdentifier.yabai(3)
        #expect(yabai == SpaceIdentifier.yabaiIndex(3))

        let native = SpaceIdentifier.native(999)
        #expect(native == SpaceIdentifier.nativeID(999))
    }

    // MARK: - QuartzRect

    @Test("QuartzRect computed properties: midX, midY, maxX, maxY")
    func quartzRectComputedProperties() {
        let rect = QuartzRect(x: 100, y: 200, width: 800, height: 600)
        #expect(rect.x == 100)
        #expect(rect.y == 200)
        #expect(rect.width == 800)
        #expect(rect.height == 600)
        #expect(rect.midX == 500)
        #expect(rect.midY == 500)
        #expect(rect.maxX == 900)
        #expect(rect.maxY == 800)
    }

    @Test("QuartzRect with zero origin")
    func quartzRectZeroOrigin() {
        let rect = QuartzRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(rect.midX == 960)
        #expect(rect.midY == 540)
        #expect(rect.maxX == 1920)
        #expect(rect.maxY == 1080)
    }

    @Test("QuartzRect CGRect conversion")
    func quartzRectToCGRect() {
        let qr = QuartzRect(x: 10, y: 20, width: 300, height: 400)
        let cg = qr.cgRect
        #expect(cg.origin.x == 10)
        #expect(cg.origin.y == 20)
        #expect(cg.width == 300)
        #expect(cg.height == 400)
    }

    @Test("QuartzRect init from CGRect")
    func quartzRectFromCGRect() {
        let cg = CGRect(x: 50, y: 60, width: 700, height: 500)
        let qr = QuartzRect(cg)
        #expect(qr.x == 50)
        #expect(qr.y == 60)
        #expect(qr.width == 700)
        #expect(qr.height == 500)
    }

    @Test("QuartzRect equality")
    func quartzRectEquality() {
        let a = QuartzRect(x: 1, y: 2, width: 3, height: 4)
        let b = QuartzRect(CGRect(x: 1, y: 2, width: 3, height: 4))
        #expect(a == b)
    }

    @Test("QuartzRect inequality")
    func quartzRectInequality() {
        let a = QuartzRect(x: 1, y: 2, width: 3, height: 4)
        let b = QuartzRect(x: 1, y: 2, width: 3, height: 5)
        #expect(a != b)
    }

    @Test("QuartzRect description format")
    func quartzRectDescription() {
        let rect = QuartzRect(x: 100.7, y: 200.3, width: 800.9, height: 600.1)
        // description uses Int() conversion
        #expect(rect.description == "100,200 800x600")
    }

    @Test("QuartzRect centerIsInside returns true when center is within screen")
    func quartzRectCenterInsideTrue() {
        let window = QuartzRect(x: 100, y: 100, width: 800, height: 600)
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(window.centerIsInside(screen))
    }

    @Test("QuartzRect centerIsInside returns false when center is outside screen")
    func quartzRectCenterInsideFalse() {
        let window = QuartzRect(x: 2000, y: 100, width: 800, height: 600)
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(!window.centerIsInside(screen))
    }

    @Test("QuartzRect centerIsInside boundary: center exactly on edge")
    func quartzRectCenterInsideBoundary() {
        // midX = 1920, midY = 540 — exactly on right edge of screen
        let window = QuartzRect(x: 1520, y: 0, width: 800, height: 1080)
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // CGRect.contains excludes max edge
        #expect(!window.centerIsInside(screen))
    }

    // MARK: - framesMatch (mirrored from CoordinateKit)

    @Test("framesMatch returns true for identical frames")
    func framesMatchIdentical() {
        let a = CGRect(x: 100, y: 200, width: 800, height: 600)
        let b = CGRect(x: 100, y: 200, width: 800, height: 600)
        #expect(CoordinateKit.framesMatch(a, b))
    }

    @Test("framesMatch returns true within default tolerance (10)")
    func framesMatchWithinTolerance() {
        let a = CGRect(x: 100, y: 200, width: 800, height: 600)
        let b = CGRect(x: 105, y: 205, width: 815, height: 615)
        // position delta = 5 <= 10, width delta = 15 <= 20, height delta = 15 <= 20
        #expect(CoordinateKit.framesMatch(a, b))
    }

    @Test("framesMatch returns false when position exceeds tolerance")
    func framesMatchPositionExceeds() {
        let a = CGRect(x: 100, y: 200, width: 800, height: 600)
        let b = CGRect(x: 120, y: 200, width: 800, height: 600)
        // position delta = 20 > 10
        #expect(!CoordinateKit.framesMatch(a, b))
    }

    @Test("framesMatch size tolerance is 2x position tolerance")
    func framesMatchSizeToleranceDouble() {
        let a = CGRect(x: 100, y: 200, width: 800, height: 600)
        let b = CGRect(x: 100, y: 200, width: 820, height: 600)
        // width delta = 20, position tolerance = 10, size tolerance = 20 -> matches
        #expect(CoordinateKit.framesMatch(a, b))

        let c = CGRect(x: 100, y: 200, width: 821, height: 600)
        // width delta = 21 > 20 -> no match
        #expect(!CoordinateKit.framesMatch(a, c))
    }

    @Test("framesMatch height uses custom heightTolerance when provided")
    func framesMatchCustomHeightTolerance() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 0, y: 0, width: 100, height: 125)
        // Default: heightTolerance = tolerance * 2 = 20, delta = 25 > 20 -> no match
        #expect(!CoordinateKit.framesMatch(a, b))

        // With heightTolerance = 30 -> delta = 25 <= 30 -> matches
        #expect(CoordinateKit.framesMatch(a, b, heightTolerance: 30))
    }

    @Test("framesMatch with custom tolerance")
    func framesMatchCustomTolerance() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 45, y: 0, width: 100, height: 100)
        // tolerance = 50, position delta = 45 <= 50 -> matches
        #expect(CoordinateKit.framesMatch(a, b, tolerance: 50))

        let c = CGRect(x: 55, y: 0, width: 100, height: 100)
        // position delta = 55 > 50 -> no match
        #expect(!CoordinateKit.framesMatch(a, c, tolerance: 50))
    }

    @Test("framesMatch zero tolerance requires exact match")
    func framesMatchZeroTolerance() {
        let a = CGRect(x: 100, y: 200, width: 800, height: 600)
        let b = CGRect(x: 100, y: 200, width: 800, height: 600)
        #expect(CoordinateKit.framesMatch(a, b, tolerance: 0))

        let c = CGRect(x: 100, y: 201, width: 800, height: 600)
        #expect(!CoordinateKit.framesMatch(a, c, tolerance: 0))
    }

    @Test("framesMatch with large tolerance accepts large differences")
    func framesMatchLargeTolerance() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 500, y: 500, width: 1100, height: 1100)
        #expect(CoordinateKit.framesMatch(a, b, tolerance: 1000))
    }
}
