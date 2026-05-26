// Tests/Standalone/HookModelsFullTests.swift
// Verification: WindowMoveReason, WindowIdentity, ClaudeHookPayload full decoding
// Mirrors: Sources/Hook/ClaudeHookModels.swift:10-274
// Run: swift Tests/Standalone/HookModelsFullTests.swift

import Foundation

// MARK: - Mirrored types

enum WindowMoveReason: String, Codable {
    case manualHotkey = "manual_hotkey"
    case claudeSessionEnd = "claude_session_end"
}

struct WindowIdentity: Codable, Equatable {
    let windowID: UInt32
    let pid: Int32
    let bundleIdentifier: String?
    let appName: String?
    let windowNumber: Int?
    let title: String?
    let capturedAt: Date
}

struct TerminalContext: Codable, Equatable {
    var termSessionID: String?
    var itermSessionID: String?
    var kittyWindowID: String?
    var weztermPane: String?
    var tty: String?
    var ppid: String?
    var machineLabel: String?
    var claudeProjectDir: String?
    var windowID: String?

    enum CodingKeys: String, CodingKey {
        case termSessionID = "term_session_id"
        case itermSessionID = "iterm_session_id"
        case kittyWindowID = "kitty_window_id"
        case weztermPane = "wezterm_pane"
        case tty
        case ppid
        case claudeProjectDir = "claude_project_dir"
        case windowID = "window_id"
        case machineLabel = "machine_label"
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

func checkEqual<T: Equatable>(_ name: String, _ a: T?, _ b: T?) {
    if a == b { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name) — expected \(String(describing: b)), got \(String(describing: a))") }
}

// MARK: - WindowMoveReason

print("1. WindowMoveReason — raw values")
do {
    checkEqual("manualHotkey", WindowMoveReason.manualHotkey.rawValue, "manual_hotkey")
    checkEqual("claudeSessionEnd", WindowMoveReason.claudeSessionEnd.rawValue, "claude_session_end")
}

print("\n2. WindowMoveReason — Codable roundtrip")
do {
    for reason in [WindowMoveReason.manualHotkey, .claudeSessionEnd] {
        let encoded = try! JSONEncoder().encode(reason)
        let decoded = try! JSONDecoder().decode(WindowMoveReason.self, from: encoded)
        check("roundtrip \(reason.rawValue)", decoded == reason)
    }
}

print("\n3. WindowMoveReason — decode from string")
do {
    let data = "\"manual_hotkey\"".data(using: .utf8)!
    let decoded = try! JSONDecoder().decode(WindowMoveReason.self, from: data)
    checkEqual("decode from string", decoded, .manualHotkey)
}

// MARK: - WindowIdentity Codable

print("\n4. WindowIdentity — full Codable roundtrip")
do {
    let id = WindowIdentity(
        windowID: 42,
        pid: 1234,
        bundleIdentifier: "com.apple.Terminal",
        appName: "Terminal",
        windowNumber: 7,
        title: "bash — 80x24",
        capturedAt: Date(timeIntervalSince1970: 1700000000)
    )
    let encoded = try! JSONEncoder().encode(id)
    let decoded = try! JSONDecoder().decode(WindowIdentity.self, from: encoded)
    checkEqual("windowID", decoded.windowID, UInt32(42))
    checkEqual("pid", decoded.pid, Int32(1234))
    checkEqual("bundleIdentifier", decoded.bundleIdentifier, "com.apple.Terminal")
    checkEqual("appName", decoded.appName, "Terminal")
    checkEqual("windowNumber", decoded.windowNumber, 7)
    checkEqual("title", decoded.title, "bash — 80x24")
}

print("\n5. WindowIdentity — minimal (nil optionals)")
do {
    let id = WindowIdentity(
        windowID: 1,
        pid: 100,
        bundleIdentifier: nil,
        appName: nil,
        windowNumber: nil,
        title: nil,
        capturedAt: Date()
    )
    let encoded = try! JSONEncoder().encode(id)
    let decoded = try! JSONDecoder().decode(WindowIdentity.self, from: encoded)
    checkEqual("windowID", decoded.windowID, UInt32(1))
    check("bundleIdentifier nil", decoded.bundleIdentifier == nil)
    check("appName nil", decoded.appName == nil)
    check("windowNumber nil", decoded.windowNumber == nil)
    check("title nil", decoded.title == nil)
}

print("\n6. WindowIdentity — JSON structure")
do {
    let id = WindowIdentity(
        windowID: 42,
        pid: 1234,
        bundleIdentifier: "com.apple.Terminal",
        appName: "Terminal",
        windowNumber: nil,
        title: nil,
        capturedAt: Date(timeIntervalSince1970: 1700000000)
    )
    let encoded = try! JSONEncoder().encode(id)
    let json = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    check("has windowID", json["windowID"] != nil || json["windowId"] != nil)
    check("has pid", json["pid"] != nil)
    check("capturedAt present", json["capturedAt"] != nil)
}

// MARK: - ClaudeHookPayload — full decoding with flexible fields

print("\n7. ClaudeHookPayload — decode with 'event' key + session_id")
do {
    let json = """
    {"event": "SessionStart", "session_id": "sess-123", "source": "claude-code"}
    """.data(using: .utf8)!

    struct Payload: Decodable {
        let event: String
        let sessionID: String
        let source: String?
        private enum CodingKeys: String, CodingKey {
            case event, source
            case sessionID = "session_id"
        }
    }

    let payload = try! JSONDecoder().decode(Payload.self, from: json)
    checkEqual("event", payload.event, "SessionStart")
    checkEqual("sessionID", payload.sessionID, "sess-123")
    checkEqual("source", payload.source, "claude-code")
}

print("\n8. ClaudeHookPayload — decode with 'hook_event_name' key")
do {
    let json = """
    {"hook_event_name": "Stop", "session_id": "sess-456"}
    """.data(using: .utf8)!

    struct PayloadFlexible: Decodable {
        let eventType: String
        let sessionID: String
        private enum CodingKeys: String, CodingKey {
            case event
            case hookEventName = "hook_event_name"
            case sessionID = "session_id"
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let e = try? container.decode(String.self, forKey: .event) {
                eventType = e
            } else {
                eventType = try container.decode(String.self, forKey: .hookEventName)
            }
            sessionID = try container.decode(String.self, forKey: .sessionID)
        }
    }

    let payload = try! JSONDecoder().decode(PayloadFlexible.self, from: json)
    checkEqual("event from hook_event_name", payload.eventType, "Stop")
    checkEqual("sessionID", payload.sessionID, "sess-456")
}

print("\n9. ClaudeHookPayload — session_id fallback to sessionId")
do {
    let json = """
    {"event": "SessionStart", "sessionId": "sess-via-camelCase"}
    """.data(using: .utf8)!

    struct PayloadFallback: Decodable {
        let sessionID: String
        private enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case sessionId
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let value = try container.decodeIfPresent(String.self, forKey: .sessionID)
                ?? container.decodeIfPresent(String.self, forKey: .sessionId)
            sessionID = value ?? ""
        }
    }

