import CoreGraphics
import Foundation

// MARK: - 会话恢复 v2 快照模型（多屏 × 多工作区 × 多窗 × 多 pane × 本地/远程 Claude 会话）
/// 旧 TerminalGridSnapshot 是「单屏单空间」模型：捕获只收编排目标屏上 isOnScreen
/// 的窗口（其它屏、其它 Space 全部漏拍），且 iTerm2 无 tty 映射、远程 ssh 会话
/// 无建模——2026-09-13 用户重启后「只恢复了一屏一格、且只有空 iTerm2 窗口」的
/// 直接根因。v2 以 yabai 全量窗口查询为骨架（跨屏跨 Space 全可见），窗口按
/// (display, yabai space) 归位，窗内按 pane（tab/split）记录会话。
///
/// 坐标注记：frame 与旧模型同为 Quartz 全局（左上原点），与 CGWindowList /
/// yabai frame 同空间，恢复时无需换算。
///
/// pane 归属链：yabai 只见「窗口」；窗内 pane 列表由 iTerm2 AppleScript 枚举
/// （window→tab→session 自带 tty）或 Terminal.app tty 枚举（window→tab→tty）补齐。

/// 一个 pane（iTerm2 session / Terminal tab）的会话记忆
struct SessionPaneSnapshot: Codable, Equatable {
    /// pane 上的会话形态，决定恢复命令的组合方式
    enum Kind: String, Codable {
        case shell          // 纯 shell（恢复 = cd [+ 启动命令偏好]）
        case localClaude    // 本机 claude（恢复 = cd + claude --resume）
        case remoteSSH      // pane 里跑着 ssh（恢复 = 回放 ssh 或 ssh + cd + --resume）
    }

    /// 终端 TTY（如 /dev/ttys004）；枚举失败为 nil（降级为无会话格子）
    var tty: String?
    var kind: Kind
    /// Claude Code session ID（本机或远程；nil = 未定位到）
    var sessionID: String?
    /// shell/claude 的工作目录。remoteSSH 时是**远程**路径（Hook 绑定链喂进来的
    /// 远程事件 cwd），组合进 ssh 远端命令
    var cwd: String?
    /// 捕获到的原始 ssh 命令行（如 `ssh -o StrictHostKeyChecking=no user@host`），
    /// 无法定位远程会话时原样回放（保真降级）
    var sshCommand: String?
    /// 从 sshCommand 解析出的目的地（user@host[:port]），远程探针与组合命令用
    var sshTarget: String?
    /// 捕获时远程 claude 是否探活（信息性：Mac 重启不杀远程进程，恢复语义已与用户对齐 = --resume 接续）
    var wasRemoteSessionLive: Bool
    /// pane 标题（iTerm2 session name / 窗口标题）。远程 pane 的标题常是远端
    /// 项目名（远端 shell 设 title），是 cwd 未知时匹配远程会话的后备信号
    var title: String?

    init(
        tty: String? = nil,
        kind: Kind,
        sessionID: String? = nil,
        cwd: String? = nil,
        sshCommand: String? = nil,
        sshTarget: String? = nil,
        wasRemoteSessionLive: Bool = false,
        title: String? = nil
    ) {
        self.tty = tty
        self.kind = kind
        self.sessionID = sessionID
        self.cwd = cwd
        self.sshCommand = sshCommand
        self.sshTarget = sshTarget
        self.wasRemoteSessionLive = wasRemoteSessionLive
        self.title = title
    }
}

