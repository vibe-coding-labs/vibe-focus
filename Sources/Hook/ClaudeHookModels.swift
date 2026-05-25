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

    init(windowID: UInt32, pid: Int32, bundleIdentifier: String?, appName: String?, windowNumber: Int? = nil, title: String?) {
        self.windowID = windowID
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.windowNumber = windowNumber
        self.title = title
        self.capturedAt = Date()
    }

    init(from state: WindowState) {
        self.windowID = state.windowID
        self.pid = state.pid
        self.bundleIdentifier = state.bundleIdentifier
        self.appName = state.appName
        self.windowNumber = state.axWindowNumber
        self.title = state.title
        self.capturedAt = state.createdAt
    }
}

/// 统一的窗口状态记录 — 对应 SQLite `windows` 表的一行
/// 合并了原来的 SessionWindowBinding + SavedWindowState
struct WindowState: Codable, Equatable {

    // MARK: - Binding Type
    enum BindingType: String, Equatable, Codable {
        case local       // Local terminal (TTY/PPID match)
        case remote      // Remote SSH (machine_label mapping)
    }

    // MARK: - Primary Key
    var windowID: UInt32          // CGWindowNumber — 主键，CGWindowNumber 变化时可重映射
    var pid: Int32
    var tty: String?              // 终端 TTY 路径 (如 /dev/ttys003)，仅用于日志和匹配辅助

    // MARK: - Window Identity
    var axWindowNumber: Int?
    var appName: String?
    var bundleIdentifier: String?
    var title: String?

    // MARK: - Terminal Context
    var termSessionID: String?
    var itermSessionID: String?
    var kittyWindowID: String?
    var weztermPane: String?
    var envWindowID: String?

    // MARK: - Claude Session
    var sessionID: String?
    var cwd: String?
    var model: String?

    // MARK: - Binding Origin (in-memory only, not persisted to SQLite)
    var bindingType: BindingType = .local

    // MARK: - Toggle State (窗口位置信息)
    var origX: CGFloat?
    var origY: CGFloat?
    var origW: CGFloat?
    var origH: CGFloat?
    var targetX: CGFloat?
    var targetY: CGFloat?
    var targetW: CGFloat?
    var targetH: CGFloat?
    var sourceSpace: Int?
    var sourceDisplay: Int?
    var sourceYabaiDisp: Int?
    var sourceDispSpace: Int?
    var targetDisplay: Int?
    var toggleReason: String?
    var toggledAt: Date?

    // MARK: - Lifecycle
    var isCompleted: Bool
    var completedAt: Date?
    let createdAt: Date
    var updatedAt: Date

    /// toggle state 是否已填充（有 origX 且有 targetX 表示曾被 toggle 保存过）
    var hasToggleState: Bool {
        origX != nil && targetX != nil
    }

    /// 获取原始 frame
    var originalFrame: CGRect? {
        guard let x = origX, let y = origY, let w = origW, let h = origH else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// 获取目标 frame
    var targetFrame: CGRect? {
        guard let x = targetX, let y = targetY, let w = targetW, let h = targetH else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// 是否被污染（originalFrame 和 targetFrame 都在主屏幕上）
    func isCorrupted(mainScreenFrame: CGRect) -> Bool {
        guard let orig = originalFrame, let tgt = targetFrame else { return false }
        let origCenter = CGPoint(x: orig.midX, y: orig.midY)
        let tgtCenter = CGPoint(x: tgt.midX, y: tgt.midY)
        return mainScreenFrame.contains(origCenter) && mainScreenFrame.contains(tgtCenter)
    }
}

/// Toggle 操作的完整快照 — 单一事实来源
/// Ctrl+Q 按下时原子性保存，Restore 时直接读取，不需要任何猜测
struct ToggleRecord: Equatable {
    // MARK: - 窗口身份（恢复时用于查找窗口）
    let windowID: UInt32          // CGWindowNumber
    let pid: Int32
    let bundleIdentifier: String?
    let appName: String?

    // MARK: - 原始位置（恢复目标）
    let origFrame: CGRect
    let sourceSpace: Int          // yabai 全局 space index (1-based)
    let sourceDisplay: Int        // ⚠️ 历史遗留：可能为 NSScreen 0-based 或 yabai 1-based
    let sourceYabaiDisp: Int      // yabai display index (1-based, 1=主屏)
    let sourceDispSpace: Int      // display-local space index (1-based)

    // MARK: - 目标位置（用于验证窗口确实被 toggle 了）
    let targetFrame: CGRect       // 主屏上的 frame
    let targetDisplay: Int        // 主屏的 display index

    // MARK: - 元数据
    let toggledAt: Date
    let sessionID: String?

    /// toggle state 是否有效（origFrame 不在主屏上，targetFrame 在主屏上）
    /// origFrame/targetFrame 是 Quartz 坐标，mainScreenFrame 是 Cocoa 坐标
    /// 需要转换后再比较
    func isValid(mainScreenFrame: CGRect) -> Bool {
        let mainScreenHeight = mainScreenFrame.height
        let origCocoaCenter = CGPoint(x: origFrame.midX, y: mainScreenHeight - origFrame.midY)
        let tgtCocoaCenter = CGPoint(x: targetFrame.midX, y: mainScreenHeight - targetFrame.midY)
        return !mainScreenFrame.contains(origCocoaCenter) && mainScreenFrame.contains(tgtCocoaCenter)
    }
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

    /// 是否包含可用于窗口匹配的有用上下文
    var hasUsefulContext: Bool {
        let result = tty?.isEmpty == false || termSessionID?.isEmpty == false || itermSessionID?.isEmpty == false || (ppid.flatMap { Int32($0) }).map { $0 > 1 } ?? false || machineLabel?.isEmpty == false
        log("TerminalContext.hasUsefulContext evaluated", level: .debug, fields: [
            "result": String(result),
            "hasTTY": String(tty?.isEmpty == false),
            "hasTermSessionID": String(termSessionID?.isEmpty == false),
            "hasItermSessionID": String(itermSessionID?.isEmpty == false),
            "hasMachineLabel": String(machineLabel?.isEmpty == false)
        ])
        if let tty, !tty.isEmpty { return true }
        if let termSessionID, !termSessionID.isEmpty { return true }
        if let itermSessionID, !itermSessionID.isEmpty { return true }
        if let ppid, let pid = Int32(ppid), pid > 1 { return true }
        if let machineLabel, !machineLabel.isEmpty { return true }
        return false
    }

    /// 是否来自远程机器（有 machine_label）
    var isRemote: Bool {
        guard let label = machineLabel, !label.isEmpty else { return false }
        return true
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

        log("ClaudeHookPayload decoded successfully", level: .debug, fields: [
            "event": event.rawValue,
            "sessionID": sessionID,
            "source": source ?? "nil",
            "cwd": cwd ?? "nil",
            "model": model ?? "nil",
            "hasTerminalCtx": String(terminalCtx != nil)
        ])
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
