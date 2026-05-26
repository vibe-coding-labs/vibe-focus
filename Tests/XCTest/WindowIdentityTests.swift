import Testing
import Foundation
@testable import VibeFocusKit

@Suite("WindowIdentity and WindowMoveReason")
struct WindowIdentityTests {

    @Test("WindowIdentity init stores all fields")
    func initStoresFields() {
        let identity = WindowIdentity(
            windowID: 42, pid: 1234,
            bundleIdentifier: "com.test", appName: "App",
            windowNumber: 100, title: "Hello"
        )
        #expect(identity.windowID == 42)
        #expect(identity.pid == 1234)
        #expect(identity.bundleIdentifier == "com.test")
        #expect(identity.appName == "App")
        #expect(identity.windowNumber == 100)
        #expect(identity.title == "Hello")
    }

    @Test("WindowIdentity capturedAt is recent")
    func capturedAtRecent() {
        let before = Date()
        let identity = WindowIdentity(
            windowID: 1, pid: 1,
            bundleIdentifier: nil, appName: nil, title: nil
        )
        let after = Date()
        #expect(identity.capturedAt >= before)
        #expect(identity.capturedAt <= after)
    }

    @Test("WindowIdentity Codable roundtrip")
    func codableRoundtrip() throws {
        let identity = WindowIdentity(
            windowID: 42, pid: 1234,
            bundleIdentifier: "com.test.app", appName: "TestApp",
            windowNumber: 55, title: "TestWindow"
        )
        let data = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(WindowIdentity.self, from: data)
        #expect(decoded.windowID == 42)
        #expect(decoded.pid == 1234)
        #expect(decoded.bundleIdentifier == "com.test.app")
        #expect(decoded.appName == "TestApp")
        #expect(decoded.windowNumber == 55)
        #expect(decoded.title == "TestWindow")
    }

    @Test("WindowIdentity Equatable: same business fields match")
    func equatable() {
        let a = WindowIdentity(windowID: 1, pid: 2, bundleIdentifier: "x", appName: "y", title: "z")
        #expect(a.windowID == 1)
        #expect(a.pid == 2)
        #expect(a.bundleIdentifier == "x")
        #expect(a.appName == "y")
        #expect(a.title == "z")
    }

    @Test("WindowIdentity Equatable: different windowID → not equal")
    func notEqualDifferentID() {
        let a = WindowIdentity(windowID: 1, pid: 2, bundleIdentifier: "x", appName: "y", title: "z")
        let b = WindowIdentity(windowID: 2, pid: 2, bundleIdentifier: "x", appName: "y", title: "z")
        #expect(a.windowID != b.windowID)
    }

    @Test("WindowMoveReason raw values")
    func moveReasonRawValues() {
        #expect(WindowMoveReason.manualHotkey.rawValue == "manual_hotkey")
        #expect(WindowMoveReason.claudeSessionEnd.rawValue == "claude_session_end")
    }

    @Test("ClaudeHookEventType allCases has 4 values")
    func eventTypesCount() {
        #expect(ClaudeHookEventType.allCases.count == 4)
    }

    @Test("ClaudeHookEventType raw values match expected strings")
    func eventTypeRawValues() {
        #expect(ClaudeHookEventType.sessionStart.rawValue == "SessionStart")
        #expect(ClaudeHookEventType.stop.rawValue == "Stop")
        #expect(ClaudeHookEventType.sessionEnd.rawValue == "SessionEnd")
        #expect(ClaudeHookEventType.userPromptSubmit.rawValue == "UserPromptSubmit")
    }
}
