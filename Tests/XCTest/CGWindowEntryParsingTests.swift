import Testing
import Foundation
import CoreGraphics
@testable import VibeFocusKit

@Suite("CGWindowEntry Parsing")
struct CGWindowEntryParsingTests {

    private func parse(_ dict: [String: Any]) throws -> CGWindowEntry {
        guard let entry = CGWindowEntry(from: dict) else {
            throw TestError("CGWindowEntry init returned nil")
        }
        return entry
    }

    private struct TestError: Error { let message: String; init(_ m: String) { message = m } }

    @Test("CGWindowEntry: parses valid full dict")
    func fullDict() throws {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(42),
            "kCGWindowOwnerPID": pid_t(1234),
            "kCGWindowOwnerName": "Terminal",
            "kCGWindowLayer": 0,
            "kCGWindowIsOnscreen": true,
            "kCGWindowName": "My Window"
        ]
        let entry = try parse(dict)
        #expect(entry.windowID == 42)
        #expect(entry.ownerPID == 1234)
        #expect(entry.ownerName == "Terminal")
        #expect(entry.layer == 0)
        #expect(entry.isOnScreen == true)
        #expect(entry.name == "My Window")
    }

    @Test("CGWindowEntry: returns nil when windowID missing")
    func missingWindowID() {
        let dict: [String: Any] = [
            "kCGWindowOwnerPID": pid_t(1234)
        ]
        #expect(CGWindowEntry(from: dict) == nil)
    }

    @Test("CGWindowEntry: returns nil when ownerPID missing")
    func missingOwnerPID() {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(42)
        ]
        #expect(CGWindowEntry(from: dict) == nil)
    }

    @Test("CGWindowEntry: parses bounds dict")
    func parsesBounds() throws {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(1),
            "kCGWindowOwnerPID": pid_t(100),
            "kCGWindowBounds": ["X": CGFloat(10), "Y": CGFloat(20), "Width": CGFloat(800), "Height": CGFloat(600)]
        ]
        let entry = try parse(dict)
        let bounds = try #require(entry.bounds)
        #expect(bounds.origin.x == 10)
        #expect(bounds.origin.y == 20)
        #expect(bounds.width == 800)
        #expect(bounds.height == 600)
    }

    @Test("CGWindowEntry: nil bounds when not provided")
    func noBounds() throws {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(1),
            "kCGWindowOwnerPID": pid_t(100)
        ]
        let entry = try parse(dict)
        #expect(entry.bounds == nil)
    }

    @Test("CGWindowEntry: defaults layer to 0 when missing")
    func defaultLayer() throws {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(1),
            "kCGWindowOwnerPID": pid_t(100)
        ]
        let entry = try parse(dict)
        #expect(entry.layer == 0)
    }

    @Test("CGWindowEntry: defaults isOnScreen to true when missing")
    func defaultOnScreen() throws {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(1),
            "kCGWindowOwnerPID": pid_t(100)
        ]
        let entry = try parse(dict)
        #expect(entry.isOnScreen == true)
    }

    @Test("CGWindowEntry: ownerName is nil when missing")
    func ownerNameNil() throws {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(1),
            "kCGWindowOwnerPID": pid_t(100)
        ]
        let entry = try parse(dict)
        #expect(entry.ownerName == nil)
    }

    @Test("CGWindowEntry: parses name from 'name' key fallback")
    func nameFromFallbackKey() throws {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(1),
            "kCGWindowOwnerPID": pid_t(100),
            "name": "Fallback Name"
        ]
        let entry = try parse(dict)
        #expect(entry.name == "Fallback Name")
    }

    @Test("CGWindowEntry: bounds with partial keys defaults to 0")
    func boundsPartial() throws {
        let dict: [String: Any] = [
            "kCGWindowNumber": UInt32(1),
            "kCGWindowOwnerPID": pid_t(100),
            "kCGWindowBounds": ["Width": CGFloat(100)]
        ]
        let entry = try parse(dict)
        let bounds = try #require(entry.bounds)
        #expect(bounds.origin.x == 0)
        #expect(bounds.origin.y == 0)
        #expect(bounds.width == 100)
        #expect(bounds.height == 0)
    }
}
