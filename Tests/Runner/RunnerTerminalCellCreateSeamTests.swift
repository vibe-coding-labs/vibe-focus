import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerTerminalCellCreateSeamTests.swift
// 靶：TerminalGridController.createTerminalCell 建窗单格全链
// （TerminalCellCreateEnvironment 注入）——终端拉起失败、实例守卫拒绝、
// osascript 挂起快失败、瞬时故障重试耗尽、收敛直返、漂移纠偏、
// CG 定位失败、iTerm 就近匹配路径。零 osascript fork、零真实等待。

final class TerminalCellCreateSeamState: @unchecked Sendable {
    var ready = true
    var refusal: String?
    /// 逐次消费的脚本结果；耗尽后回落 fallbackScript。
    var scriptQueue: [YabaiClient.YabaiResult?] = []
    var scriptCalls = 0
    var fallbackScript: YabaiClient.YabaiResult?
    var sleeps: [UInt64] = []
    var locateCalls = 0
    var locateResult: UInt32?
    var cgBounds: CGRect?
    var placeCalls: [(windowID: UInt32, frame: CGRect, op: String)] = []
    var placeResult = true

    func nextScript() -> YabaiClient.YabaiResult? {
        defer { scriptCalls += 1 }
        if scriptCalls < scriptQueue.count { return scriptQueue[scriptCalls] }
        return fallbackScript
    }
}

final class TerminalCellCreateResultBox: @unchecked Sendable {
    var cgWindowID: UInt32?
    var corrected = false
    var appleScriptID: String?
    var lastError: String?
}

extension RunnerHarness {

    /// async 桥接（同文件内既有 run() 的 Task + 短片泵法，抽成可复用版）。
    private func runMainActorWait<T>(_ block: @escaping @MainActor () async -> T) -> T? {
        final class Box: @unchecked Sendable { var value: T? }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            box.value = await block()
            sem.signal()
        }
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if sem.wait(timeout: .now() + 0.05) == .success { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return box.value
    }

    func runTerminalCellCreateSeamTests() {
        let state = TerminalCellCreateSeamState()
        let target = CGRect(x: 20, y: 20, width: 800, height: 600)
        let terminalID = "com.apple.Terminal"
        let itermID = "com.googlecode.iterm2"

        func ok(_ stdout: String) -> YabaiClient.YabaiResult {
            YabaiClient.YabaiResult(exitCode: 0, stdout: stdout, stderr: "")
        }
        func fail(_ code: Int32 = 1) -> YabaiClient.YabaiResult {
            YabaiClient.YabaiResult(exitCode: code, stdout: "", stderr: "boom")
        }
        func reset() {
            state.ready = true
            state.refusal = nil
            state.scriptQueue = []
            state.scriptCalls = 0
            state.fallbackScript = nil
            state.sleeps = []
            state.locateCalls = 0
            state.locateResult = nil
            state.cgBounds = nil
            state.placeCalls = []
            state.placeResult = true
        }
        func run(bundleID: String = terminalID) -> TerminalCellCreateResultBox {
            let box = TerminalCellCreateResultBox()
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                let env = TerminalCellCreateEnvironment(
                    ensureTerminalRunning: { _, _ in state.ready },
                    instanceRefusal: { _, _ in state.refusal },
                    runScript: { _ in state.nextScript() },
                    sleepNanos: { nanos in state.sleeps.append(nanos) },
                    cgWindowID: { _, _, _ in
                        state.locateCalls += 1
                        return state.locateResult
                    },
                    cgWindowBounds: { _ in state.cgBounds },
                    placeWindow: { windowID, frame, op in
                        state.placeCalls.append((windowID, frame, op))
                        return state.placeResult
                    }
                )
                let controller = TerminalGridController.shared
                let r = await controller.createTerminalCell(
                    appBundleID: bundleID,
                    command: nil,
                    frame: target,
                    op: "ut-cell",
                    environment: env
                )
                box.cgWindowID = r.cgWindowID
                box.corrected = r.corrected
                box.appleScriptID = r.appleScriptID
                box.lastError = controller.lastScriptError
                sem.signal()
            }
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if sem.wait(timeout: .now() + 0.05) == .success { break }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return box
        }

        // A. 终端自动拉起失败
        reset()
        state.ready = false
        let a = run()
        check("cellCreate A1: 终端未就绪 → 建窗中止并带可读错误",
              a.cgWindowID == nil && !a.corrected && a.lastError?.contains("仍未检测到实例") == true)