    let payload = try! JSONDecoder().decode(PayloadFallback.self, from: json)
    checkEqual("sessionId fallback", payload.sessionID, "sess-via-camelCase")
}

print("\n10. ClaudeHookPayload — session_id trimming")
do {
    let json = """
    {"event": "SessionStart", "session_id": "  sess-whitespace  "}
    """.data(using: .utf8)!

    struct PayloadTrim: Decodable {
        let sessionID: String
        private enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try container.decode(String.self, forKey: .sessionID)
            sessionID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    let payload = try! JSONDecoder().decode(PayloadTrim.self, from: json)
    checkEqual("whitespace trimmed", payload.sessionID, "sess-whitespace")
}

print("\n11. ClaudeHookPayload — empty session_id after trimming rejected")
do {
    let json = """
    {"event": "SessionStart", "session_id": "   "}
    """.data(using: .utf8)!

    struct PayloadRequired: Decodable {
        let sessionID: String
        private enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try container.decode(String.self, forKey: .sessionID)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .sessionID, in: container, debugDescription: "empty")
            }
            sessionID = trimmed
        }
    }

    check("whitespace-only session_id rejected", (try? JSONDecoder().decode(PayloadRequired.self, from: json)) == nil)
}

print("\n12. ClaudeHookPayload — with terminal_ctx")
do {
    let json = """
    {
        "event": "UserPromptSubmit",
        "session_id": "sess-ctx",
        "terminal_ctx": {
            "term_session_id": "ts-1",
            "tty": "/dev/ttys003",
            "ppid": "1234",
            "window_id": "42"
        }
    }
    """.data(using: .utf8)!

    struct PayloadWithCtx: Decodable {
        let event: String
        let sessionID: String
        let terminalCtx: TerminalContext?
        private enum CodingKeys: String, CodingKey {
            case event
            case sessionID = "session_id"
            case terminalCtx = "terminal_ctx"
        }
    }

    let payload = try! JSONDecoder().decode(PayloadWithCtx.self, from: json)
    check("has terminalCtx", payload.terminalCtx != nil)
    checkEqual("termSessionID", payload.terminalCtx?.termSessionID, "ts-1")
    checkEqual("tty", payload.terminalCtx?.tty, "/dev/ttys003")
    checkEqual("ppid", payload.terminalCtx?.ppid, "1234")
    checkEqual("windowID", payload.terminalCtx?.windowID, "42")
}

