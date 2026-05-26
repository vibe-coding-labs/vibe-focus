// Tests/Standalone/ClaudeHookPayloadTests.swift
// Verification: ClaudeHookPayload Decodable (flexible event field + session_id)
//               ClaudeHookResponse Encodable, ClaudeHookEventType roundtrip
// Mirrors: Sources/Hook/ClaudeHookModels.swift:1-290
// Run: swift Tests/Standalone/ClaudeHookPayloadTests.swift

import Foundation

// MARK: - Mirrored types

enum ClaudeHookEventType: String, Codable, CaseIterable {
    case sessionStart = "SessionStart"
    case stop = "Stop"
    case sessionEnd = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
}

struct ClaudeHookResponse: Encodable, Equatable {
    let ok: Bool
    let code: String
    let message: String
    let sessionID: String?
    let handled: Bool
    private enum CodingKeys: String, CodingKey {
        case ok, code, message, handled
        case sessionID = "session_id"
    }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

func checkEqual<T: Equatable>(_ name: String, _ a: T, _ b: T) {
    if a == b { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name) — expected \(b), got \(a)") }
}

// MARK: - ClaudeHookEventType

print("1. ClaudeHookEventType — all cases")
do {
    checkEqual("4 cases", ClaudeHookEventType.allCases.count, 4)
    checkEqual("sessionStart raw", ClaudeHookEventType.sessionStart.rawValue, "SessionStart")
    checkEqual("stop raw", ClaudeHookEventType.stop.rawValue, "Stop")
    checkEqual("sessionEnd raw", ClaudeHookEventType.sessionEnd.rawValue, "SessionEnd")
    checkEqual("userPromptSubmit raw", ClaudeHookEventType.userPromptSubmit.rawValue, "UserPromptSubmit")
}

print("\n2. ClaudeHookEventType — Codable roundtrip")
do {
    for eventType in ClaudeHookEventType.allCases {
        let encoded = try! JSONEncoder().encode(eventType)
        let decoded = try! JSONDecoder().decode(ClaudeHookEventType.self, from: encoded)
        check("roundtrip \(eventType.rawValue)", decoded == eventType)
    }
}

print("\n3. ClaudeHookEventType — decode from JSON string")
do {
    let json = "\"SessionStart\"".data(using: .utf8)!
    let decoded = try! JSONDecoder().decode(ClaudeHookEventType.self, from: json)
    checkEqual("decode from string", decoded, .sessionStart)

    let badJson = "\"InvalidEvent\"".data(using: .utf8)!
    check("invalid event type → nil", (try? JSONDecoder().decode(ClaudeHookEventType.self, from: badJson)) == nil)
}

// MARK: - ClaudeHookPayload with "event" key

print("\n4. ClaudeHookPayload — decode with 'event' key")
do {
    let json = """
    {"event": "UserPromptSubmit", "session_id": "sess-123", "source": "claude-code", "cwd": "/tmp"}
    """.data(using: .utf8)!

    struct Payload: Decodable {
        let event: ClaudeHookEventType
        let sessionID: String
        let source: String?
        let cwd: String?
        private enum CodingKeys: String, CodingKey {
            case event, source, cwd
            case sessionID = "session_id"
        }
    }

    let payload = try! JSONDecoder().decode(Payload.self, from: json)
    checkEqual("event", payload.event, .userPromptSubmit)
    checkEqual("sessionID", payload.sessionID, "sess-123")
    checkEqual("source", payload.source, "claude-code")
    checkEqual("cwd", payload.cwd, "/tmp")
}

// MARK: - ClaudeHookPayload with "hook_event_name" key

print("\n5. ClaudeHookPayload — decode with 'hook_event_name' key")
do {
    let json = """
    {"hook_event_name": "Stop", "session_id": "sess-456"}
    """.data(using: .utf8)!

    struct PayloadFlexible: Decodable {
        let event: ClaudeHookEventType
        let sessionID: String
        private enum CodingKeys: String, CodingKey {
            case event
            case hookEventName = "hook_event_name"
            case sessionID = "session_id"
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let e = try? container.decode(ClaudeHookEventType.self, forKey: .event) {
                event = e
            } else if let e = try? container.decode(ClaudeHookEventType.self, forKey: .hookEventName) {
                event = e
            } else {
                throw DecodingError.dataCorruptedError(forKey: .event, in: container, debugDescription: "no event key")
            }
            sessionID = try container.decode(String.self, forKey: .sessionID)
        }
    }

    let payload = try! JSONDecoder().decode(PayloadFlexible.self, from: json)
    checkEqual("event from hook_event_name", payload.event, .stop)
    checkEqual("sessionID", payload.sessionID, "sess-456")
}

// MARK: - ClaudeHookPayload — missing session_id

print("\n6. ClaudeHookPayload — missing session_id should fail")
do {
    let json = """
    {"event": "SessionStart"}
    """.data(using: .utf8)!

    struct PayloadRequired: Decodable {
        let event: ClaudeHookEventType
        let sessionID: String
        private enum CodingKeys: String, CodingKey {
            case event
            case sessionID = "session_id"
        }
    }

    check("missing session_id → decode fails", (try? JSONDecoder().decode(PayloadRequired.self, from: json)) == nil)
}

// MARK: - ClaudeHookResponse encoding

print("\n7. ClaudeHookResponse — encoding")
do {
    let response = ClaudeHookResponse(ok: true, code: "accepted", message: "Event processed", sessionID: "sess-789", handled: true)
    let encoded = try! JSONEncoder().encode(response)
    let json = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    checkEqual("ok", json["ok"] as? Bool, true)
    checkEqual("code", json["code"] as? String, "accepted")
    checkEqual("message", json["message"] as? String, "Event processed")
    checkEqual("session_id", json["session_id"] as? String, "sess-789")
    checkEqual("handled", json["handled"] as? Bool, true)
}

print("\n8. ClaudeHookResponse — nil sessionID")
do {
    let response = ClaudeHookResponse(ok: false, code: "error", message: "Unauthorized", sessionID: nil, handled: false)
    let encoded = try! JSONEncoder().encode(response)
    let json = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    check("session_id absent when nil", json["session_id"] == nil)
    checkEqual("ok false", json["ok"] as? Bool, false)
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
