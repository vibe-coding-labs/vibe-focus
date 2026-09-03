import CoreGraphics
import Foundation

// MARK: - Terminal 网格快照模型
/// 一个网格格子的记忆：位置 + 当时的 Claude Code session。
struct TerminalGridCellSnapshot: Codable, Equatable {
    /// row-major 序号（0 起）
    var index: Int
    /// Quartz 坐标（捕获时窗口实际落位）
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    /// 终端 TTY（如 /dev/ttys004）；iTerm2 无法经 AppleScript 获取时为 nil
    var ttyPath: String?
    /// 捕获时该终端正在运行的 Claude Code session ID（nil = 无会话）
    var sessionID: String?
    /// 捕获时 shell/claude 的工作目录（重建时 cd 回去）
    var cwd: String?
    var title: String?

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set {
            x = newValue.origin.x
            y = newValue.origin.y
            width = newValue.width
            height = newValue.height
        }
    }
}

/// 一份完整布局快照。持久化在 WindowStateStore preferences KV（JSON）。
/// 有意不存 CGWindowNumber——窗口重建后 CG 编号会变，tty/session 才是稳定键。
struct TerminalGridSnapshot: Codable, Equatable {
    var id: String
    var name: String
    /// 捕获/创建时使用的终端 app（com.apple.Terminal / com.googlecode.iterm2）
    var appBundleID: String
    /// 捕获时的目标屏（CGDisplayID）；恢复时失效则回落主屏
    var displayID: UInt32
    var displayYabaiIndex: Int?
    var rows: Int
    var cols: Int
    var cells: [TerminalGridCellSnapshot]
    /// 每格默认启动命令（无 session 的格子恢复时使用）
    var launchCommand: String?
    var capturedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        appBundleID: String,
        displayID: UInt32,
        displayYabaiIndex: Int?,
        rows: Int,
        cols: Int,
        cells: [TerminalGridCellSnapshot],
        launchCommand: String?,
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.appBundleID = appBundleID
        self.displayID = displayID
        self.displayYabaiIndex = displayYabaiIndex
        self.rows = rows
        self.cols = cols
        self.cells = cells
        self.launchCommand = launchCommand
        self.capturedAt = capturedAt
    }
}
