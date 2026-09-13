import AppKit
import CoreGraphics
import Foundation

// MARK: - 会话恢复执行器
/// 消费 SessionRestorePlanner 的计划：按（显示器 × 工作区）分组「切视角 → 建窗 →
/// 跨 Space 投递」，活窗空闲 pane 注入，结束时归还原视角。跨 Space 投递走真机
/// 验证过的「泊到另一屏 → 写回目标格位」通道（yabai --space 在无 SA 环境静默
/// 失效，见 TerminalGridController+SpaceDelivery 注记）。
@MainActor
final class SessionRestoreExecutor {

    private let controller: SessionRestoreController

    init(controller: SessionRestoreController) {
        self.controller = controller
    }

    func restore(snapshot: SessionRestoreSnapshot) async -> TerminalGridController.OperationResult {
        let op = makeOperationID(prefix: "session-restore")

        // 1. 实例环境守卫（快照里出现过的每个终端都验；未运行放行冷拉起）
        for bundleID in Set(snapshot.windows.map(\.appBundleID)) {
            if let refusal = TerminalGridController.shared.automationInstanceRefusal(appBundleID: bundleID, allowNotRunning: true) {
                log("[SessionRestore] restore refused by instance guard", level: .warn, fields: [
                    "op": op, "app": bundleID
                ])
                return TerminalGridController.OperationResult(ok: false, message: refusal)
            }
        }
        // 冷拉起未运行的终端（建窗 AE 前置；失败继续——守卫链会兜住）
        for bundleID in Set(snapshot.windows.map(\.appBundleID)) {
            _ = await TerminalGridController.shared.ensureTerminalRunning(appBundleID: bundleID, op: op)
        }

        // 2. 环境真值采集
        let spaces = SpaceController.shared.querySpaces(ignoreCache: true) ?? []
        let existingSpaceIndices = Set(spaces.compactMap(\.index))
        var visibleSpaceByYabaiDisplay: [Int: Int] = [:]
        for space in spaces where space.isVisible == true {
            if let display = space.display, let index = space.index {
                visibleSpaceByYabaiDisplay[display] = index
            }
        }
        var displayIDByYabaiIndex: [Int: UInt32] = [:]
        for screen in NSScreen.screens {
            if let yabaiIndex = SpaceController.shared.exactYabaiDisplayIndex(for: screen),
               let cgID = CoordinateKit.cgDisplayID(for: screen) {
                displayIDByYabaiIndex[yabaiIndex] = cgID
            }
        }
        let existingDisplayIDs = Set(displayIDByYabaiIndex.values)
        let primaryDisplayID = NSScreen.screens.first { $0.frame.origin == .zero }
            .flatMap { CoordinateKit.cgDisplayID(for: $0) }

        // 3. 活窗观测（会话在跑的绝不动）
        let liveWindows = await observeLiveWindows()
        let plan = SessionRestorePlanner.plan(
            snapshot: snapshot,
            existingDisplayIDs: existingDisplayIDs,
            displayIDByYabaiIndex: displayIDByYabaiIndex,
            primaryDisplayID: primaryDisplayID,
            existingSpaceIndices: existingSpaceIndices,
            visibleSpaceByYabaiDisplay: visibleSpaceByYabaiDisplay,
            liveWindows: liveWindows,
            launchCommand: snapshot.launchCommand
        )
        if let refusal = plan.refusal {
            return TerminalGridController.OperationResult(ok: false, message: refusal)
        }
        log("[SessionRestore] restore plan", fields: [
            "op": op,
            "live": String(liveWindows.count),
            "items": String(plan.items.count),
        ])

        // 4. 分组执行：create 按（屏 × 工作区）分组「切视角 → 建窗 → 投递」；inject 直写
        var claimedIDs = Set<UInt32>()
        var deliveryFailures = 0
        var injectFailures = 0
        let originalVisibleSpaces = visibleSpaceByYabaiDisplay
        var switchedSpaces = false

        let createItems = plan.items.filter { item in
            if case .create = item.action { return true }
            return false
        }
        // 分组键序 = 首次出现序（保持快照阅读序）
        var groupOrder: [String] = []
        var groups: [String: [SessionRestorePlanner.Item]] = [:]
        for item in createItems {
            let key = "\(item.targetYabaiDisplay ?? -1):\(item.targetYabaiSpace ?? -1)"
            if groups[key] == nil { groupOrder.append(key) }
            groups[key, default: []].append(item)
        }

        for key in groupOrder {
            let items = groups[key]!
            guard let first = items.first, first.targetFrame != nil else { continue }
            // 切视角：目标工作区可见是投递通道的前置（写回时目标屏正显示目标 space）
            if let space = first.targetYabaiSpace,
               let displayIndex = first.targetYabaiDisplay,
               originalVisibleSpaces[displayIndex] != space {
                let focused = SpaceController.shared.focusSpace(.yabai(space), operationID: op)
                if focused { switchedSpaces = true }
                await settleVisibleSpace(space, budgetSeconds: 2.0)
            }
            for item in items {
                guard case .create(let commands) = item.action, let frame = item.targetFrame else { continue }
                let appBundleID = snapshot.windows[item.windowIndex].appBundleID
                let placement = await TerminalGridController.shared.createTerminalCell(
                    appBundleID: appBundleID,
                    command: commands.first ?? nil,
                    frame: frame,
                    op: op,
                    excluding: claimedIDs
                )
                if let cgID = placement.cgWindowID {
                    claimedIDs.insert(cgID)
                    // 附加 pane：iTerm2 追加 tab（AppleScript id 定位）；Terminal 逐条 do script in window
                    let extras = Array(commands.dropFirst().compactMap { $0 })
                    for (extraIndex, command) in extras.enumerated() {
                        _ = extraIndex
                        let script: String?
                        if TerminalAutomationScript.usesITermDialect(appBundleID), let asid = placement.appleScriptID {
                            script = PaneEnumeration.itermAppendTab(windowASID: asid, command: command)
                        } else {
                            script = PaneEnumeration.terminalWriteToWindow(windowCGID: cgID, command: command)
                        }
                        if let script {
                            _ = await runAppleScript(script)
                        }
                        try? await Task.sleep(nanoseconds: TerminalGridController.interWindowDelayNanos)
                    }
                    // 投递校验与纠偏（含泊靠往返）
                    if let space = item.targetYabaiSpace {
                        let delivered = await deliver(windowID: cgID, frame: frame, space: space, displayIndex: item.targetYabaiDisplay, op: op)
                        if !delivered { deliveryFailures += 1 }
                    }
                }
            }
        }

        for item in plan.items {
            guard case .inject(let windowID, let itermASID, let commands) = item.action else { continue }
            let appBundleID = snapshot.windows[item.windowIndex].appBundleID
            let livePaneCoords = liveWindows.first { $0.cgWindowID == windowID }?.paneCoords ?? [:]
            for (paneIndex, command) in commands.enumerated() {
                guard let command else { continue }
                var script: String?
                if TerminalAutomationScript.usesITermDialect(appBundleID) {
                    if let itermASID {
                        if let coord = livePaneCoords[paneIndex] {
                            script = PaneEnumeration.itermWriteToSession(
                                windowASID: itermASID, tabIndex: coord.tabIndex, sessionIndex: coord.sessionIndex, command: command)
                        } else {
                            script = PaneEnumeration.itermWriteToWindow(windowASID: itermASID, command: command)
                        }
                    }
                } else {
                    script = PaneEnumeration.terminalWriteToWindow(windowCGID: windowID, command: command)
                }
                if let script {
                    let output = await runAppleScript(script)
                    if output == nil { injectFailures += 1 }
                    try? await Task.sleep(nanoseconds: TerminalGridController.interWindowDelayNanos)
                } else {
                    injectFailures += 1
                }
            }
        }

        // 5. 归还原视角（有切换才还）
        if switchedSpaces {
            if let (_, space) = originalVisibleSpaces.sorted(by: { $0.key < $1.key }).first {
                _ = SpaceController.shared.focusSpace(.yabai(space), operationID: op)
                // 只还主活动屏的原视角即可，逐屏切换反而折腾
            }
        }

        var message = SessionRestorePlanner.summaryMessage(plan: plan, snapshotWindowCount: snapshot.windows.count)
        if deliveryFailures > 0 {
            message += "；\(deliveryFailures) 窗未能送达目标工作区（已落在该屏当前工作区）"
        }
        if injectFailures > 0 {
            message += "；\(injectFailures) 条注入命令执行失败"
        }
        log("[SessionRestore] restore done", fields: [
            "op": op, "claimed": String(claimedIDs.count),
            "deliveryFailures": String(deliveryFailures), "injectFailures": String(injectFailures),
        ])
        return TerminalGridController.OperationResult(ok: true, message: message)
    }