/// 一个终端窗口的记忆：位置 + 归属屏/工作区 + 窗内全部 pane
struct SessionWindowSnapshot: Codable, Equatable {
    /// 捕获时该窗口所属终端（混用多终端时逐窗记录，恢复按窗建）
    var appBundleID: String
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    /// 捕获时的显示器（CGDisplayID）；恢复时失效回落主屏
    var displayID: UInt32
    /// yabai display index（1-based）；nil = 捕获时 yabai 不可用
    var yabaiDisplay: Int?
    /// yabai 全局 space 索引（1-based，跨 display 全局编号）；nil = 未知（恢复落到该屏可见 space）
    var yabaiSpace: Int?
    var title: String?
    /// 捕获时是否处于最小化（最小化状态本身不还原，恢复为普通窗口，记账说明）
    var wasMinimized: Bool
    var panes: [SessionPaneSnapshot]

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set {
            x = newValue.origin.x
            y = newValue.origin.y
            width = newValue.width
            height = newValue.height
        }
    }

    init(
        appBundleID: String,
        frame: CGRect,
        displayID: UInt32,
        yabaiDisplay: Int? = nil,
        yabaiSpace: Int? = nil,
        title: String? = nil,
        wasMinimized: Bool = false,
        panes: [SessionPaneSnapshot]
    ) {
        self.appBundleID = appBundleID
        self.x = frame.origin.x
        self.y = frame.origin.y
        self.width = frame.width
        self.height = frame.height
        self.displayID = displayID
        self.yabaiDisplay = yabaiDisplay
        self.yabaiSpace = yabaiSpace
        self.title = title
        self.wasMinimized = wasMinimized
        self.panes = panes
    }
}

/// 一份完整的会话快照（v2）。持久化在 WindowStateStore preferences KV（JSON）。
struct SessionRestoreSnapshot: Codable, Equatable {
    /// v2 格式代号（模型演进时的解码护栏）
    static let currentFormatVersion = 2

    var id: String
    var name: String
    var windows: [SessionWindowSnapshot]
    /// 纯 shell / 无会话 pane 恢复时的默认启动命令
    var launchCommand: String?
    var capturedAt: Date
    var formatVersion: Int

    init(
        id: String = UUID().uuidString,
        name: String,
        windows: [SessionWindowSnapshot],
        launchCommand: String?,
        capturedAt: Date = Date(),
        formatVersion: Int = SessionRestoreSnapshot.currentFormatVersion
    ) {
        self.id = id
        self.name = name
        self.windows = windows
        self.launchCommand = launchCommand
        self.capturedAt = capturedAt
        self.formatVersion = formatVersion
    }
}

extension SessionRestoreSnapshot {
    var sessionPaneCount: Int {
        windows.reduce(0) { count, window in
            count + window.panes.lazy.filter { $0.sessionID != nil }.count
        }
    }

    /// 覆盖的 Space 数（去重；nil space 不计）
    var spaceCount: Int {
        Set(windows.compactMap(\.yabaiSpace)).count
    }

    /// 覆盖的屏数（去重）
    var displayCount: Int {
        Set(windows.map(\.displayID)).count
    }
}

// MARK: - 旧快照迁移（纯函数）
/// 旧 TerminalGridSnapshot（单屏模型）→ v2：每个 cell 升格为一个窗口（单 pane）。
/// 旧快照没有 Space 概念（yabaiSpace = nil，恢复落到该屏可见 Space）；tty/sessionID/cwd
/// 语义直接平移。迁移是无损映射：id / capturedAt / launchCommand / 帧全部保留。
enum SessionSnapshotMigrator {

    static func migrateLegacy(_ legacy: TerminalGridSnapshot) -> SessionRestoreSnapshot {
        let windows = legacy.cells.map { cell in
            let pane: SessionPaneSnapshot
            if let sessionID = cell.sessionID, !sessionID.isEmpty {
                pane = SessionPaneSnapshot(tty: cell.ttyPath, kind: .localClaude, sessionID: sessionID, cwd: cell.cwd)
            } else if let tty = cell.ttyPath, !tty.isEmpty {
                pane = SessionPaneSnapshot(tty: tty, kind: .shell, cwd: cell.cwd)
            } else {
                pane = SessionPaneSnapshot(kind: .shell, cwd: cell.cwd)
            }
            return SessionWindowSnapshot(
                appBundleID: legacy.appBundleID,
                frame: cell.frame,
                displayID: legacy.displayID,
                yabaiDisplay: legacy.displayYabaiIndex,
                yabaiSpace: nil,
                title: cell.title,
                panes: [pane]
            )
        }
        return SessionRestoreSnapshot(
            id: legacy.id,
            name: legacy.name,
            windows: windows,
            launchCommand: legacy.launchCommand,
            capturedAt: legacy.capturedAt
        )
    }
}
