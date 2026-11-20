import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerYabaiMoveSeamTests.swift
// 靶：WindowManager.moveWindowToFrameViaYabai 全链（YabaiMoveEnvironment 注入）——
// 管理窗分流、写前快照与写序、yabai move/resize 发令、AX resize 择优与
// 「AX 一轮不收敛即降级 yabai」、收敛/不收敛裁决。零 fork、零真实窗口移动、
// 零真实等待（pollSleep 注入为空操作）。

final class YabaiMoveSeamState: @unchecked Sendable {
    var info: YabaiWindowInfo?
    var bounds: CGRect?
    var yabaiArgs: [[String]] = []
    var axFound = false
    var axSettable = false
    var axResizeResult = true
    var axResizeCalls = 0
    var ensureConverged = true
    /// 是否走原子合发（默认 true = 生产行为；false 复现历史两段序列）。
    var combined = true
}

extension RunnerHarness {
    func runYabaiMoveSeamTests() {
        let state = YabaiMoveSeamState()
        let fakeAX = AXUIElementCreateSystemWide()
        let source = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let target = CGRect(x: 10, y: 20, width: 500, height: 400)

        func info(manageable: Bool) -> YabaiWindowInfo {
            YabaiWindowInfo(
                id: 7101, pid: 4242, app: "Terminal", title: "t",
                space: 1, display: 1,
                frame: YabaiWindowInfo.Frame(x: 0, y: 0, w: 1000, h: 800),
                isFloatingRaw: false, hasAXReferenceRaw: manageable)
        }

        /// 每次重跑工厂：bounds 复位、计数器清零，闭包按 state 现场取值。
        func makeEnv() -> YabaiMoveEnvironment {
            YabaiMoveEnvironment(
                queryWindow: { _ in state.info },
                cgWindowBounds: { _ in state.bounds },
                runYabai: { args in
                    state.yabaiArgs.append(args)
                    guard state.ensureConverged else { return }
                    // 合发与单发同款：一条消息里出现哪个动作就应用哪个（合发两条都应用）。
                    var frame = state.bounds ?? source
                    if args.contains("--move") { frame.origin = target.origin }
                    if args.contains("--resize") { frame.size = target.size }
                    state.bounds = frame
                },
                findAXWindow: { _, _ in state.axFound ? fakeAX : nil },
                isSettable: { _, _ in state.axSettable },
                resizeViaAX: { _, _ in
                    state.axResizeCalls += 1
                    guard state.axResizeResult, state.ensureConverged else { return state.axResizeResult }
                    state.bounds = CGRect(origin: state.bounds?.origin ?? source.origin,
                                          size: target.size)
                    return true
                },
                pollSleep: { _ in },
                useCombinedWrite: state.combined)
        }

        let wm = WindowManager.shared
        func reset(manageable: Bool = true) {
            state.info = info(manageable: manageable)
            state.bounds = source
            state.yabaiArgs = []
            state.axFound = false
            state.axSettable = false
            state.axResizeResult = true
            state.axResizeCalls = 0
            state.ensureConverged = true
            state.combined = true
        }
        func run() -> Bool {
            wm.moveWindowToFrameViaYabai(
                windowID: 7101, frame: target, op: "ut-yabai", stage: "ut",
                sourceVisibleFrame: source, environment: makeEnv())
        }

        // A. 管理窗 + AX 不可写 + 合发关闭（历史两段路径）：写序与发令逐条保留
        reset()
        state.combined = false
        let a = run()
        check("yabaiSeam A1: 管理窗 AX 不可写 → yabai 双段写入后收敛", a == true)
        check("yabaiSeam A2: move 与 resize 均经 yabai 发令（两段路径各自成条）",
              state.yabaiArgs.filter { $0.contains("--move") }.count >= 1
              && state.yabaiArgs.filter { $0.contains("--resize") }.count >= 1)
        // 两段路径的每条发令只含一个动作（合发关闭的回归锁）。
        check("yabaiSeam A3: 两段路径每条消息只含一个动作",
              state.yabaiArgs.allSatisfy { args in
                  let hasMove = args.contains("--move"), hasResize = args.contains("--resize")
                  return (hasMove || hasResize) && !(hasMove && hasResize)
              })
        let firstResize = state.yabaiArgs.firstIndex { $0.contains("--resize") }
        let firstMove = state.yabaiArgs.firstIndex { $0.contains("--move") }
        check("yabaiSeam A4: 收窄场景 resize 先于 move（写序自适应）",
              firstResize != nil && firstMove != nil && firstResize! < firstMove!)

        // A′. 合发开启（生产默认）：一次消息写完两段，零段间等待、写序保留
        reset()
        let aPrime = run()
        check("yabaiSeam A5: 合发路径 → 收敛", aPrime == true)
        let combinedSends = state.yabaiArgs.filter { $0.contains("--move") && $0.contains("--resize") }
        check("yabaiSeam A6: 合发路径首条消息同时含 --move 与 --resize（单次 fork 写全帧）",
              combinedSends.count >= 1 && state.yabaiArgs.first == combinedSends.first)
        if let combo = state.yabaiArgs.first {
            let moveIdx = combo.firstIndex(of: "--move") ?? combo.count
            let resizeIdx = combo.firstIndex(of: "--resize") ?? combo.count
            check("yabaiSeam A7: 收窄场景合发内部 resize 仍在 move 之前（写序不丢）",
                  resizeIdx < moveIdx)
            check("yabaiSeam A8: 合发参数含 move 与 resize 的 abs 目标值",
                  combo.contains("abs:\(Int(target.origin.x)):\(Int(target.origin.y))")
                  && combo.contains("abs:\(Int(target.width)):\(Int(target.height))"))
        } else {
            check("yabaiSeam A7: 收窄场景合发内部 resize 仍在 move 之前（写序不丢）", false)
            check("yabaiSeam A8: 合发参数含 move 与 resize 的 abs 目标值", false)
        }

        // B. AX resize 可写且成功（合发关闭的兼容路径）：resize 走 AX（零 fork），move 走 yabai
        reset()
        state.combined = false
        state.axFound = true
        state.axSettable = true
        let b = run()
        check("yabaiSeam B1: AX resize 通道成功 → 收敛", b == true)
        check("yabaiSeam B2: resize 未走 yabai（AX 择优生效）",
              !state.yabaiArgs.contains { $0.contains("--resize") })
        check("yabaiSeam B3: AX resize 至少一次", state.axResizeCalls >= 1)
        check("yabaiSeam B4: move 恒走 yabai（跨屏唯一通道）",
              state.yabaiArgs.contains { $0.contains("--move") })

        // C. AX resize 报告失败且不生效（合发关闭的兼容路径）：降级 yabai resize 补发后收敛
        reset()
        state.combined = false
        state.axFound = true
        state.axSettable = true
        state.axResizeResult = false
        let c = run()
        check("yabaiSeam C1: AX 写一轮失败后降级 yabai → 收敛", c == true)
        check("yabaiSeam C2: AX 尝试过且随后出现 yabai resize",
              state.axResizeCalls >= 1 && state.yabaiArgs.contains { $0.contains("--resize") })

        // D. 写原语全部不生效：预算内轮询后如实 false
        reset()
        state.ensureConverged = false
        let d = run()
        check("yabaiSeam D1: 写不生效 → false（不谎报成功）", d == false)
        check("yabaiSeam D2: 失败前确有写入尝试",
              state.yabaiArgs.contains { $0.contains("--move") })

        // E. AX 属性不可写（findAXWindow 命中但 settable=false）→ 全走 yabai
        reset()
        state.axFound = true
        state.axSettable = false
        let e = run()
        check("yabaiSeam E1: AX 属性不可写 → yabai 通道收敛", e == true)
        check("yabaiSeam E2: 零 AX resize 尝试", state.axResizeCalls == 0)
    }
}
