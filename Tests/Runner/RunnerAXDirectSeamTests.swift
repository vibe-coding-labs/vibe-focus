import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerAXDirectSeamTests.swift
// 靶：WindowManager.moveWindowToFrameViaAX 全链（AXDirectMoveEnvironment 注入）——
// owner pid 缺失、AX 窗口数组缺失、AX 窗口不匹配、属性不可写、写序执行与收敛
// 验证（收敛/不收敛）。零 AX 写入、零窗口移动、零真实等待。

final class AXDirectSeamState: @unchecked Sendable {
    var pid: Int32? = 4242
    var windows: [AXUIElement]? = []
    var matched = true
    var settable = true
    var currentFrame: CGRect?
    var moveWrites = 0
    var resizeWrites = 0
}

extension RunnerHarness {
    func runAXDirectSeamTests() {
        let state = AXDirectSeamState()
        let fakeAX = AXUIElementCreateSystemWide()
        state.windows = [fakeAX]

        let env = AXDirectMoveEnvironment(
            ownerPID: { _ in state.pid },
            axWindows: { _ in state.windows },
            matchAXWindow: { _, _ in state.matched ? fakeAX : nil },
            isSettable: { _, _ in state.settable },
            cgWindowBounds: { _ in state.currentFrame },
            writeMove: { _, _ in state.moveWrites += 1 },
            writeResize: { _, _ in state.resizeWrites += 1 },
            pollSleep: { _ in })

        let wm = WindowManager.shared
        let source = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let target = CGRect(x: 10, y: 20, width: 500, height: 400)
        func run() -> Bool {
            wm.moveWindowToFrameViaAX(
                windowID: 7001, frame: target, op: "ut-ax", stage: "ut",
                sourceVisibleFrame: source, environment: env)
        }

        // A. owner pid 缺失
        state.pid = nil
        check("axDirectSeam A1: owner pid 缺失 → false", run() == false)
        state.pid = 4242

        // B. AX 窗口数组缺失
        state.windows = nil
        check("axDirectSeam B1: AX windows 不可用 → false", run() == false)
        state.windows = [fakeAX]

        // C. AX 窗口不匹配
        state.matched = false
        check("axDirectSeam C1: AX 窗口匹配失败 → false", run() == false)
        state.matched = true

        // D. 属性不可写
        state.settable = false
        check("axDirectSeam D1: 属性不可写 → false", run() == false)
        state.settable = true

        // E. 收敛成功：写原语逐段推进 readback 到目标
        state.currentFrame = source
        state.moveWrites = 0
        state.resizeWrites = 0
        // 写原语把 readback 置为「本段已生效」的中间态/终态
        let convergingEnv = AXDirectMoveEnvironment(
            ownerPID: { _ in 4242 },
            axWindows: { _ in [fakeAX] },
            matchAXWindow: { _, _ in fakeAX },
            isSettable: { _, _ in true },
            cgWindowBounds: { _ in state.currentFrame },
            writeMove: { _, _ in
                state.moveWrites += 1
                state.currentFrame = target
            },
            writeResize: { _, _ in
                state.resizeWrites += 1
                state.currentFrame = CGRect(x: 0, y: 0, width: 500, height: 800)
            },
            pollSleep: { _ in })
        state.currentFrame = source
        let converged = wm.moveWindowToFrameViaAX(
            windowID: 7001, frame: target, op: "ut-ax", stage: "ut",
            sourceVisibleFrame: source, environment: convergingEnv)
        check("axDirectSeam E1: 两段写入后收敛 → true", converged == true)
        check("axDirectSeam E2: 收窄场景先 resize 后 move（两段都执行）",
              state.resizeWrites >= 1 && state.moveWrites >= 1)

        // F. 不收敛：写原语不改 readback → 如实 false（预算内轮询后放弃）
        state.currentFrame = source
        state.moveWrites = 0
        state.resizeWrites = 0
        let stuckEnv = AXDirectMoveEnvironment(
            ownerPID: { _ in 4242 },
            axWindows: { _ in [fakeAX] },
            matchAXWindow: { _, _ in fakeAX },
            isSettable: { _, _ in true },
            cgWindowBounds: { _ in state.currentFrame },
            writeMove: { _, _ in state.moveWrites += 1 },
            writeResize: { _, _ in state.resizeWrites += 1 },
            pollSleep: { _ in })
        let stuck = wm.moveWindowToFrameViaAX(
            windowID: 7001, frame: target, op: "ut-ax", stage: "ut",
            sourceVisibleFrame: source, environment: stuckEnv)
        check("axDirectSeam F1: 写不生效 → false（不谎报成功）", stuck == false)
        check("axDirectSeam F2: 收敛失败前确有写尝试",
              state.resizeWrites + state.moveWrites >= 1)
    }
}