        // B. 实例守卫拒绝
        reset()
        state.refusal = "多实例拒绝：/tmp/iTerm2 副本"
        let b = run()
        check("cellCreate B1: 守卫拒绝 → 错误透传、零脚本调用",
              b.cgWindowID == nil && b.lastError == "多实例拒绝：/tmp/iTerm2 副本"
              && state.scriptCalls == 0)

        // C. osascript 挂起（nil）→ 快速失败不重试
        reset()
        state.fallbackScript = nil
        let c = run()
        check("cellCreate C1: 脚本挂起 → 单发即失败（不重试）",
              c.cgWindowID == nil && state.scriptCalls == 1 && state.sleeps.isEmpty)

        // D. 瞬时故障重试耗尽
        reset()
        state.fallbackScript = fail()
        let d = run()
        check("cellCreate D1: 三次失败后放弃",
              d.cgWindowID == nil && state.scriptCalls == 3)
        check("cellCreate D2: 重试退避 400ms + 800ms",
              state.sleeps == [400_000_000, 800_000_000])

        // E. 收敛直返：回读/CG 真值 == 目标帧
        reset()
        state.scriptQueue = [ok("777"), ok("20, 20, 820, 620")]
        state.cgBounds = target
        let e = run()
        check("cellCreate E1: 收敛 → 直接返回 CG id 且不纠偏",
              e.cgWindowID == 777 && !e.corrected && e.appleScriptID == "777"
              && state.placeCalls.isEmpty)
        check("cellCreate E2: 建窗后固定格间距睡眠一次",
              state.sleeps == [TerminalGridController.interWindowDelayNanos])

        // F. 漂移 → 纠偏写原语
        reset()
        state.scriptQueue = [ok("777"), ok("20, 20, 820, 620")]
        state.cgBounds = CGRect(x: 200, y: 200, width: 800, height: 600)
        state.placeResult = true
        let f = run()
        check("cellCreate F1: CG 真值漂移 → 走 placeWindow 纠偏",
              f.cgWindowID == 777 && f.corrected
              && state.placeCalls.count == 1 && state.placeCalls[0].windowID == 777)

        // G. 定位失败：非数字 AppleScript id + 就近匹配为空 → CG 定位重试耗尽
        reset()
        state.scriptQueue = [ok("abc"), ok("0, 0, 800, 600")]
        state.locateResult = nil
        let g = run()
        check("cellCreate G1: CG 定位耗尽 → 失败并带定位错误",
              g.cgWindowID == nil && g.lastError?.contains("无法在 CG 窗口列表定位") == true)
        check("cellCreate G2: 定位重试 6 轮、5 段递增退避",
              state.locateCalls == 6
              && state.sleeps == [200_000_000, 400_000_000, 600_000_000,
                                  900_000_000, 1_400_000_000, 2_000_000_000])

        // H. iTerm2 就近匹配路径
        reset()
        state.scriptQueue = [ok("iterm-1"), ok("20, 20, 820, 620")]
        state.locateResult = 555
        state.cgBounds = target
        let h = run(bundleID: itermID)
        check("cellCreate H1: iTerm2 按落点就近匹配拿 CG id",
              h.cgWindowID == 555 && !h.corrected && state.locateCalls == 1
              && h.appleScriptID == "iterm-1")

        // I. runScript 生产体（2026-11-23 补口）：现有用例全走 environment.runScript
        // 注入，真实 osascript fork 的 23-33 段零覆盖。用不触任何 app 的极小脚本
        // （`return 1` / `error "x"`）直调，锁 lastScriptError 双态语义：
        // 每次调用都重写，不携带历史陈旧错误。
        let controller = TerminalGridController.shared
        let savedError = controller.lastScriptError
        defer { controller.lastScriptError = savedError }

        controller.lastScriptError = "陈旧错误（应被覆盖）"
        let okResult = runMainActorWait { await controller.runScript("return 1") }
        check("cellCreate I1: 成功脚本 → lastScriptError 被清空（不携陈旧错误）",
              okResult != nil && okResult?.exitCode == 0
              && controller.lastScriptError == nil)

        let failResult = runMainActorWait { await controller.runScript("error \"vf-ut-boom\"") }
        check("cellCreate I2: 失败脚本 → lastScriptError 反映本次错误",
              failResult != nil && failResult?.exitCode != 0
              && controller.lastScriptError?.isEmpty == false)
    }
}
