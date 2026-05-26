import Testing
import Foundation
@testable import VibeFocusKit

@Suite("ToggleRecord and ClaudeHookResponse")
struct ToggleRecordCodableTests {

    // MARK: - ToggleRecord field correctness

    @Test("ToggleRecord: stores all fields correctly")
    func toggleRecordFields() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let record = ToggleRecord(
            windowID: 42,
            pid: 1234,
            bundleIdentifier: "com.apple.Terminal",
            appName: "Terminal",
            origFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            sourceSpace: 3,
            sourceDisplay: 2,
            sourceYabaiDisp: 2,
            sourceDispSpace: 1,
            targetFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            targetDisplay: 1,
            toggledAt: date,
            sessionID: "sess-abc-123"
        )
        #expect(record.windowID == 42)
        #expect(record.pid == 1234)
        #expect(record.bundleIdentifier == "com.apple.Terminal")
        #expect(record.appName == "Terminal")
        #expect(record.origFrame == CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        #expect(record.sourceSpace == 3)
        #expect(record.sourceDisplay == 2)
        #expect(record.sourceYabaiDisp == 2)
        #expect(record.sourceDispSpace == 1)
        #expect(record.targetFrame == CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(record.targetDisplay == 1)
        #expect(record.toggledAt == date)
        #expect(record.sessionID == "sess-abc-123")
    }

    @Test("ToggleRecord: Equatable same values")
    func toggleRecordEquatableSame() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let a = ToggleRecord(
            windowID: 1, pid: 100, bundleIdentifier: nil, appName: nil,
            origFrame: .zero, sourceSpace: 1, sourceDisplay: 1,
            sourceYabaiDisp: 1, sourceDispSpace: 1,
            targetFrame: .zero, targetDisplay: 1,
            toggledAt: date, sessionID: nil
        )
        let b = ToggleRecord(
            windowID: 1, pid: 100, bundleIdentifier: nil, appName: nil,
            origFrame: .zero, sourceSpace: 1, sourceDisplay: 1,
            sourceYabaiDisp: 1, sourceDispSpace: 1,
            targetFrame: .zero, targetDisplay: 1,
            toggledAt: date, sessionID: nil
        )
        #expect(a == b)
    }

    @Test("ToggleRecord: Equatable different windowID")
    func toggleRecordEquatableDifferent() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let a = ToggleRecord(
            windowID: 1, pid: 100, bundleIdentifier: nil, appName: nil,
            origFrame: .zero, sourceSpace: 1, sourceDisplay: 1,
            sourceYabaiDisp: 1, sourceDispSpace: 1,
            targetFrame: .zero, targetDisplay: 1,
            toggledAt: date, sessionID: nil
        )
        let b = ToggleRecord(
            windowID: 2, pid: 100, bundleIdentifier: nil, appName: nil,
            origFrame: .zero, sourceSpace: 1, sourceDisplay: 1,
            sourceYabaiDisp: 1, sourceDispSpace: 1,
            targetFrame: .zero, targetDisplay: 1,
            toggledAt: date, sessionID: nil
        )
        #expect(a != b)
    }

    @Test("ToggleRecord: nil optional fields")
    func toggleRecordNilOptionals() {
        let record = ToggleRecord(
            windowID: 99, pid: 50, bundleIdentifier: nil, appName: nil,
            origFrame: CGRect(x: 100, y: 200, width: 300, height: 400),
            sourceSpace: 1, sourceDisplay: 1,
            sourceYabaiDisp: 1, sourceDispSpace: 1,
            targetFrame: CGRect(x: 500, y: 600, width: 700, height: 800),
            targetDisplay: 1,
            toggledAt: Date(timeIntervalSince1970: 0),
            sessionID: nil
        )
        #expect(record.bundleIdentifier == nil)
        #expect(record.appName == nil)
        #expect(record.sessionID == nil)
    }

    @Test("ToggleRecord: Equatable differs by sourceSpace")
    func toggleRecordDiffSourceSpace() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let a = ToggleRecord(
            windowID: 1, pid: 100, bundleIdentifier: nil, appName: nil,
            origFrame: .zero, sourceSpace: 1, sourceDisplay: 1,
            sourceYabaiDisp: 1, sourceDispSpace: 1,
            targetFrame: .zero, targetDisplay: 1,
            toggledAt: date, sessionID: nil
        )
        let b = ToggleRecord(
            windowID: 1, pid: 100, bundleIdentifier: nil, appName: nil,
            origFrame: .zero, sourceSpace: 2, sourceDisplay: 1,
            sourceYabaiDisp: 1, sourceDispSpace: 1,
            targetFrame: .zero, targetDisplay: 1,
            toggledAt: date, sessionID: nil
        )
        #expect(a != b)
    }

    // MARK: - ClaudeHookResponse encoding

    @Test("ClaudeHookResponse: encodes all fields correctly")
    func responseEncoding() throws {
        let response = ClaudeHookResponse(
            ok: true,
            code: "session_bound",
            message: "Session bound to window",
            sessionID: "sess-123",
            handled: true
        )
        let data = try JSONEncoder().encode(response)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["ok"] as? Bool == true)
        #expect(json?["code"] as? String == "session_bound")
        #expect(json?["message"] as? String == "Session bound to window")
        #expect(json?["session_id"] as? String == "sess-123")
        #expect(json?["handled"] as? Bool == true)
    }

    @Test("ClaudeHookResponse: encodes with nil sessionID")
    func responseNilSessionID() throws {
        let response = ClaudeHookResponse(
            ok: false,
            code: "error",
            message: "Something failed",
            sessionID: nil,
            handled: false
        )
        let data = try JSONEncoder().encode(response)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["ok"] as? Bool == false)
        #expect(json?["handled"] as? Bool == false)
        #expect(json?["session_id"] == nil)
    }

    @Test("ClaudeHookResponse: uses snake_case session_id key")
    func responseSnakeCaseKey() throws {
        let response = ClaudeHookResponse(
            ok: true, code: "test", message: "msg",
            sessionID: "abc", handled: true
        )
        let data = try JSONEncoder().encode(response)
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        #expect(jsonString.contains("session_id"))
        #expect(!jsonString.contains("sessionID"))
    }
}
