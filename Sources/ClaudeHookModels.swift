import Foundation

enum ClaudeHookEventType: String, Codable, CaseIterable {
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
}

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

struct SessionWindowBinding: Codable, Equatable {
    let sessionID: String
    var windowIdentity: WindowIdentity
    let createdAt: Date
    var lastSeenAt: Date
    var isCompleted: Bool
    var completedAt: Date?
}

struct ClaudeHookPayload: Decodable {
    let event: ClaudeHookEventType
    let sessionID: String
    let source: String?
    let timestamp: String?

    private enum CodingKeys: String, CodingKey {
        case event
        case sessionID = "session_id"
        case sessionId
        case source
        case timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        event = try container.decode(ClaudeHookEventType.self, forKey: .event)

        let sessionValue = try container.decodeIfPresent(String.self, forKey: .sessionID)
            ?? container.decodeIfPresent(String.self, forKey: .sessionId)
        let trimmedSession = sessionValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedSession.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .sessionID,
                in: container,
                debugDescription: "session_id is required"
            )
        }
        sessionID = trimmedSession
        source = try container.decodeIfPresent(String.self, forKey: .source)
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
    }
}

struct ClaudeHookResponse: Encodable {
    let ok: Bool
    let code: String
    let message: String
    let sessionID: String?
    let handled: Bool

    private enum CodingKeys: String, CodingKey {
        case ok
        case code
        case message
        case sessionID = "session_id"
        case handled
    }
}
