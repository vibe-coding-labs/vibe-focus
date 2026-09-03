import CoreGraphics
import Foundation

// MARK: - 自动恢复规划器（纯函数）
/// 重启/登录后自动恢复的核心联动逻辑：快照格子 × 当前活窗口观测 × claude 存活标记
/// → 每格动作（新建 / 向既有窗口注入 / 跳过）。三类上下文互相联动才能拿到完整现场：
/// - 快照：位置 + cwd + sessionID（捕获时多个来源联动拼出，见 ClaudeSessionLocator）
/// - 活窗口：CGWindowList 枚举 + AppleScript tty 映射
/// - claude 存活：tty 上是否有活 claude 进程（会话还在跑就绝不能重复拉起/注入）

/// 自动恢复时一个"活终端窗口"的观测快照
struct TerminalLiveWindow: Equatable {
    /// CGWindowNumber（Terminal.app 的 AppleScript window id 与之相等）
    let windowID: UInt32
    let frame: CGRect
    let ttyPath: String?
    /// 该窗口 tty 上是否有存活的 claude 进程（会话仍在跑）
    let hasLiveClaude: Bool
}

/// 单个快照格子的自动恢复动作
enum TerminalAutoRestoreCellAction: Equatable {
    /// 无活窗口 → 新建窗口并执行命令
    case create
    /// 有活窗口且会话未在跑 → 向既有窗口注入命令（不重建，防重复窗口）
    case inject(windowID: UInt32)
    /// 有活窗口且 claude 会话仍在跑（或终端不支持注入）→ 不动
    case skipRunning
}

enum TerminalAutoRestorePlanner {

    /// frame 中心匹配容差（px）——快照记录的是实际落位，活窗口应几乎重合，
    /// 留少量余量吸收阴影读数噪声（±2~3px，见窗口移动调试手册）
    static let frameTolerance: CGFloat = 15

    /// 对每个 cell 求动作。
    /// - Parameters:
    ///   - injectEnabled: 终端不支持向既有窗口可靠注入时传 false（iTerm2 的
    ///     AppleScript window id ≠ CGWindowNumber，无法按 CG id 定位注入），
    ///     此时匹配到的活窗口一律 skipRunning，只重建缺失格子。
    static func plan(
        cells: [TerminalGridCellSnapshot],
        targetFrames: [CGRect],
        liveWindows: [TerminalLiveWindow],
        injectEnabled: Bool = true
    ) -> [TerminalAutoRestoreCellAction] {
        var used = Set<UInt32>()
        var actions: [TerminalAutoRestoreCellAction] = []
        actions.reserveCapacity(cells.count)
        for (index, _) in cells.enumerated() {
            guard index < targetFrames.count else { break }
            let frame = targetFrames[index]
            let matched = liveWindows.first { live in
                !used.contains(live.windowID)
                    && hypot(live.frame.midX - frame.midX, live.frame.midY - frame.midY) <= frameTolerance
            }
            if let live = matched {
                used.insert(live.windowID)
                if !injectEnabled {
                    actions.append(.skipRunning)
                } else if live.hasLiveClaude {
                    actions.append(.skipRunning)
                } else {
                    actions.append(.inject(windowID: live.windowID))
                }
            } else {
                actions.append(.create)
            }
        }
        return actions
    }
}
