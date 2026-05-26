import Testing
import Foundation
@testable import VibeFocusKit

@Suite("CoordinateKit FramesMatch")
@MainActor
struct FramesMatchTests {

    // MARK: - framesMatch: identical frames

    @Test("framesMatch: identical frames → true")
    func identicalFrames() {
        let frame = CGRect(x: 100, y: 200, width: 800, height: 600)
        #expect(CoordinateKit.framesMatch(frame, frame))
    }

    @Test("framesMatch: zero frames → true")
    func zeroFrames() {
        #expect(CoordinateKit.framesMatch(.zero, .zero))
    }

    // MARK: - framesMatch: within tolerance

    @Test("framesMatch: within default tolerance (10pt) → true")
    func withinTolerance() {
        let a = CGRect(x: 100, y: 200, width: 800, height: 600)
        let b = CGRect(x: 105, y: 195, width: 805, height: 615)
        #expect(CoordinateKit.framesMatch(a, b))
    }

    @Test("framesMatch: at exact tolerance boundary → true")
    func exactTolerance() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 10, y: 10, width: 120, height: 120)
        #expect(CoordinateKit.framesMatch(a, b))
    }

    // MARK: - framesMatch: outside tolerance

    @Test("framesMatch: position exceeds tolerance → false")
    func positionExceeds() {
        let a = CGRect(x: 0, y: 0, width: 800, height: 600)
        let b = CGRect(x: 15, y: 0, width: 800, height: 600)
        #expect(!CoordinateKit.framesMatch(a, b))
    }

    @Test("framesMatch: width exceeds size tolerance → false")
    func widthExceeds() {
        let a = CGRect(x: 0, y: 0, width: 800, height: 600)
        let b = CGRect(x: 0, y: 0, width: 825, height: 600)
        #expect(!CoordinateKit.framesMatch(a, b))
    }

    @Test("framesMatch: height exceeds default height tolerance (2x) → false")
    func heightExceeds() {
        let a = CGRect(x: 0, y: 0, width: 800, height: 600)
        let b = CGRect(x: 0, y: 0, width: 800, height: 625)
        #expect(!CoordinateKit.framesMatch(a, b))
    }

    // MARK: - framesMatch: custom tolerance

    @Test("framesMatch: custom larger tolerance")
    func customTolerance() {
        let a = CGRect(x: 0, y: 0, width: 800, height: 600)
        let b = CGRect(x: 20, y: 20, width: 840, height: 640)
        #expect(CoordinateKit.framesMatch(a, b, tolerance: 25))
    }

    @Test("framesMatch: custom height tolerance")
    func customHeightTolerance() {
        let a = CGRect(x: 0, y: 0, width: 800, height: 600)
        let b = CGRect(x: 0, y: 0, width: 800, height: 630)
        // Default height tolerance = 20, 30 > 20 → false
        #expect(!CoordinateKit.framesMatch(a, b))
        // Custom height tolerance = 40, 30 < 40 → true
        #expect(CoordinateKit.framesMatch(a, b, tolerance: 10, heightTolerance: 40))
    }

    @Test("framesMatch: zero tolerance requires exact match")
    func zeroTolerance() {
        let a = CGRect(x: 0, y: 0, width: 800, height: 600)
        let b = CGRect(x: 0.001, y: 0, width: 800, height: 600)
        #expect(!CoordinateKit.framesMatch(a, b, tolerance: 0))
    }

    // MARK: - framesMatch: negative coordinates (secondary screen)

    @Test("framesMatch: negative coordinates work correctly")
    func negativeCoords() {
        let a = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let b = CGRect(x: -1915, y: 5, width: 1915, height: 1075)
        #expect(CoordinateKit.framesMatch(a, b, tolerance: 10))
    }
}
