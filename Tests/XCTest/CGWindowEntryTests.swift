import Testing
import Foundation
import CoreGraphics
@testable import VibeFocusKit

@Suite("CGWindowEntry")
struct CGWindowEntryTests {

    // MARK: - Complete dictionary parsing

    @Test("parses complete dictionary with all fields")
    func parseCompleteDictionary() throws {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(42),
            "kCGWindowOwnerPID": pid_t(1234),
            "kCGWindowOwnerName": "TestApp",
            "kCGWindowLayer": Int(0),
            "kCGWindowBounds": [
                "X": CGFloat(100),
                "Y": CGFloat(200),
                "Width": CGFloat(800),
                "Height": CGFloat(600)
            ],
            "kCGWindowName": "MainWindow",
            "kCGWindowIsOnscreen": true
        ]
        let entry = CGWindowEntry(from: dict)
        let e = try #require(entry)
        #expect(e.windowID == 42)
        #expect(e.ownerPID == 1234)
        #expect(e.ownerName == "TestApp")
        #expect(e.layer == 0)
        #expect(e.name == "MainWindow")
        #expect(e.isOnScreen == true)

        let bounds = try #require(e.bounds)
        #expect(bounds.origin.x == 100)
        #expect(bounds.origin.y == 200)
        #expect(bounds.width == 800)
        #expect(bounds.height == 600)
    }

    // MARK: - Missing required fields

    @Test("returns nil when kCGWindowNumber is missing")
    func missingWindowNumber() {
        let dict: [String: Any] = [
            "kCGWindowOwnerPID": pid_t(1234)
        ]
        let entry = CGWindowEntry(from: dict)
        #expect(entry == nil)
    }

    @Test("returns nil when kCGWindowOwnerPID is missing")
    func missingOwnerPID() {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(42)
        ]
        let entry = CGWindowEntry(from: dict)
        #expect(entry == nil)
    }

    @Test("returns nil when both required fields are missing")
    func missingBothRequired() {
        let dict: [String: Any] = [:]
        let entry = CGWindowEntry(from: dict)
        #expect(entry == nil)
    }

    // MARK: - Wrong types

    @Test("returns nil when kCGWindowNumber is wrong type (String)")
    func wrongTypeWindowNumber() {
        let dict: [String: Any] = [
            "kCGWindowNumber": "not-a-number",
            "kCGWindowOwnerPID": pid_t(1234)
        ]
        let entry = CGWindowEntry(from: dict)
        #expect(entry == nil)
    }

    @Test("returns nil when kCGWindowOwnerPID is wrong type (String)")
    func wrongTypeOwnerPID() {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(42),
            "kCGWindowOwnerPID": "not-a-pid"
        ]
        let entry = CGWindowEntry(from: dict)
        #expect(entry == nil)
    }

    // MARK: - Optional fields with defaults

    @Test("ownerName defaults to nil when missing")
    func ownerNameDefaultsNil() throws {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(1),
            "kCGWindowOwnerPID": pid_t(100)
        ]
        let entry = CGWindowEntry(from: dict)
        let e = try #require(entry)
        #expect(e.ownerName == nil)
    }

    @Test("layer defaults to 0 when missing")
    func layerDefaultsZero() throws {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(1),
            "kCGWindowOwnerPID": pid_t(100)
        ]
        let entry = CGWindowEntry(from: dict)
        let e = try #require(entry)
        #expect(e.layer == 0)
    }

    @Test("bounds defaults to nil when missing")
    func boundsDefaultsNil() throws {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(1),
            "kCGWindowOwnerPID": pid_t(100)
        ]
        let entry = CGWindowEntry(from: dict)
        let e = try #require(entry)
        #expect(e.bounds == nil)
    }

    @Test("name defaults to nil when missing")
    func nameDefaultsNil() throws {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(1),
            "kCGWindowOwnerPID": pid_t(100)
        ]
        let entry = CGWindowEntry(from: dict)
        let e = try #require(entry)
        #expect(e.name == nil)
    }

    @Test("isOnScreen defaults to true when missing")
    func isOnScreenDefaultsTrue() throws {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(1),
            "kCGWindowOwnerPID": pid_t(100)
        ]
        let entry = CGWindowEntry(from: dict)
        let e = try #require(entry)
        #expect(e.isOnScreen == true)
    }

    @Test("isOnScreen can be false")
    func isOnScreenFalse() throws {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(1),
            "kCGWindowOwnerPID": pid_t(100),
            "kCGWindowIsOnscreen": false
        ]
        let entry = CGWindowEntry(from: dict)
        let e = try #require(entry)
        #expect(e.isOnScreen == false)
    }

    // MARK: - Bounds parsing

    @Test("bounds with partial keys fills zeros for missing X and Y")
    func boundsPartialXY() throws {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(1),
            "kCGWindowOwnerPID": pid_t(100),
            "kCGWindowBounds": [
                "Width": CGFloat(500),
                "Height": CGFloat(400)
            ] as [String: CGFloat]
        ]
        let entry = CGWindowEntry(from: dict)
        let e = try #require(entry)
        let bounds = try #require(e.bounds)
        #expect(bounds.origin.x == 0)
        #expect(bounds.origin.y == 0)
        #expect(bounds.width == 500)
        #expect(bounds.height == 400)
    }

    @Test("bounds with all zero values")
    func boundsAllZeros() throws {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(1),
            "kCGWindowOwnerPID": pid_t(100),
            "kCGWindowBounds": [
                "X": CGFloat(0),
                "Y": CGFloat(0),
                "Width": CGFloat(0),
                "Height": CGFloat(0)
            ] as [String: CGFloat]
        ]
        let entry = CGWindowEntry(from: dict)
        let e = try #require(entry)
        let bounds = try #require(e.bounds)
        #expect(bounds == .zero)
    }

    @Test("bounds with wrong type falls back to nil")
    func boundsWrongType() throws {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(1),
            "kCGWindowOwnerPID": pid_t(100),
            "kCGWindowBounds": "not-a-dict"
        ]
        let entry = CGWindowEntry(from: dict)
        let e = try #require(entry)
        #expect(e.bounds == nil)
    }

    // MARK: - Name parsing (tries both kCGWindowName and "name")

    @Test("name reads from kCGWindowName key")
    func nameFromCGKey() throws {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(1),
            "kCGWindowOwnerPID": pid_t(100),
            "kCGWindowName": "CGName"
        ]
        let entry = CGWindowEntry(from: dict)
        let e = try #require(entry)
        #expect(e.name == "CGName")
    }

    @Test("name reads from 'name' key as fallback")
    func nameFromPlainKey() throws {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(1),
            "kCGWindowOwnerPID": pid_t(100),
            "name": "PlainName"
        ]
        let entry = CGWindowEntry(from: dict)
        let e = try #require(entry)
        #expect(e.name == "PlainName")
    }

    @Test("name prefers kCGWindowName over 'name' key")
    func nameCGKeyPreferred() throws {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(1),
            "kCGWindowOwnerPID": pid_t(100),
            "kCGWindowName": "CGName",
            "name": "PlainName"
        ]
        let entry = CGWindowEntry(from: dict)
        let e = try #require(entry)
        #expect(e.name == "CGName")
    }

    // MARK: - Layer parsing

    @Test("layer can be non-zero")
    func layerNonZero() throws {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(1),
            "kCGWindowOwnerPID": pid_t(100),
            "kCGWindowLayer": Int(24)
        ]
        let entry = CGWindowEntry(from: dict)
        let e = try #require(entry)
        #expect(e.layer == 24)
    }

    // MARK: - Minimal valid dictionary

    @Test("minimal valid dictionary with only required fields")
    func minimalValid() throws {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(999),
            "kCGWindowOwnerPID": pid_t(5678)
        ]
        let entry = CGWindowEntry(from: dict)
        let e = try #require(entry)
        #expect(e.windowID == 999)
        #expect(e.ownerPID == 5678)
        #expect(e.ownerName == nil)
        #expect(e.layer == 0)
        #expect(e.name == nil)
        #expect(e.isOnScreen == true)
        #expect(e.bounds == nil)
    }

    @Test("large windowID value")
    func largeWindowID() throws {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(UInt32.max),
            "kCGWindowOwnerPID": pid_t(1)
        ]
        let entry = CGWindowEntry(from: dict)
        let e = try #require(entry)
        #expect(e.windowID == UInt32.max)
    }
}
