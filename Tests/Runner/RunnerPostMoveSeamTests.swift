import AppKit
import ApplicationServices.HIServices
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerPostMoveSeamTests.swift
// 靶：move_to_main 收尾（PostMoveEnvironment 注入）——
// 后置 size 校验：无漂移/回读失败/重写一次收敛/重写两次耗尽；
// toggle record 落账：屏上下文推导与字段透传。
// 零 AX 写、零真实睡眠、零记录库写。

final class PostMoveSeamState: @unchecked Sendable {
    var boundsScript: [CGRect?] = []
    var boundsCalls = 0
    var writeCalls = 0
    var settles = 0
    var displayIndex: Int? = 2
    var displayCalls = 0
    var saves: [(
        windowID: UInt32, sourceDisplayIndex: DisplayIdentifier?,
        targetDisplay: Int?, reason: WindowMoveReason, sessionID: String?, singleDisplay: Bool
    )] = []

    func nextBounds() -> CGRect? {
        defer { boundsCalls += 1 }
        if boundsCalls < boundsScript.count { return boundsScript[boundsCalls] }
        return boundsScript.last ?? nil
    }
}

extension RunnerHarness {
    func runPostMoveSeamTests() {
        guard let screen = NSScreen.screens.first else {
            check("postMove A0: 无 NSScreen 环境，跳过", true)
            return
        }
        let state = PostMoveSeamState()
        let ax = AXUIElementCreateSystemWide()
        let target = CGRect(x: 20, y: 20, width: 800, height: 600)
        let drifted = CGRect(x: 20, y: 20, width: 800, height: 1200)
        let identity = WindowIdentity(
            windowID: 6101, pid: 4242, bundleIdentifier: "com.apple.Terminal",
            appName: "Terminal", windowNumber: 6101, title: "t")

        func makeEnv() -> PostMoveEnvironment {
            PostMoveEnvironment(
                cgWindowBounds: { _ in state.nextBounds() },
                writeSize: { _, _ in state.writeCalls += 1 },
                settle: { _ in state.settles += 1 },
                displayYabaiIndex: { _ in
                    state.displayCalls += 1
                    return state.displayIndex
                },
                saveToggleRecord: { _, windowID, _, spaceContext, _, targetDisplay, reason, sessionID, singleDisplay in
                    state.saves.append((
                        windowID, spaceContext.sourceDisplayIndex,
                        targetDisplay, reason, sessionID, singleDisplay))
                }
            )
        }
        func reset() {
            state.boundsScript = []
            state.boundsCalls = 0
            state.writeCalls = 0
            state.settles = 0
            state.displayIndex = 2
            state.displayCalls = 0
            state.saves = []
        }
        let wm = WindowManager.shared

        // A. 无漂移
        reset()
        state.boundsScript = [target]
        _ = wm.verifyAndCorrectPostMoveSize(
            windowAX: ax, windowID: 6101, targetFrame: target,
            origFrame: target, mainScreen: screen, op: "ut-post", environment: makeEnv())
        check("postMove A1: 无漂移 → 不重写不睡眠",
              state.writeCalls == 0 && state.settles == 0)

        // B. 回读失败 → 同样不重写
        reset()
        state.boundsScript = [nil]
        _ = wm.verifyAndCorrectPostMoveSize(
            windowAX: ax, windowID: 6101, targetFrame: target,
            origFrame: target, mainScreen: screen, op: "ut-post", environment: makeEnv())
        check("postMove B1: 回读失败 → 零重写", state.writeCalls == 0)

        // C. 容差内漂移（10 < frameTolerance 20）不触发重写
        reset()
        state.boundsScript = [CGRect(x: 20, y: 20, width: 800, height: 610)]
        _ = wm.verifyAndCorrectPostMoveSize(
            windowAX: ax, windowID: 6101, targetFrame: target,
            origFrame: target, mainScreen: screen, op: "ut-post", environment: makeEnv())
        check("postMove C1: 容差内漂移 → 零重写", state.writeCalls == 0 && state.settles == 0)

        // D. 超容差漂移、第二轮回读收敛
        reset()
        state.boundsScript = [drifted, target]
        _ = wm.verifyAndCorrectPostMoveSize(
            windowAX: ax, windowID: 6101, targetFrame: target,
            origFrame: target, mainScreen: screen, op: "ut-post", environment: makeEnv())
        check("postMove D1: 重写后回读收敛 → 两次写两次 settle",
              state.writeCalls == 2 && state.settles == 2)

        // E. 漂移持续 → 两次重写耗尽（mismatched 出口）
        reset()
        state.boundsScript = [drifted]
        _ = wm.verifyAndCorrectPostMoveSize(
            windowAX: ax, windowID: 6101, targetFrame: target,
            origFrame: target, mainScreen: screen, op: "ut-post", environment: makeEnv())
        check("postMove E1: 两次重写仍漂移 → 停止重试",
              state.writeCalls == 2 && state.settles == 2)

        // F. 记录落账：源屏由 injected 上下文推导
        reset()
        _ = wm.saveToggleRecordForMainMove(
            identity: identity, windowID: 6101, origFrame: target,
            spaceContext: SpaceContext(
                sourceSpaceIndex: .yabaiIndex(3), targetSpaceIndex: nil,
                sourceDisplayIndex: nil, sourceDisplaySpaceIndex: 4),
            targetFrame: target, targetDisplayIndex: 1,
            reason: .manualHotkey, sessionID: "ut-session", op: "ut-post",
            singleDisplay: false, environment: makeEnv())
        check("postMove F1: 记录写入一次并透传目标屏/原因/会话",
              state.saves.count == 1 && state.saves[0].windowID == 6101
              && state.saves[0].targetDisplay == 1
              && state.saves[0].reason == .manualHotkey
              && state.saves[0].sessionID == "ut-session")
        check("postMove F2: 源屏缺失时回退注入屏上下文",
              state.displayCalls == 1 && state.saves[0].sourceDisplayIndex == nil)

        // G. 记录落账：单屏标记与显式源屏透传
        reset()
        _ = wm.saveToggleRecordForMainMove(
            identity: identity, windowID: 6101, origFrame: target,
            spaceContext: SpaceContext(
                sourceSpaceIndex: nil, targetSpaceIndex: nil,
                sourceDisplayIndex: .yabaiIndex(2), sourceDisplaySpaceIndex: nil),
            targetFrame: target, targetDisplayIndex: nil,
            reason: .manualHotkey, sessionID: nil, op: "ut-post",
            singleDisplay: true, environment: makeEnv())
        check("postMove G1: 单屏标记与显式源屏透传",
              state.saves.count == 1 && state.saves[0].singleDisplay
              && state.saves[0].sourceDisplayIndex == DisplayIdentifier.yabaiIndex(2))
    }
}
