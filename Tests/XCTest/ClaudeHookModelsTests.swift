import Testing
import Foundation
import CoreGraphics
@testable import VibeFocusKit

@Suite("ClaudeHook Models")
struct ClaudeHookModelsTests {

    @Test("Event type raw values")
    func eventTypeRawValues() {
        #expect(ClaudeHookEventType.allCases.count == 4)
        #expect(ClaudeHookEventType.sessionStart.rawValue == "SessionStart")
        #expect(ClaudeHookEventType.stop.rawValue == "Stop")
        #expect(ClaudeHookEventType.sessionEnd.rawValue == "SessionEnd")
        #expect(ClaudeHookEventType.userPromptSubmit.rawValue == "UserPromptSubmit")
    }

    @Test("WindowMoveReason raw values")
    func windowMoveReasonRawValues() {
        #expect(WindowMoveReason.manualHotkey.rawValue == "manual_hotkey")
        #expect(WindowMoveReason.claudeSessionEnd.rawValue == "claude_session_end")
    }

    @Test("WindowIdentity Codable roundtrip")
    func windowIdentityCodable() throws {
        let identity = WindowIdentity(
            windowID: 42,
            pid: 1234,
            bundleIdentifier: "com.test",
            appName: "TestApp",
            title: "Hello"
        )
        let data = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(WindowIdentity.self, from: data)
        #expect(decoded.windowID == 42)
        #expect(decoded.pid == 1234)
        #expect(decoded.bundleIdentifier == "com.test")
        #expect(decoded.appName == "TestApp")
        #expect(decoded.title == "Hello")
    }

    @Test("WindowState Codable roundtrip")
    func windowStateCodable() throws {
        var state = WindowState(
            windowID: 100,
            pid: 5678,
            tty: "/dev/ttys001",
            axWindowNumber: 200,
            appName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            title: "bash",
            termSessionID: nil,
            itermSessionID: nil,
            sessionID: "sess-123",
            isCompleted: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        state.cwd = "/Users/test/project"
        state.model = "opus"

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WindowState.self, from: data)
        #expect(decoded.windowID == 100)
        #expect(decoded.pid == 5678)
        #expect(decoded.sessionID == "sess-123")
        #expect(decoded.cwd == "/Users/test/project")
        #expect(decoded.model == "opus")
    }

    @Test("TerminalContext hasUsefulContext")
    func terminalContextUsefulContext() {
        let emptyCtx = TerminalContext(
            termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
            weztermPane: nil, tty: nil, ppid: nil,
            claudeProjectDir: nil, windowID: nil, machineLabel: nil
        )
        #expect(!emptyCtx.hasUsefulContext)

        let ttyCtx = TerminalContext(
            termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
            weztermPane: nil, tty: "/dev/ttys001", ppid: nil,
            claudeProjectDir: nil, windowID: nil, machineLabel: nil
        )
        #expect(ttyCtx.hasUsefulContext)

        let sessionCtx = TerminalContext(
            termSessionID: "sess-1", itermSessionID: nil, kittyWindowID: nil,
            weztermPane: nil, tty: nil, ppid: nil,
            claudeProjectDir: nil, windowID: nil, machineLabel: nil
        )
        #expect(sessionCtx.hasUsefulContext)
    }

    @Test("ClaudeHookPayload decoding")
    func payloadDecoding() throws {
        let json = """
        {"event":"SessionStart","session_id":"abc-123","cwd":"/tmp"}
        """
        let data = Data(json.utf8)
        let payload = try JSONDecoder().decode(ClaudeHookPayload.self, from: data)
        #expect(payload.event == .sessionStart)
        #expect(payload.sessionID == "abc-123")
        #expect(payload.cwd == "/tmp")
    }

    @Test("ClaudeHookResponse encoding")
    func responseEncoding() throws {
        let response = ClaudeHookResponse(
            ok: true,
            code: "window_focused",
            message: "Window moved",
            sessionID: "sess-1",
            handled: true
        )
        let data = try JSONEncoder().encode(response)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["ok"] as? Bool == true)
        #expect(json["code"] as? String == "window_focused")
        #expect(json["handled"] as? Bool == true)
    }

    @Test("ToggleRecord equality")
    func toggleRecordEquality() {
        let now = Date()
        let frame1 = CGRect(x: 0, y: -1440, width: 2560, height: 1440)
        let frame2 = CGRect(x: 0, y: 0, width: 1920, height: 1117)
        let a = ToggleRecord(
            windowID: 42, pid: 1234, bundleIdentifier: "com.test", appName: "App",
            origFrame: frame1, sourceSpace: 3, sourceDisplay: 2,
            sourceYabaiDisp: 2, sourceDispSpace: 1, targetFrame: frame2,
            targetDisplay: 1, toggledAt: now, sessionID: "sess-1"
        )
        let b = ToggleRecord(
            windowID: 42, pid: 1234, bundleIdentifier: "com.test", appName: "App",
            origFrame: frame1, sourceSpace: 3, sourceDisplay: 2,
            sourceYabaiDisp: 2, sourceDispSpace: 1, targetFrame: frame2,
            targetDisplay: 1, toggledAt: now, sessionID: "sess-1"
        )
        #expect(a == b)
    }
}
