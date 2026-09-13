import CoreGraphics
import Foundation

// MARK: - 会话恢复规划器（纯函数）
/// 快照 × 恢复时环境真值（现存显示器/工作区/活窗观测）→ 每窗动作 + 降级台账。
/// 全部输入由执行器真值采集；本文件零 IO，Runner 穷尽锁定。
enum SessionRestorePlanner {

    /// 恢复时观测到的一个活终端窗（含 pane 存活形态）
    struct ObservedLiveWindow: Equatable {
        let cgWindowID: UInt32
        let frame: CGRect
        let appBundleID: String
        /// iTerm2 的 AppleScript window id（注入定位用；Terminal.app 为 nil——
        /// 其 AppleScript id == CGWindowNumber）
        let itermWindowASID: String?
        /// 活窗 pane 列表（与枚举序一致）
        let panes: [ObservedLivePane]
        /// paneIndex → AppleScript 定位坐标（iTerm2 注入路径；Terminal/未知为空）
        var paneCoords: [Int: PaneCoord] = [:]
    }

    struct PaneCoord: Equatable {
        let tabIndex: Int
        let sessionIndex: Int
    }

    struct ObservedLivePane: Equatable {
        let tty: String?
        /// tty 上有本机 claude 进程在跑
        let hasLocalClaude: Bool
        /// tty 上有 ssh 进程在跑（远程会话视为在用，绝不可注入/重建）
        let hasSSH: Bool
    }

    /// 单窗动作
    enum Action: Equatable {
        /// 新建窗口（paneCommands[0] 建窗脚本带入，其余逐 tab 写入）
        case create(commands: [String?])
        /// 向既有活窗注入（仅当窗口在但会话都没在跑）
        case inject(windowID: UInt32, itermWindowASID: String?, commands: [String?])
        /// 会话仍在跑（本地 claude 活 / ssh 挂着），绝不动
        case skipAlive(reason: String)
        /// 无处安放（无显示器等）
        case skipUnplaceable(reason: String)
    }

    struct Item: Equatable {
        let windowIndex: Int
        let action: Action
        /// 解析后的投递目标（create 用）
        let targetYabaiDisplay: Int?
        let targetYabaiSpace: Int?
        let targetFrame: CGRect?
        /// 该窗降级注记（进入汇总台账）
        let notes: [String]
    }

    struct Plan: Equatable {
        var items: [Item]
        /// 拒绝原因（非 nil = 整体不执行）
        var refusal: String?
    }

    /// 空间解析结果
    struct SpaceResolution: Equatable {
        let yabaiDisplay: Int?
        let yabaiSpace: Int?
        let notes: [String]
    }

    // MARK: 规划入口

    static func plan(
        snapshot: SessionRestoreSnapshot,
        existingDisplayIDs: Set<UInt32>,
        displayIDByYabaiIndex: [Int: UInt32],
        primaryDisplayID: UInt32?,
        existingSpaceIndices: Set<Int>,
        visibleSpaceByYabaiDisplay: [Int: Int],
        liveWindows: [ObservedLiveWindow],
        launchCommand: String?,
        frameTolerance: CGFloat = 15
    ) -> Plan {
        guard snapshot.windows.count <= TerminalGridPlanner.maxSnapshotCells else {
            return Plan(items: [], refusal: "快照包含 \(snapshot.windows.count) 个窗口（上限 \(TerminalGridPlanner.maxSnapshotCells)），疑似异常快照，已拒绝恢复以防窗口风暴")
        }
        var usedLiveIDs = Set<UInt32>()
        var items: [Item] = []
        items.reserveCapacity(snapshot.windows.count)

        for (index, window) in snapshot.windows.enumerated() {
            // 显示器解析：记录的 displayID 优先 → yabai 索引映射 → 主屏
            var notes: [String] = []
            let targetDisplayID = resolveDisplay(
                window: window,
                existingDisplayIDs: existingDisplayIDs,
                displayIDByYabaiIndex: displayIDByYabaiIndex,
                primaryDisplayID: primaryDisplayID,
                notes: &notes
            )
            guard let targetDisplayID else {
                items.append(Item(windowIndex: index, action: .skipUnplaceable(reason: "无可用显示器"),
                                  targetYabaiDisplay: nil, targetYabaiSpace: nil, targetFrame: nil, notes: notes))
                continue
            }
            let space = resolveSpace(
                window: window,
                targetDisplayID: targetDisplayID,
                displayIDByYabaiIndex: displayIDByYabaiIndex,
                existingSpaceIndices: existingSpaceIndices,
                visibleSpaceByYabaiDisplay: visibleSpaceByYabaiDisplay,
                notes: &notes
            )
            if window.wasMinimized {
                notes.append("捕获时该窗处于最小化，恢复为普通窗口")
            }

            // 活窗联动：frame 中心就近匹配（同 app）
            let commands = window.panes.map { SessionCommandBuilder.paneCommand($0, launchCommand: launchCommand) }
            let targetFrame = window.frame
            let matched = liveWindows.first { live in
                !usedLiveIDs.contains(live.cgWindowID)
                    && live.appBundleID == window.appBundleID
                    && hypot(live.frame.midX - targetFrame.midX, live.frame.midY - targetFrame.midY) <= frameTolerance
            }
            if let live = matched {
                usedLiveIDs.insert(live.cgWindowID)
                let anyBusy = live.panes.contains { $0.hasLocalClaude || $0.hasSSH }
                if anyBusy {
                    let busyKind = live.panes.contains { $0.hasSSH } ? "远程会话挂线中" : "会话仍在跑"
                    items.append(Item(windowIndex: index, action: .skipAlive(reason: busyKind),
                                      targetYabaiDisplay: space.yabaiDisplay, targetYabaiSpace: space.yabaiSpace,
                                      targetFrame: targetFrame, notes: notes))
                } else {
                    // 活窗但都空闲：按 pane 序注入（多的 pane 忽略）
                    let paneCount = min(commands.count, max(live.panes.count, 1))
                    items.append(Item(
                        windowIndex: index,
                        action: .inject(windowID: live.cgWindowID, itermWindowASID: live.itermWindowASID,
                                        commands: Array(commands.prefix(paneCount))),
                        targetYabaiDisplay: space.yabaiDisplay, targetYabaiSpace: space.yabaiSpace,
                        targetFrame: targetFrame, notes: notes))
                }
                continue
            }
            items.append(Item(
                windowIndex: index,
                action: .create(commands: commands),
                targetYabaiDisplay: space.yabaiDisplay,
                targetYabaiSpace: space.yabaiSpace,
                targetFrame: targetFrame,
                notes: notes
            ))
        }
        return Plan(items: items, refusal: nil)
    }