    // MARK: 活窗观测

    /// 当前全部终端活窗（含 pane 存活形态）。枚举失败 / tty 不可读的 pane 按
    /// 「无会话」处理（恢复语义宁可注入也不盲跳？不——busy 判据按 pane 有 tty
    /// 且探到进程才算，读不到 tty 的 pane 不阻塞 skip 判定，但活窗匹配本身仍生效）。
    private func observeLiveWindows() async -> [SessionRestorePlanner.ObservedLiveWindow] {
        guard let allWindows = SpaceController.shared.queryAllWindows() else { return [] }
        let terminalWindows = allWindows.filter {
            SessionRestoreController.isCapturableYabaiWindow($0, bundleIDOf: { pid in
                NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            })
        }
        guard !terminalWindows.isEmpty else { return [] }
        let hasIterm = terminalWindows.contains { $0.app == "iTerm2" }
        let hasAppleTerminal = terminalWindows.contains { $0.app == "Terminal" }
        var itermEntries: [ITermSessionEntry] = []
        if hasIterm {
            itermEntries = await runAppleScript(PaneEnumeration.itermEnumerateSessions())
                .map { PaneEnumeration.parseITermSessions($0) } ?? []
        }
        var terminalTTYs: [UInt32: [String]] = [:]
        if hasAppleTerminal {
            terminalTTYs = await runAppleScript(TerminalAutomationScript.terminalEnumerateWindowTTYs())
                .map { PaneEnumeration.parseTerminalTabTTYs($0) } ?? [:]
        }
        let skeletons = SessionRestoreController.joinPanes(
            yabaiWindows: terminalWindows, itermEntries: itermEntries, terminalTTYs: terminalTTYs)

        var result: [SessionRestorePlanner.ObservedLiveWindow] = []
        for skeleton in skeletons {
            var panes: [SessionRestorePlanner.ObservedLivePane] = []
            var coords: [Int: SessionRestorePlanner.PaneCoord] = [:]
            for (paneIndex, pane) in skeleton.panes.enumerated() {
                var hasClaude = false
                var hasSSH = false
                if let tty = pane.tty {
                    let cls = SessionRestoreController.classifyTTY(tty)
                    hasClaude = cls.kind == .localClaude
                    hasSSH = cls.kind == .remoteSSH
                }
                if let tabIndex = pane.tabIndex, let sessionIndex = pane.sessionIndex {
                    coords[paneIndex] = SessionRestorePlanner.PaneCoord(tabIndex: tabIndex, sessionIndex: sessionIndex)
                }
                panes.append(SessionRestorePlanner.ObservedLivePane(tty: pane.tty, hasLocalClaude: hasClaude, hasSSH: hasSSH))
            }
            result.append(SessionRestorePlanner.ObservedLiveWindow(
                cgWindowID: skeleton.cgWindowID,
                frame: skeleton.frame,
                appBundleID: skeleton.appBundleID,
                itermWindowASID: skeleton.itermWindowASID,
                panes: panes,
                paneCoords: coords
            ))
        }
        return result
    }

