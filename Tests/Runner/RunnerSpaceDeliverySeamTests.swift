import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerSpaceDeliverySeamTests.swift
// 靶：TerminalGridController.deliverCellsToTargetSpace 建窗后 Space 投递全链
// （SpaceDeliveryEnvironment 注入）——目标解析/屏映射/泊位缺失、跨屏直写、
// 同屏往返 park、AX 就绪轮询超时跳过、视角漂移 refocus、帧数截断。
// 虚拟时钟推进睡眠预算，零真实等待、零 yabai fork、零窗口移动。

final class SpaceDeliverySeamState: @unchecked Sendable {
    var screen: NSScreen?
    var targetSpace: Int? = 2
    var displayIndex: Int? = 1
    var parkingScreen: NSScreen?
    var parkingFrame = CGRect(x: 1440, y: 0, width: 1440, height: 900)
    /// 逐次消费的可见 space 序列；耗尽后沿用最后一个值。
    var visibleScript: [Int?] = [2, 2]
    var visibleCalls = 0
    /// 逐次消费的查询结果序列；耗尽后回落到 fallbackInfo。
    var queryScript: [YabaiWindowInfo?] = []
    var queryCalls = 0
    var fallbackInfo: YabaiWindowInfo?
    var refocusCalls: [(space: Int, op: String)] = []
    var floatCalls: [UInt32] = []
    var yabaiCalls: [(args: [String], operation: String)] = []
    var sleeps: [UInt64] = []
    var clock = Date(timeIntervalSince1970: 1_000_000)

    func nextVisible() -> Int? {
        defer { visibleCalls += 1 }
        if visibleCalls < visibleScript.count { return visibleScript[visibleCalls] }
        return visibleScript.last ?? nil
    }

    func nextQuery() -> YabaiWindowInfo? {
        defer { queryCalls += 1 }
        if queryCalls < queryScript.count { return queryScript[queryCalls] }
        return fallbackInfo
    }
}

final class SpaceDeliveryResultBox: @unchecked Sendable {
    var attempted = -1
    var delivered = -1
    var parkingUnavailable = false
}

extension RunnerHarness {
    func runSpaceDeliverySeamTests() {
        guard let screen = NSScreen.screens.first else {
            check("spaceDelivery A0: 无 NSScreen 环境，跳过实屏用例", true)
            return
        }
        let state = SpaceDeliverySeamState()
        state.screen = screen
        state.parkingScreen = screen

        func info(space: Int, display: Int, manageable: Bool) -> YabaiWindowInfo {
            YabaiWindowInfo(
                id: 9101, pid: 4242, app: "Terminal", title: "t",
                space: space, display: display,
                frame: YabaiWindowInfo.Frame(x: 0, y: 0, w: 800, h: 600),
                isFloatingRaw: false, hasAXReferenceRaw: manageable
            )
        }

        func reset() {
            state.targetSpace = 2
            state.displayIndex = 1
            state.parkingScreen = screen
            state.visibleScript = [2, 2]
            state.visibleCalls = 0
            state.queryScript = []
            state.queryCalls = 0
            state.fallbackInfo = nil
            state.refocusCalls = []
            state.floatCalls = []
            state.yabaiCalls = []
            state.sleeps = []
            state.clock = Date(timeIntervalSince1970: 1_000_000)
        }

        func run(windowIDs: [UInt32], frames: [CGRect]) -> SpaceDeliveryResultBox {
            let box = SpaceDeliveryResultBox()
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                let screenValue = state.screen!
                let env = SpaceDeliveryEnvironment(
                    targetSpaceIndex: { state.targetSpace },
                    displayIndexForScreen: { _ in state.displayIndex },
                    parkingScreen: { _ in state.parkingScreen },
                    quartzVisibleFrame: { _ in state.parkingFrame },
                    queryWindow: { _ in state.nextQuery() },
                    refocusOnSpace: { space, op in state.refocusCalls.append((space, op)) },
                    setFloat: { windowID, _ in state.floatCalls.append(windowID) },
                    runYabai: { args, operation in state.yabaiCalls.append((args, operation)) },
                    activeSpaceIndex: { _ in state.nextVisible() },
                    sleepNanos: { nanos in
                        state.sleeps.append(nanos)
                        state.clock = state.clock.addingTimeInterval(Double(nanos) / 1_000_000_000)
                    },
                    now: { state.clock }
                )
                let r = await TerminalGridController.shared.deliverCellsToTargetSpace(
                    windowIDs: windowIDs,
                    frames: frames,
                    screen: screenValue,
                    op: "ut-delivery",
                    environment: env
                )
                box.attempted = r.attempted
                box.delivered = r.delivered
                box.parkingUnavailable = r.parkingUnavailable
                sem.signal()
            }
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if sem.wait(timeout: .now() + 0.05) == .success { break }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return box
        }

        let cell = CGRect(x: 20, y: 20, width: 800, height: 600)

