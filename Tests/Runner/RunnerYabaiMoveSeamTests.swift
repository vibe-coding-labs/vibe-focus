import AppKit
import ApplicationServices
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
    /// position 属性是否可写（与 size 分开：只读窗口可以 size 可写而 position 不可写）。
    var axPositionSettable = false
    var axResizeResult = true
    var axResizeCalls = 0
    var axPositionCalls = 0
    var axPositionResult = true
    /// AX position 写是否真的落地（false = 静默吞写，用于断言降级路径）。
    var axPositionApplies = true
    var ensureConverged = true
    /// 是否走原子合发（默认 true = 生产行为；false 复现历史两段序列）。
    var combined = true
    /// yabai 通道的 size 写被终端吸附的额外宽度（0 = 精确；24 = iTerm2 664-640 实测差）。
    var snappedWidth: CGFloat = 0
    /// yabai 自己是否做过 size 写（决定它进程内缓存里是吸附值还是旧值）。
    var yabaiSawSizeWrite = false
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
                    // 生产的偏差来源（yabai 源码）：--move 落到 set_window_frame，它用它
                    // 缓存的宽高再写一次 size；缓存只在 yabai 自己做过 size 写之后才有
                    // 吸附值。state.yabaiSawSizeWrite 模拟这条时间线。
                    var frame = state.bounds ?? source
                    let yabaiSize = CGSize(width: target.width + state.snappedWidth,
                                           height: target.height)
                    if args.contains("--move") {
                        frame.origin = target.origin
                        // set_window_frame 会用它缓存的宽高重写 size；缓存只在 yabai 自己
                        // 做过 size 写之后才是吸附值（生产的偏差来源）。
                        if state.yabaiSawSizeWrite { frame.size = yabaiSize }
                    }
                    if args.contains("--resize") {
                        frame.size = yabaiSize
                        state.yabaiSawSizeWrite = true
                    }
                    state.bounds = frame
                },
                findAXWindow: { _, _ in state.axFound ? fakeAX : nil },
                isSettable: { _, attribute in
                    attribute == kAXPositionAttribute ? state.axPositionSettable : state.axSettable
                },
                resizeViaAX: { _, _ in
                    state.axResizeCalls += 1
                    guard state.axResizeResult, state.ensureConverged else { return state.axResizeResult }
                    state.bounds = CGRect(origin: state.bounds?.origin ?? source.origin,
                                          size: target.size)
                    return true
                },
                pollSleep: { _ in },
                useCombinedWrite: state.combined,
                writePositionViaAX: { frame, _ in
                    state.axPositionCalls += 1
                    guard state.axPositionResult, state.ensureConverged,
                          state.axPositionApplies else { return state.axPositionResult }
                    state.bounds = CGRect(origin: frame.origin,
                                          size: state.bounds?.size ?? frame.size)
                    return true
                })
        }

        let wm = WindowManager.shared
        func reset(manageable: Bool = true) {
            state.info = info(manageable: manageable)
            state.bounds = source
            state.yabaiArgs = []
            state.axFound = false
            state.axSettable = false
            state.axPositionSettable = false
            state.axResizeResult = true
            state.axResizeCalls = 0
            state.axPositionCalls = 0
            state.axPositionResult = true
            state.axPositionApplies = true
            state.ensureConverged = true
            state.combined = true
            state.snappedWidth = 0
            state.yabaiSawSizeWrite = false
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

        // A′. 合发开启、AX 不可写：一次消息写完两段，零段间等待、写序保留
        //     （生产里这条臂只在 AX 尺寸不可用时接管，见 A″）。
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
        state.axPositionSettable = true
        let b = run()
        check("yabaiSeam B1: AX resize 通道成功 → 收敛", b == true)
        check("yabaiSeam B2: resize 未走 yabai（AX 择优生效）",
              !state.yabaiArgs.contains { $0.contains("--resize") })
        check("yabaiSeam B3: AX resize 至少一次", state.axResizeCalls >= 1)
        check("yabaiSeam B4: 位置也由 AX 直写（全 AX 臂不再依赖 yabai move）",
              state.axPositionCalls >= 1
              && !state.yabaiArgs.contains { $0.contains("--move") })

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

        // A″. 生产默认（AX 可写 + 合发开启）：AX 尺寸通道优先，合发被让位
        //     ——2026-11-23 还原尺寸精度修复（yabai 的 size 写会被终端字符网格吸附）。
        reset()
        state.axFound = true
        state.axSettable = true
        state.axPositionSettable = true
        let aDoublePrime = run()
        check("yabaiSeam A9: AX 可写时收敛", aDoublePrime == true)
        check("yabaiSeam A10: AX 可写时尺寸走 AX、yabai 不再发 --resize",
              state.axResizeCalls >= 1
              && !state.yabaiArgs.contains { $0.contains("--resize") })
        check("yabaiSeam A11: AX 可写时不再合发（合发会绕过精确尺寸通道）",
              !state.yabaiArgs.contains { $0.contains("--move") && $0.contains("--resize") })
        // 2026-11-23 双向单步：位置也可 AX 写时**不再需要** yabai --move——yabai 只要
        // 碰位置就会用缓存宽高覆盖尺寸，那正是「两步」与「尺寸错」的共同来源。
        check("yabaiSeam A12: 位置也可 AX 写 → 不再发 yabai --move（全 AX 单步）",
              state.axPositionCalls >= 1
              && !state.yabaiArgs.contains { $0.contains("--move") })

        // A‴′. 双向单步（2026-11-23）：position 也可 AX 写 → 全 AX 臂，零 yabai 帧写入。
        //      这是「一次跳变」的唯一形态——yabai 只要碰位置就会用缓存宽高覆盖尺寸。
        reset()
        state.axFound = true
        state.axSettable = true
        state.axPositionSettable = true
        let axFull = run()
        check("yabaiSeam A16: AX 尺寸+位置都可写 → 收敛", axFull == true)
        check("yabaiSeam A17: 全 AX 臂零 yabai 帧写入（无 --move 也无 --resize）",
              !state.yabaiArgs.contains { $0.contains("--move") || $0.contains("--resize") })
        check("yabaiSeam A18: 尺寸与位置都由 AX 写（各 ≥1 次）",
              state.axResizeCalls >= 1 && state.axPositionCalls >= 1)

        // A‴″. AX position 静默吞写（返回 true 但读回不达标）→ 当场降级 yabai move，
        //       并且此后不再反复撞 AX 位置通道（一次失败即永久降级）。
        reset()
        state.axFound = true
        state.axSettable = true
        state.axPositionSettable = true
        state.axPositionApplies = false
        let degraded = run()
        check("yabaiSeam A19: AX 位置吞写 → 降级 yabai move 后仍收敛", degraded == true)
        check("yabaiSeam A20: 降级后 yabai 确有 --move", state.yabaiArgs.contains { $0.contains("--move") })
        check("yabaiSeam A21: 位置通道只试一次（失败即降级，不反复撞）",
              state.axPositionCalls == 1)

        // A″′. 跨屏回归锁（2026-11-23 真机「来回跳来跳去」）：目标 frame **不在**源屏
        //       可视区内 → 必须拒绝 AX position（裸 AX 跨屏写被 WindowServer 钳回源屏，
        //       读回失败再降级 yabai move = 位置动两次），位置改走 yabai。
        reset()
        state.axFound = true
        state.axSettable = true
        state.axPositionSettable = true
        // 跨屏目标：不在 source(0,0,1000,800) 内。
        let crossTarget = CGRect(x: 1200, y: 900, width: 500, height: 400)
        let crossSource = source
        let crossOK = wm.moveWindowToFrameViaYabai(
            windowID: 7101, frame: crossTarget, op: "ut-yabai", stage: "ut",
            sourceVisibleFrame: crossSource, environment: makeEnv())
        check("yabaiSeam A22: 跨屏目标 → 拒绝 AX position（零 axPosition 写）",
              state.axPositionCalls == 0)
        check("yabaiSeam A23: 跨屏目标 → 位置走 yabai --move（唯一验证过的跨屏通道）",
              state.yabaiArgs.contains { $0.contains("--move") })
        // 跨屏 + 位置走 yabai + 尺寸走 AX → 应能收敛（本夹具的 yabai move 会落到 target）。
        check("yabaiSeam A24: 跨屏路径收敛", crossOK == true)

        // A‴. 终端吸附场景：yabai 的 size 写落 664（iTerm2 字符网格 +24），且它缓存着
        //     664——随后的 --move 会把 AX 刚写好的 640 盖回 664。这是用户主诉
        //     「目标 640x525、实际 664x525、frameOK=false」的执行器级复现。
        reset()
        state.axFound = true
        state.axSettable = true
        state.axPositionSettable = false   // 只尺寸可 AX → axPrecise 臂
        state.snappedWidth = 24
        state.yabaiSawSizeWrite = true   // yabai 缓存里已是吸附值
        let snapped = run()
        check("yabaiSeam A13: yabai 缓存复写 664 后 AX 补写仍收敛到 640",
              snapped == true && state.axResizeCalls >= 2)
        check("yabaiSeam A14: 吸附场景全程不靠 yabai --resize（它永远回到 664）",
              !state.yabaiArgs.contains { $0.contains("--resize") })
        // A⁗. 同样起点，但 AX 不可用：只能靠 yabai → 如实不收敛（不得谎报成功）。
        reset()
        state.snappedWidth = 24
        state.yabaiSawSizeWrite = true
        let snappedNoAX = run()
        check("yabaiSeam A15: 吸附 + AX 不可用 → 如实 false（不谎报 640）",
              snappedNoAX == false)

        // D. 写原语全部不生效：预算内轮询后如实 false
        reset()
        state.ensureConverged = false
        state.axPositionSettable = true   // 位置先 AX、失败后降级 yabai
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