    // MARK: 跨 Space 投递（泊靠往返通道）

    /// 交付判定 + 纠偏：已在对的 space → 原样；错位 → 泊靠往返写回
    /// （前置：目标屏正显示目标 space——分组循环里已切视角）。
    private func deliver(windowID: UInt32, frame: CGRect, space: Int, displayIndex: Int?, op: String) async -> Bool {
        guard let info = SpaceController.shared.queryWindow(windowID: windowID, ignoreCache: true) else {
            return false
        }
        if info.space == space { return true }
        // AX 引用懒建立（新建窗 1-3s）：未建立时 float/move 全部静默失效
        let axDeadline = Date().addingTimeInterval(3)
        var axReady = false
        while Date() < axDeadline {
            if SpaceController.shared.queryWindow(windowID: windowID, ignoreCache: true)?.isManageableByYabai == true {
                axReady = true
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard axReady else {
            log("[SessionRestore] delivery skip: window never became yabai-managed", level: .warn, fields: [
                "op": op, "windowID": String(windowID)
            ])
            return false
        }
        _ = SpaceController.shared.setWindowFloat(windowID, operationID: op)
        // 泊靠屏：目标屏之外的任一屏（跨屏 frame 直写必入目标屏当前可见 space）
        if let parkingScreen = NSScreen.screens.first(where: {
            SpaceController.shared.exactYabaiDisplayIndex(for: $0) != displayIndex
        }), info.display == displayIndex {
            // 同屏错位：先泊到其它屏，再写回（此刻目标屏正显示目标 space）
            let parkingBase = CoordinateKit.quartzVisibleFrame(of: parkingScreen)
            _ = SpaceController.shared.runYabai(
                arguments: ["-m", "window", "\(windowID)", "--move", "abs:\(Int(parkingBase.minX + 40)):\(Int(parkingBase.minY + 40))"],
                operation: "session-delivery.park(windowID=\(windowID))", operationID: op
            )
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        _ = SpaceController.shared.runYabai(
            arguments: ["-m", "window", "\(windowID)", "--move", "abs:\(Int(frame.origin.x)):\(Int(frame.origin.y))"],
            operation: "session-delivery.writeback.move(windowID=\(windowID))", operationID: op
        )
        _ = SpaceController.shared.runYabai(
            arguments: ["-m", "window", "\(windowID)", "--resize", "abs:\(Int(frame.width)):\(Int(frame.height))"],
            operation: "session-delivery.writeback.resize(windowID=\(windowID))", operationID: op
        )
        // 轮询确认到位
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if SpaceController.shared.queryWindow(windowID: windowID, ignoreCache: true)?.space == space {
                return true
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return false
    }

    // MARK: 辅助

    private func settleVisibleSpace(_ space: Int, budgetSeconds: Double) async {
        let deadline = Date().addingTimeInterval(budgetSeconds)
        while Date() < deadline {
            if let spaces = SpaceController.shared.querySpaces(ignoreCache: true),
               spaces.first(where: { $0.index == space })?.isVisible == true {
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func runAppleScript(_ script: String) async -> String? {
        await controller.runAppleScript(script)
    }
}
