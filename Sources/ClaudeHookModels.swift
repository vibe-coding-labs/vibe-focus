import Foundation

enum ClaudeHookEventType: String, Codable, CaseIterable {
    case sessionStart = "SessionStart"
    case stop = "Stop"
    case sessionEnd = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
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

/// Claude Code hook 辅助脚本捕获的终端上下文信息
/// 用于精确定位 hook 事件对应的终端窗口，解决多工作区/多实例场景下的窗口匹配问题
struct TerminalContext: Codable, Equatable {
    let termSessionID: String?
    let itermSessionID: String?
    let kittyWindowID: String?
    let weztermPane: String?
    let tty: String?
    let ppid: String?
    let claudeProjectDir: String?
    let windowID: String?

    enum CodingKeys: String, CodingKey {
        case termSessionID = "term_session_id"
        case itermSessionID = "iterm_session_id"
        case kittyWindowID = "kitty_window_id"
        case weztermPane = "wezterm_pane"
        case tty
        case ppid
        case claudeProjectDir = "claude_project_dir"
        case windowID = "window_id"
    }

    /// 是否包含可用于窗口匹配的有用上下文
    var hasUsefulContext: Bool {
        if let tty, !tty.isEmpty { return true }
        if let termSessionID, !termSessionID.isEmpty { return true }
        if let itermSessionID, !itermSessionID.isEmpty { return true }
        if let ppid, let pid = Int32(ppid), pid > 1 { return true }
        return false
    }
}

struct ClaudeHookPayload: Decodable {
    let event: ClaudeHookEventType
    let sessionID: String
    let source: String?
    let timestamp: String?
    let cwd: String?
    let model: String?
    let terminalCtx: TerminalContext?

    private enum CodingKeys: String, CodingKey {
        case event
        case hookEventName = "hook_event_name"
        case sessionID = "session_id"
        case sessionId
        case source
        case timestamp
        case cwd
        case model
        case terminalCtx = "terminal_ctx"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // 兼容两种字段名：我们的测试用 event，Claude Code HTTP Hook 用 hook_event_name
        if let e = try? container.decode(ClaudeHookEventType.self, forKey: .event) {
            event = e
        } else if let e = try? container.decode(ClaudeHookEventType.self, forKey: .hookEventName) {
            event = e
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .event,
                in: container,
                debugDescription: "Neither 'event' nor 'hook_event_name' found"
            )
        }

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
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        terminalCtx = try container.decodeIfPresent(TerminalContext.self, forKey: .terminalCtx)
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
