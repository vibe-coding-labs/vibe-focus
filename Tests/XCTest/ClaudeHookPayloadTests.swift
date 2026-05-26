import Testing
import Foundation
@testable import VibeFocusKit

@Suite("ClaudeHookPayload Decoding")
struct ClaudeHookPayloadTests {

    private func decode(_ json: String) throws -> ClaudeHookPayload {
        guard let data = json.data(using: .utf8) else {
            throw NSError(domain: "test", code: 1)
        }
        return try JSONDecoder().decode(ClaudeHookPayload.self, from: data)
    }

    @Test("decodes from 'event' key")
    func eventKey() throws {
        let json = """
        {"event":"SessionStart","session_id":"s1"}
        """
        let payload = try decode(json)
        #expect(payload.event == .sessionStart)
        #expect(payload.sessionID == "s1")
    }

    @Test("decodes from 'hook_event_name' key")
    func hookEventNameKey() throws {
        let json = """
        {"hook_event_name":"Stop","session_id":"s2"}
        """
        let payload = try decode(json)
        #expect(payload.event == .stop)
        #expect(payload.sessionID == "s2")
    }

    @Test("prefers 'event' over 'hook_event_name' when both present")
    func eventPriority() throws {
        let json = """
        {"event":"UserPromptSubmit","hook_event_name":"SessionEnd","session_id":"s3"}
        """
        let payload = try decode(json)
        #expect(payload.event == .userPromptSubmit)
    }

    @Test("decodes all optional fields")
    func allOptionalFields() throws {
        let json = """
        {"event":"SessionStart","session_id":"s4","source":"claude","timestamp":"2025-01-01T00:00:00Z","cwd":"/Users/test/project","model":"opus","terminal_ctx":{"tty":"/dev/ttys001","ppid":"1234","machine_label":"remote-host"}}
        """
        let payload = try decode(json)
        #expect(payload.source == "claude")
        #expect(payload.timestamp == "2025-01-01T00:00:00Z")
        #expect(payload.cwd == "/Users/test/project")
        #expect(payload.model == "opus")
        #expect(payload.terminalCtx?.tty == "/dev/ttys001")
        #expect(payload.terminalCtx?.ppid == "1234")
        #expect(payload.terminalCtx?.machineLabel == "remote-host")
    }

    @Test("throws when neither event key is present")
    func missingEventKey() {
        let json = """
        {"session_id":"s5"}
        """
        #expect(throws: DecodingError.self) {
            _ = try decode(json)
        }
    }

    @Test("throws when session_id is missing")
    func missingSessionID() {
        let json = """
        {"event":"Stop"}
        """
        #expect(throws: DecodingError.self) {
            _ = try decode(json)
        }
    }

    @Test("throws when session_id is empty string")
    func emptySessionID() {
        let json = """
        {"event":"Stop","session_id":"   "}
        """
        #expect(throws: DecodingError.self) {
            _ = try decode(json)
        }
    }

    @Test("decodes session_id from 'sessionId' fallback key")
    func sessionIdFallback() throws {
        let json = """
        {"event":"SessionEnd","sessionId":"s6"}
        """
        let payload = try decode(json)
        #expect(payload.sessionID == "s6")
    }

    @Test("trims whitespace from session_id")
    func trimmedSessionID() throws {
        let json = """
        {"event":"Stop","session_id":"  s7  "}
        """
        let payload = try decode(json)
        #expect(payload.sessionID == "s7")
    }

    @Test("all event types decode correctly")
    func allEventTypes() throws {
        let events: [(String, ClaudeHookEventType)] = [
            ("SessionStart", .sessionStart),
            ("Stop", .stop),
            ("SessionEnd", .sessionEnd),
            ("UserPromptSubmit", .userPromptSubmit),
        ]
        for (rawValue, expected) in events {
            let json = """
            {"event":"\(rawValue)","session_id":"test"}
            """
            let payload = try decode(json)
            #expect(payload.event == expected, "Failed for \(rawValue)")
        }
    }

    @Test("ClaudeHookResponse encodes with snake_case session_id")
    func responseEncoding() throws {
        let response = ClaudeHookResponse(
            ok: true, code: "test_code",
            message: "hello", sessionID: "s1", handled: true
        )
        let data = try JSONEncoder().encode(response)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["session_id"] as? String == "s1")
        #expect(json?["ok"] as? Bool == true)
        #expect(json?["code"] as? String == "test_code")
        #expect(json?["handled"] as? Bool == true)
    }
}
