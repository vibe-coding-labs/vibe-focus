import Testing
import Foundation
@testable import VibeFocusKit

@Suite("iTerm Session ID Parsing")
@MainActor
struct ItermSessionParsingTests {

    @Test("parseItermSessionUUID: standard format w0t0p0:{UUID}")
    func standardFormat() {
        let result = WindowManager.parseItermSessionUUID("w0t0p0:ABCDEF-1234")
        #expect(result == "ABCDEF-1234")
    }

    @Test("parseItermSessionUUID: no colon → returns full string")
    func noColon() {
        let result = WindowManager.parseItermSessionUUID("ABCDEF-1234")
        #expect(result == "ABCDEF-1234")
    }

    @Test("parseItermSessionUUID: empty string → nil")
    func emptyString() {
        let result = WindowManager.parseItermSessionUUID("")
        #expect(result == nil)
    }

    @Test("parseItermSessionUUID: colon at end → nil (empty after colon)")
    func colonAtEnd() {
        let result = WindowManager.parseItermSessionUUID("w0t0p0:")
        #expect(result == nil)
    }

    @Test("parseItermSessionUUID: multiple colons → uses first colon")
    func multipleColons() {
        let result = WindowManager.parseItermSessionUUID("w0t0p0:UUID:extra")
        #expect(result == "UUID:extra")
    }

    @Test("parseItermSessionUUID: complex window/tab/pane format")
    func complexFormat() {
        let result = WindowManager.parseItermSessionUUID("w2t1p3:550e8400-e29b-41d4-a716-446655440000")
        #expect(result == "550e8400-e29b-41d4-a716-446655440000")
    }
}