        // A. 非显式 space 目标（解析不出 displaySpace）
        reset()
        state.targetSpace = nil
        let a = run(windowIDs: [9101], frames: [cell])
        check("spaceDelivery A1: 无显式 space 目标 → (0,0,false) 且零副作用",
              a.attempted == 0 && a.delivered == 0 && !a.parkingUnavailable
              && state.yabaiCalls.isEmpty && state.floatCalls.isEmpty)

        // B. 目标屏无 yabai display index
        reset()
        state.displayIndex = nil
        let b = run(windowIDs: [9101], frames: [cell])
        check("spaceDelivery B1: 屏无法映射 yabai display → (0,0,false)",
              b.attempted == 0 && b.delivered == 0 && !b.parkingUnavailable)

        // C. 单屏：无泊位屏
        reset()
        state.parkingScreen = nil
        let c = run(windowIDs: [9101], frames: [cell])
        check("spaceDelivery C1: 无泊位屏 → parkingUnavailable=true",
              c.attempted == 0 && c.delivered == 0 && c.parkingUnavailable
              && state.yabaiCalls.isEmpty && state.sleeps.isEmpty)

        // D. 窗口已在目标 space → notNeeded 跳过
        reset()
        state.queryScript = [info(space: 2, display: 1, manageable: true)]
        let d = run(windowIDs: [9101], frames: [cell])
        check("spaceDelivery D1: 已在目标 space → 零投递零 yabai",
              d.attempted == 0 && d.delivered == 0 && !d.parkingUnavailable
              && state.yabaiCalls.isEmpty && state.floatCalls.isEmpty)

        // E. 跨屏直写：窗口在其它 display → float + move + resize → 到位
        reset()
        state.queryScript = [
            info(space: 1, display: 2, manageable: true),
            info(space: 1, display: 2, manageable: true),
            info(space: 2, display: 2, manageable: true),
        ]
        let e = run(windowIDs: [9101], frames: [cell])
        check("spaceDelivery E1: 跨屏错位 → attempted=1 delivered=1",
              e.attempted == 1 && e.delivered == 1 && !e.parkingUnavailable)
        check("spaceDelivery E2: 浮起一次 + move/resize 两段直写（无 park 段）",
              state.floatCalls == [9101] && state.yabaiCalls.count == 2
              && state.yabaiCalls[0].operation.hasPrefix("delivery.writeback.move")
              && state.yabaiCalls[1].operation.hasPrefix("delivery.writeback.resize"))
        check("spaceDelivery E3: 直写帧取传入格位", state.yabaiCalls[0].args.contains("abs:20:20"))

        // F. 同屏往返：窗口在目标屏错位 space → park + 600ms + move/resize
        reset()
        state.queryScript = [
            info(space: 1, display: 1, manageable: true),
            info(space: 1, display: 1, manageable: true),
            info(space: 2, display: 1, manageable: true),
        ]
        let f = run(windowIDs: [9101], frames: [cell])
        check("spaceDelivery F1: 同屏往返 → attempted=1 delivered=1",
              f.attempted == 1 && f.delivered == 1)
        check("spaceDelivery F2: park 段 + 600ms 睡眠 + 写回两段",
              state.yabaiCalls.count == 3
              && state.yabaiCalls[0].operation.hasPrefix("delivery.park")
              && state.sleeps.contains(600_000_000))

        // G. AX 引用始终未建立 → 轮询 3s 后跳过
        reset()
        state.fallbackInfo = info(space: 1, display: 2, manageable: false)
        let g = run(windowIDs: [9101], frames: [cell])
        check("spaceDelivery G1: AX 未就绪 → attempted=1 delivered=0",
              g.attempted == 1 && g.delivered == 0)
        check("spaceDelivery G2: 未 float、未写帧，轮询全部 200ms",
              state.floatCalls.isEmpty && state.yabaiCalls.isEmpty
              && state.sleeps.count == 15 && state.sleeps.allSatisfy { $0 == 200_000_000 })

        // H. 目标屏视角被拉走 → 先 refocus 再投递
        reset()
        state.visibleScript = [1, 2]
        state.queryScript = [
            info(space: 1, display: 2, manageable: true),
            info(space: 1, display: 2, manageable: true),
            info(space: 2, display: 2, manageable: true),
        ]
        let h = run(windowIDs: [9101], frames: [cell])
        check("spaceDelivery H1: 视角漂移 → refocus 一次", state.refocusCalls.count == 1
              && state.refocusCalls[0].space == 2)
        check("spaceDelivery H2: refocus 后仍完成投递", h.delivered == 1)

        // I. 帧数少于窗口数 → 只处理 frames.count 个
        reset()
        state.queryScript = [
            info(space: 1, display: 2, manageable: true),
            info(space: 1, display: 2, manageable: true),
            info(space: 2, display: 2, manageable: true),
        ]
        let i2 = run(windowIDs: [9101, 9102], frames: [cell])
        check("spaceDelivery I1: 无第二帧 → 只投递第一窗",
              i2.attempted == 1 && state.floatCalls == [9101])
    }
}
