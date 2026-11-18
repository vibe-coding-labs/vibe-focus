import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerInputBubbleTickSeamTests.swift
// 靶：InputBubbleAutoShow.tick 编排（InputBubbleAutoShowEnvironment 注入）——
// 焦点门 summon / 各 skip 态（未开启、气泡占用、非终端、同窗、无活跃绑定）、
// 跨屏到达门（hookPull 直弹、userAction 看绑定、外部移动静默）、
// 气泡开着时到达窗改绑/自动隐藏保持/同窗保持、基线落账与崩溃记账。
// 零真面板、零 CGWindowList、零数据库读。

final class InputBubbleTickSeamState: @unchecked Sendable {
    var frontIsTerminal = true
    var frontName: String? = "iTerm2"
    var frontBundleID: String? = "com.googlecode.iterm2"
    var windows: [CGWindowEntry] = []
    var idle = true
    var targetWindowID: UInt32?
    var autoShowOnFocus = true
    var autoShowOnMoveToMain = true
    var autoHide = false
    var live: Set<UInt32> = []
    var movers: [UInt32: InputBubbleArrivalMover] = [:]
    var summons = 0
    var movedSummons: [(windowID: UInt32, pid: pid_t, appName: String?)] = []
    var retargets: [(windowID: UInt32, pid: pid_t, appName: String?)] = []
    var crashes: [String] = []

    func reset() {
        frontIsTerminal = true
        frontName = "iTerm2"
        frontBundleID = "com.googlecode.iterm2"
        windows = []
        idle = true
        targetWindowID = nil
        autoShowOnFocus = true
        autoShowOnMoveToMain = true
        autoHide = false
        live = []
        movers = [:]
        summons = 0
        movedSummons = []
        retargets = []
        crashes = []
    }
}

