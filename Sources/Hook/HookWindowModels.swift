// HookWindowModels.swift
// VibeFocus — 窗口身份/状态/Toggle 记录模型
// 2026-09-08 B44 从 ClaudeHookModels.swift 按域拆分：窗口模型与 Hook 数据契约分文件

import Foundation

// Reasons why a window was moved to the main screen.
/// Reasons why a window was moved to the main screen.
enum WindowMoveReason: String, Codable {
    case manualHotkey = "manual_hotkey"
    case claudeSessionEnd = "claude_session_end"
    case userPromptSubmit = "user_prompt_submit"
}

/// Identifies a window by CGWindowID, PID, and optional metadata.
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
    /// 移动原因（WindowMoveReason.rawValue），落库到 windows.toggle_reason。
    /// 列所有权：本记录的写入方（ToggleEngine）只允许写 toggle 列；
    /// session_id 等绑定列归 SessionWindowRegistry 独占写。
    let reason: String

    init(
        windowID: UInt32,
        pid: Int32,
        bundleIdentifier: String?,
        appName: String?,
        origFrame: CGRect,
        sourceSpace: Int,
        sourceDisplay: Int,
        sourceYabaiDisp: Int,
        sourceDispSpace: Int,
        targetFrame: CGRect,
        targetDisplay: Int,
        toggledAt: Date,
        sessionID: String?,
        reason: String = WindowMoveReason.manualHotkey.rawValue
    ) {
        self.windowID = windowID
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.origFrame = origFrame
        self.sourceSpace = sourceSpace
        self.sourceDisplay = sourceDisplay
        self.sourceYabaiDisp = sourceYabaiDisp
        self.sourceDispSpace = sourceDispSpace
        self.targetFrame = targetFrame
        self.targetDisplay = targetDisplay
        self.toggledAt = toggledAt
        self.sessionID = sessionID
        self.reason = reason
    }

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
