import Foundation

/// Claude Code hook event types (SessionStart, SessionEnd, UserPromptSubmit, Stop).
enum ClaudeHookEventType: String, Codable, CaseIterable {
    case sessionStart = "SessionStart"
    case stop = "Stop"
    case sessionEnd = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
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
    let machineLabel: String?

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

    /// 是否包含可用于窗口匹配的有用上下文。
    ///
    /// ## 场景
    /// - SessionStart 绑定入口（handleSessionStart）的绑定前置判据：false 时直接拒绝绑定；
    /// - 判定字段：TTY / termSessionID / itermSessionID / 有效 PPID（>1）/ machineLabel 任一非空。
    ///
    /// ## 竞态风险
    /// 无（纯值判定）。历史上"日志用一份内联表达式、返回值用另一份 if 链"两份逻辑各算各的，
    /// 一旦漂移日志会说谎——现收敛为单一谓词，日志与返回值消费同一 result。
    var hasUsefulContext: Bool {
        let hasTTY = tty?.isEmpty == false
        let hasTermSessionID = termSessionID?.isEmpty == false
        let hasItermSessionID = itermSessionID?.isEmpty == false
        let hasLivePPID: Bool
        if let ppid, let pid = Int32(ppid) {
            hasLivePPID = pid > 1
        } else {
            hasLivePPID = false
        }
        let hasMachineLabel = machineLabel?.isEmpty == false
        let result = hasTTY || hasTermSessionID || hasItermSessionID || hasLivePPID || hasMachineLabel
        log("TerminalContext.hasUsefulContext evaluated", level: .debug, fields: [
            "result": String(result),
            "hasTTY": String(hasTTY),
            "hasTermSessionID": String(hasTermSessionID),
            "hasItermSessionID": String(hasItermSessionID),
            "hasMachineLabel": String(hasMachineLabel)
        ])
        return result
    }

    /// 是否来自远程机器（有 machine_label）
    var isRemote: Bool {
        guard let label = machineLabel, !label.isEmpty else { return false }
        return true
    }
}

/// Parsed payload from a Claude Code hook HTTP request.
struct ClaudeHookPayload: Decodable {
    let event: ClaudeHookEventType
    let sessionID: String
    let source: String?
    let timestamp: String?
    let cwd: String?
    let model: String?
    let terminalCtx: TerminalContext?
    /// AI 最后一轮回复的正文（Claude Code / Codex 的 Stop hook payload 直接携带）
    /// 用于语音播报模板插值与 LLM 总结 fallback
    let lastAssistantMessage: String?
    /// 会话 transcript 文件路径（Stop hook payload 携带，目前未使用，留作未来扩展）
    let transcriptPath: String?

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
        case lastAssistantMessage = "last_assistant_message"
        case transcriptPath = "transcript_path"
    }

    /// Memberwise initializer（用于非解码路径构造，如语音播报试听）
    init(
        event: ClaudeHookEventType,
        sessionID: String,
        source: String?,
        timestamp: String?,
        cwd: String?,
        model: String?,
        terminalCtx: TerminalContext?,
        lastAssistantMessage: String?,
        transcriptPath: String?
    ) {
        self.event = event
        self.sessionID = sessionID
        self.source = source
        self.timestamp = timestamp
        self.cwd = cwd
        self.model = model
        self.terminalCtx = terminalCtx
        self.lastAssistantMessage = lastAssistantMessage
        self.transcriptPath = transcriptPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        log("ClaudeHookPayload.init(from:) decoding started", level: .debug)

        // 兼容两种字段名：我们的测试用 event，Claude Code HTTP Hook 用 hook_event_name
        if let e = try? container.decode(ClaudeHookEventType.self, forKey: .event) {
            log("ClaudeHookPayload: decoded event from 'event' key", level: .debug, fields: ["eventType": e.rawValue])
            event = e
        } else if let e = try? container.decode(ClaudeHookEventType.self, forKey: .hookEventName) {
            log("ClaudeHookPayload: decoded event from 'hook_event_name' key", level: .debug, fields: ["eventType": e.rawValue])
            event = e
        } else {
            log("ClaudeHookPayload: failed to decode event field", level: .debug)
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
            log("ClaudeHookPayload: session_id is empty or missing", level: .debug)
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
        lastAssistantMessage = try container.decodeIfPresent(String.self, forKey: .lastAssistantMessage)
        transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)

        log("ClaudeHookPayload decoded successfully", level: .debug, fields: [
            "event": event.rawValue,
            "sessionID": sessionID,
            "source": source ?? "nil",
            "cwd": cwd ?? "nil",
            "model": model ?? "nil",
            "hasTerminalCtx": String(terminalCtx != nil),
            "hasLastAssistantMessage": String(lastAssistantMessage != nil),
            "hasTranscriptPath": String(transcriptPath != nil)
        ])
    }
}

/// HTTP response sent back to Claude Code after processing a hook event.
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
