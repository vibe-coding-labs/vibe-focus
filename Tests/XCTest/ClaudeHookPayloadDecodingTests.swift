import Testing
import Foundation
@testable import VibeFocusKit

@Suite("ClaudeHookPayload Decoding")
struct ClaudeHookPayloadDecodingTests {

    // MARK: - Dual event key support

    @Test("decodes from 'event' key")
    func decodeFromEventKey() throws {
        let json = """
        {"event": "SessionStart", "session_id": "sess-1"}
        """
        let payload = try JSONDecoder().decode(ClaudeHookPayload.self, from: Data(json.utf8))
        #expect(payload.event == .sessionStart)
        #expect(payload.sessionID == "sess-1")
    }

    @Test("decodes from 'hook_event_name' key")
    func decodeFromHookEventName() throws {
        let json = """
        {"hook_event_name": "Stop", "session_id": "sess-2"}
        """
        let payload = try JSONDecoder().decode(ClaudeHookPayload.self, from: Data(json.utf8))
        #expect(payload.event == .stop)
        #expect(payload.sessionID == "sess-2")
    }

    @Test("prefers 'event' over 'hook_event_name' when both present")
    func eventKeyPriority() throws {
        let json = """
        {"event": "SessionEnd", "hook_event_name": "UserPromptSubmit", "session_id": "sess-3"}
        """
        let payload = try JSONDecoder().decode(ClaudeHookPayload.self, from: Data(json.utf8))
        #expect(payload.event == .sessionEnd)
    }

    // MARK: - Session ID handling

    @Test("session_id with 'session_id' key")
    func sessionIDSnakeCase() throws {
        let json = """
        {"event": "SessionStart", "session_id": "abc-123"}
        """
        let payload = try JSONDecoder().decode(ClaudeHookPayload.self, from: Data(json.utf8))
        #expect(payload.sessionID == "abc-123")
    }

    @Test("session_id with 'sessionId' camelCase key")
    func sessionIDCamelCase() throws {
        let json = """
        {"event": "SessionStart", "sessionId": "xyz-456"}
        """
        let payload = try JSONDecoder().decode(ClaudeHookPayload.self, from: Data(json.utf8))
        #expect(payload.sessionID == "xyz-456")
    }

    @Test("session_id trimmed of whitespace")
    func sessionIDTrimmed() throws {
        let json = """
        {"event": "SessionStart", "session_id": "  trimmed  "}
        """
        let payload = try JSONDecoder().decode(ClaudeHookPayload.self, from: Data(json.utf8))
        #expect(payload.sessionID == "trimmed")
    }

    @Test("missing session_id throws decode error")
    func missingSessionID() {
        let json = """
        {"event": "SessionStart"}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ClaudeHookPayload.self, from: Data(json.utf8))
        }
    }

    @Test("empty session_id throws decode error")
    func emptySessionID() {
        let json = """
        {"event": "SessionStart", "session_id": "  "}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ClaudeHookPayload.self, from: Data(json.utf8))
        }
    }

    // MARK: - Missing event throws

    @Test("missing event key throws decode error")
    func missingEventKey() {
        let json = """
        {"session_id": "sess-1"}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ClaudeHookPayload.self, from: Data(json.utf8))
        }
    }

    // MARK: - Optional fields

    @Test("all optional fields decode when present")
    func allOptionalsPresent() throws {
        let json = """
        {
            "event": "UserPromptSubmit",
            "session_id": "sess-full",
            "source": "cli",
            "timestamp": "2025-01-01T00:00:00Z",
            "cwd": "/project/path",
            "model": "claude-4",
            "terminal_ctx": {
                "tty": "/dev/ttys001",
                "ppid": "1234"
            }
        }
        """
        let payload = try JSONDecoder().decode(ClaudeHookPayload.self, from: Data(json.utf8))
        #expect(payload.source == "cli")
        #expect(payload.timestamp == "2025-01-01T00:00:00Z")
        #expect(payload.cwd == "/project/path")
        #expect(payload.model == "claude-4")
        #expect(payload.terminalCtx?.tty == "/dev/ttys001")
        #expect(payload.terminalCtx?.ppid == "1234")
    }

    @Test("optional fields default to nil when missing")
    func optionalsDefaultNil() throws {
        let json = """
        {"event": "SessionStart", "session_id": "sess-min"}
        """
        let payload = try JSONDecoder().decode(ClaudeHookPayload.self, from: Data(json.utf8))
        #expect(payload.source == nil)
        #expect(payload.timestamp == nil)
        #expect(payload.cwd == nil)
        #expect(payload.model == nil)
        #expect(payload.terminalCtx == nil)
    }

    // MARK: - All event types

    @Test("decodes all event types")
    func allEventTypes() throws {
        for eventType in ClaudeHookEventType.allCases {
            let json = """
            {"event": "\(eventType.rawValue)", "session_id": "sess-\(eventType.rawValue)"}
            """
            let payload = try JSONDecoder().decode(ClaudeHookPayload.self, from: Data(json.utf8))
            #expect(payload.event == eventType)
        }
    }

    @Test("ClaudeHookEventType has exactly 4 cases")
    func eventTypeCount() {
        #expect(ClaudeHookEventType.allCases.count == 4)
    }
}
