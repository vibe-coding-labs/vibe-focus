import Foundation
import CoreGraphics

/// 关机时的终端窗口快照，用于下次开机恢复
struct ShutdownSnapshot: Codable {
    /// 快照采集时间
    let capturedAt: Date
    /// 采集时的 macOS 启动时间（用于判断快照是否属于上次启动）
    let systemUptimeAtCapture: TimeInterval
    /// 所有终端窗口快照
    var terminalWindows: [TerminalWindowSnapshot]
    /// 采集时正在运行的终端 App bundle IDs（用于区分"终端没开"和"终端开了但没窗口"）
    let runningTerminalApps: Set<String>
}

/// 单个终端窗口在关机时的状态
struct TerminalWindowSnapshot: Codable, Equatable {
    /// CGWindowNumber — 窗口唯一标识（恢复后窗口 ID 会变化）
    let windowID: UInt32
    /// 终端进程 PID（恢复后会变化）
    let pid: Int32
    /// 终端 App 名称（如 "Terminal", "iTerm2"）
    let appName: String
    /// Bundle Identifier（如 "com.apple.Terminal"）
    let bundleIdentifier: String
    /// 窗口标题
    let title: String?
    /// 窗口在屏幕上的位置和大小
    let frame: SnapshotRect
    /// 所在屏幕的 Display ID (CGDirectDisplayID)
    let displayID: UInt32
    /// 所在 Space 的全局 index (yabai) — 可为 nil（无 yabai 时）
    let spaceIndex: Int?
    /// 所在 Space 的 display-local index
    let displayLocalSpaceIndex: Int?
    /// 终端 TTY 路径（如 /dev/ttys001）
    let tty: String?
    /// Terminal.app 的 TERM_SESSION_ID
    let termSessionID: String?
    /// iTerm2 的 ITERM_SESSION_ID
    let itermSessionID: String?
    // MARK: - Claude Code 关联信息
    /// Claude Code Session ID
    let claudeSessionID: String?
    /// Claude Code 项目绝对路径
    let claudeProjectDir: String?
    /// Claude Code 使用的模型
    let claudeModel: String?
}

/// CGRect 的 Codable 包装
struct SnapshotRect: Codable, Equatable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(_ rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.width
        self.height = rect.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