    // MARK: 解析子决策

    /// 显示器解析：记录 displayID 在场 → 用；yabai 索引能映射 → 用 + 注记；主屏兜底 + 注记
    static func resolveDisplay(
        window: SessionWindowSnapshot,
        existingDisplayIDs: Set<UInt32>,
        displayIDByYabaiIndex: [Int: UInt32],
        primaryDisplayID: UInt32?,
        notes: inout [String]
    ) -> UInt32? {
        if existingDisplayIDs.contains(window.displayID) {
            return window.displayID
        }
        if let yabaiDisplay = window.yabaiDisplay,
           let mapped = displayIDByYabaiIndex[yabaiDisplay], existingDisplayIDs.contains(mapped) {
            notes.append("显示器已变化，按 yabai 屏序映射到当前对应屏")
            return mapped
        }
        if let primaryDisplayID, existingDisplayIDs.contains(primaryDisplayID) {
            notes.append("原显示器不在场，改投主屏")
            return primaryDisplayID
        }
        return nil
    }

    /// 工作区解析：记录 space 仍在 → 用；否则目标屏可见 space + 注记
    static func resolveSpace(
        window: SessionWindowSnapshot,
        targetDisplayID: UInt32,
        displayIDByYabaiIndex: [Int: UInt32],
        existingSpaceIndices: Set<Int>,
        visibleSpaceByYabaiDisplay: [Int: Int],
        notes: inout [String]
    ) -> SpaceResolution {
        let yabaiDisplay = displayIDByYabaiIndex.first { $0.value == targetDisplayID }?.key
        if let space = window.yabaiSpace, existingSpaceIndices.contains(space) {
            return SpaceResolution(yabaiDisplay: yabaiDisplay, yabaiSpace: space, notes: [])
        }
        if let space = window.yabaiSpace {
            notes.append("原工作区 Space \(space) 已不存在")
        }
        if let yabaiDisplay, let visible = visibleSpaceByYabaiDisplay[yabaiDisplay] {
            if window.yabaiSpace != nil {
                notes.append("落到该屏当前工作区 Space \(visible)")
            }
            return SpaceResolution(yabaiDisplay: yabaiDisplay, yabaiSpace: visible, notes: [])
        }
        // yabai 空间信息不可用：窗口只求建出来（落在终端自己的活跃工作区）
        if window.yabaiSpace != nil {
            notes.append("工作区信息不可用，无法精确投递")
        }
        return SpaceResolution(yabaiDisplay: yabaiDisplay, yabaiSpace: nil, notes: [])
    }

    // MARK: 汇总文案

    /// 汇总消息（诚实记账：五类去处 + 降级注记全部交代）
    static func summaryMessage(
        plan: Plan,
        snapshotWindowCount: Int
    ) -> String {
        if let refusal = plan.refusal { return refusal }
        var created = 0
        var injected = 0
        var skippedAlive = 0
        var skippedUnplaceable = 0
        var notes: [String] = []
        for item in plan.items {
            switch item.action {
            case .create: created += 1
            case .inject: injected += 1
            case .skipAlive: skippedAlive += 1
            case .skipUnplaceable: skippedUnplaceable += 1
            }
            notes.append(contentsOf: item.notes)
        }
        let unprocessed = max(0, snapshotWindowCount - plan.items.count)
        var parts: [String] = []
        if created > 0 { parts.append("新建 \(created) 窗") }
        if injected > 0 { parts.append("注入 \(injected) 窗") }
        if skippedAlive > 0 { parts.append("仍活着跳过 \(skippedAlive) 窗") }
        if skippedUnplaceable > 0 { parts.append("无法安放 \(skippedUnplaceable) 窗") }
        if unprocessed > 0 { parts.append("未处理 \(unprocessed) 窗") }
        // 去重注记聚合计数（如 8 窗都"改投主屏"合成一条）
        var noteCounts: [String: Int] = [:]
        for note in notes { noteCounts[note, default: 0] += 1 }
        let noteParts = noteCounts.sorted { $0.key < $1.key }.map { entry in
            entry.value > 1 ? "\(entry.key)（\(entry.value) 窗）" : entry.key
        }
        parts.append(contentsOf: noteParts)
        return parts.isEmpty ? "快照没有可恢复的窗口" : parts.joined(separator: "；")
    }
}