print("\n13. ClaudeHookPayload — optional fields nil when absent")
do {
    let json = """
    {"event": "Stop", "session_id": "sess-minimal"}
    """.data(using: .utf8)!

    struct PayloadMinimal: Decodable {
        let sessionID: String
        let source: String?
        let timestamp: String?
        let cwd: String?
        let model: String?
        let terminalCtx: TerminalContext?
        private enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case source, timestamp, cwd, model
            case terminalCtx = "terminal_ctx"
        }
    }

    let payload = try! JSONDecoder().decode(PayloadMinimal.self, from: json)
    check("source nil", payload.source == nil)
    check("timestamp nil", payload.timestamp == nil)
    check("cwd nil", payload.cwd == nil)
    check("model nil", payload.model == nil)
    check("terminalCtx nil", payload.terminalCtx == nil)
}

print("\n14. ClaudeHookPayload — all fields populated")
do {
    let json = """
    {
        "event": "Stop",
        "session_id": "sess-full",
        "source": "claude-code",
        "timestamp": "2026-05-25T00:00:00Z",
        "cwd": "/Users/test/project",
        "model": "claude-sonnet-4-6",
        "terminal_ctx": {
            "term_session_id": "ts-full",
            "iterm_session_id": "iterm-full",
            "kitty_window_id": "kw-1",
            "wezterm_pane": "wp-1",
            "tty": "/dev/ttys999",
            "ppid": "5678",
            "machine_label": "remote-host",
            "claude_project_dir": "/project",
            "window_id": "99"
        }
    }
    """.data(using: .utf8)!

    struct PayloadFull: Decodable {
        let sessionID: String
        let source: String?
        let timestamp: String?
        let cwd: String?
        let model: String?
        let terminalCtx: TerminalContext?
        private enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case source, timestamp, cwd, model
            case terminalCtx = "terminal_ctx"
        }
    }

    let payload = try! JSONDecoder().decode(PayloadFull.self, from: json)
    checkEqual("source", payload.source, "claude-code")
    checkEqual("timestamp", payload.timestamp, "2026-05-25T00:00:00Z")
    checkEqual("cwd", payload.cwd, "/Users/test/project")
    checkEqual("model", payload.model, "claude-sonnet-4-6")
    checkEqual("ctx.termSessionID", payload.terminalCtx?.termSessionID, "ts-full")
    checkEqual("ctx.itermSessionID", payload.terminalCtx?.itermSessionID, "iterm-full")
    checkEqual("ctx.machineLabel", payload.terminalCtx?.machineLabel, "remote-host")
    checkEqual("ctx.claudeProjectDir", payload.terminalCtx?.claudeProjectDir, "/project")
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