extension RunnerHarness {
    func runInputBubbleTickSeamTests() {
        let ownApp = NSRunningApplication(processIdentifier: ProcessInfo.processInfo.processIdentifier)
        guard let front = ownApp ?? NSWorkspace.shared.frontmostApplication else {
            check("inputBubbleTick A0: 无前台应用环境，跳过", true)
            return
        }
        let frontPID = front.processIdentifier
        let state = InputBubbleTickSeamState()
        let show = InputBubbleAutoShow.shared

        func entry(_ id: UInt32, onMain: Bool) -> CGWindowEntry {
            CGWindowEntry(from: [
                kCGWindowNumber as String: id,
                kCGWindowOwnerPID as String: frontPID,
                kCGWindowLayer as String: 0,
                kCGWindowIsOnscreen as String: true,
                kCGWindowBounds as String: [
                    "X": onMain ? CGFloat(0) : CGFloat(5000),
                    "Y": CGFloat(0), "Width": CGFloat(800), "Height": CGFloat(600),
                ],
            ])!
        }
        func environment() -> InputBubbleAutoShowEnvironment {
            InputBubbleAutoShowEnvironment(
                frontmostApp: { front },
                frontIdentity: {
                    InputBubbleAutoShowEnvironment.FrontIdentity(
                        name: state.frontName, bundleID: state.frontBundleID)
                },
                cgWindows: { state.windows },
                isOnMainScreen: { $0.minX < 5000 },
                isIdle: { state.idle },
                targetWindowID: { state.targetWindowID },
                summon: { state.summons += 1 },
                summonForMovedWindow: { id, pid, name in
                    state.movedSummons.append((id, pid, name))
                },
                retargetForMovedWindow: { id, pid, name in
                    state.retargets.append((id, pid, name))
                },
                hasLiveSessionBinding: { state.live.contains($0) },
                recentMover: { state.movers[$0] },
                preferences: {
                    InputBubbleAutoShowEnvironment.Preferences(
                        autoShowOnFocus: state.autoShowOnFocus,
                        autoShowOnMoveToMain: state.autoShowOnMoveToMain,
                        autoHide: state.autoHide)
                },
                recordCrashEvent: { state.crashes.append($0) }
            )
        }
        func tick() { show.tick(environment: environment()) }

        // A. 焦点门 summon：首次见到终端窗且挂活跃会话 → 弹一次
        state.reset()
        state.windows = [entry(8001, onMain: true)]
        state.live = [8001]
        tick()
        check("inputBubbleTick A1: 终端窗有活跃会话 → summon 一次", state.summons == 1)
        check("inputBubbleTick A2: summon 落崩溃归因账", state.crashes == ["input_bubble_autoshow windowID=8001"])
        check("inputBubbleTick A3: 焦点门 summon 不走到达弹窗", state.movedSummons.isEmpty)

        // A4. 同窗再观测 → skipSameWindow 不重复弹
        tick()
        check("inputBubbleTick A4: 同窗二次 tick 不重复弹", state.summons == 1)

        // B. 气泡占用（非 idle）→ 整体冻结
        state.reset()
        state.windows = [entry(8002, onMain: true)]
        state.live = [8002]
        state.idle = false
        tick()
        check("inputBubbleTick B1: 气泡占用时不弹", state.summons == 0 && state.movedSummons.isEmpty)

        // C. 自动弹出开关关闭 → 焦点门不弹
        state.reset()
        state.windows = [entry(8003, onMain: true)]
        state.live = [8003]
        state.autoShowOnFocus = false
        tick()
        check("inputBubbleTick C1: 开关关闭时焦点门不弹", state.summons == 0)

        // D. 前台非终端 → 清 lastSeen（回到会话窗会重新弹出）
        state.reset()
        state.frontIsTerminal = false
        state.frontName = "Safari"
        state.frontBundleID = "com.apple.Safari"
        state.windows = [entry(8004, onMain: true)]
        state.live = [8004]
        tick()
        check("inputBubbleTick D1: 前台非终端不弹", state.summons == 0)
        state.frontIsTerminal = true
        state.frontName = "iTerm2"
        state.frontBundleID = "com.googlecode.iterm2"
        tick()
        check("inputBubbleTick D2: 回到同一会话窗重新弹出（lastSeen 已清）", state.summons == 1)

        // E. 无活跃会话绑定 → 不弹；之后绑定出现但同窗仍不弹
        state.reset()
        state.windows = [entry(8005, onMain: true)]
        tick()
        check("inputBubbleTick E1: 无活跃绑定不弹", state.summons == 0)
        state.live = [8005]
        tick()
        check("inputBubbleTick E2: 同窗补上绑定仍不弹（窗口未变化）", state.summons == 0)

        // F. 跨屏到达：hookPull 直弹
        state.reset()
        state.autoShowOnFocus = false
        state.windows = [entry(8006, onMain: false)]
        tick()
        check("inputBubbleTick F1: 非主屏首观测只落基线不弹", state.movedSummons.isEmpty)
        state.windows = [entry(8006, onMain: true)]
        state.movers[8006] = .hookPull
        tick()
        check("inputBubbleTick F2: hookPull 到达 → summonForMovedWindow 带窗口/pid/应用名",
              state.movedSummons.count == 1 && state.movedSummons[0].windowID == 8006
              && state.movedSummons[0].pid == frontPID && state.movedSummons[0].appName == "iTerm2")
        check("inputBubbleTick F3: 到达弹窗落崩溃归因账",
              state.crashes == ["input_bubble_autoshow_move windowID=8006"])

        // G. 到达 + userAction + 活跃绑定 → 弹
        state.reset()
        state.autoShowOnFocus = false
        state.windows = [entry(8007, onMain: false)]
        tick()
        state.windows = [entry(8007, onMain: true)]
        state.movers[8007] = .userAction
        state.live = [8007]
        tick()
        check("inputBubbleTick G1: 用户拉回且窗挂活跃会话 → 弹",
              state.movedSummons.count == 1 && state.movedSummons[0].windowID == 8007)

        // H. 到达 + userAction + 无绑定 → 静默
        state.reset()
        state.autoShowOnFocus = false
        state.windows = [entry(8008, onMain: false)]
        tick()
        state.windows = [entry(8008, onMain: true)]
        state.movers[8008] = .userAction
        tick()
        check("inputBubbleTick H1: 用户拉回但无活跃会话 → 不弹", state.movedSummons.isEmpty)

        // I. 外部移动（无归因记录）→ 静默
        state.reset()
        state.autoShowOnFocus = false
        state.windows = [entry(8009, onMain: false)]
        tick()
        state.windows = [entry(8009, onMain: true)]
        state.live = [8009]
        tick()
        check("inputBubbleTick I1: 外部移动无归因 → 不弹", state.movedSummons.isEmpty)

        // J. 到达时气泡开着 + 跟随模式 + 目标窗不同 → 改绑
        state.reset()
        state.autoShowOnFocus = false
        state.idle = false
        state.targetWindowID = 8999
        state.windows = [entry(8010, onMain: false)]
        tick()
        state.windows = [entry(8010, onMain: true)]
        state.movers[8010] = .hookPull
        tick()
        check("inputBubbleTick J1: 气泡开着跟随模式 → 改绑到到达窗",
              state.retargets.count == 1 && state.retargets[0].windowID == 8010
              && state.movedSummons.isEmpty)

        // K. 到达时气泡开着 + 自动隐藏 → 保持不动
        state.reset()
        state.autoShowOnFocus = false
        state.idle = false
        state.autoHide = true
        state.targetWindowID = 8999
        state.windows = [entry(8011, onMain: false)]
        tick()
        state.windows = [entry(8011, onMain: true)]
        state.movers[8011] = .hookPull
        tick()
        check("inputBubbleTick K1: 自动隐藏模式不打扰当前气泡", state.retargets.isEmpty)

        // L. 到达窗就是气泡当前窗 → 保持不动
        state.reset()
        state.autoShowOnFocus = false
        state.idle = false
        state.targetWindowID = 8012
        state.windows = [entry(8012, onMain: false)]
        tick()
        state.windows = [entry(8012, onMain: true)]
        state.movers[8012] = .hookPull
        tick()
        check("inputBubbleTick L1: 到达窗即当前绑定窗 → 不改绑", state.retargets.isEmpty)

        // M. 移动开关关闭 → 到达门整体不弹
        state.reset()
        state.autoShowOnFocus = false
        state.autoShowOnMoveToMain = false
        state.windows = [entry(8013, onMain: false)]
        tick()
        state.windows = [entry(8013, onMain: true)]
        state.movers[8013] = .hookPull
        tick()
        check("inputBubbleTick M1: 移动自动弹出开关关闭 → 不弹不改绑",
              state.movedSummons.isEmpty && state.retargets.isEmpty)

        // N. 非目标 window 的到达不影响（多窗并扫，只弹真正跨越的那扇）
        state.reset()
        state.autoShowOnFocus = false
        state.windows = [entry(8014, onMain: true), entry(8015, onMain: false)]
        tick()
        state.windows = [entry(8014, onMain: true), entry(8015, onMain: true)]
        state.movers[8015] = .hookPull
        tick()
        check("inputBubbleTick N1: 多窗扫描只弹跨越到主屏的窗",
              state.movedSummons.count == 1 && state.movedSummons[0].windowID == 8015)
    }
}
