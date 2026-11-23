import AppKit
import ApplicationServices
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerYabaiMoveSeamTests.swift
// 靶：WindowManager.moveWindowToFrameViaYabai 全链（YabaiMoveEnvironment 注入）——
// 管理窗分流、写前快照与写序、yabai move/resize 发令、AX resize 择优与
// 「AX 一轮不收敛即降级 yabai」、收敛/不收敛裁决。零 fork、零真实窗口移动、
// 零真实等待（pollSleep 注入为空操作）。
//
// ## 2026-11-23 收敛后的契约（本文件锁定）
// 跨屏且改尺寸时「一步完成」在物理上不存在（三条硬约束见 FrameWriteExecutor 头注），
// 帧写入恒走「尺寸优先 AX、位置恒 yabai」两段。曾试过并被真机否掉的：
// 原子合发（尺寸吸附 664）、AX 跨屏 position（被钳回 → 来回跳）、
// 放大序先试终态（三跳）、AX resize 单次写不等读回（仍跳）。相关断言已随之删除，
// 不要凭旧提交历史把它们加回来。

final class YabaiMoveSeamState: @unchecked Sendable {
    var info: YabaiWindowInfo?
    var bounds: CGRect?
    var yabaiArgs: [[String]] = []
    var axFound = false
    var axSettable = false
    var axResizeResult = true
    var axResizeCalls = 0
    var ensureConverged = true
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

        /// 每次重跑工厂：闭包按 state 现场取值。
        func makeEnv() -> YabaiMoveEnvironment {
            YabaiMoveEnvironment(
                queryWindow: { _ in state.info },
                cgWindowBounds: { _ in state.bounds },
                runYabai: { args in
                    state.yabaiArgs.append(args)
                    guard state.ensureConverged else { return }
                    // 生产的偏差来源（yabai 源码）：--move 落到 set_window_frame，它用它
                    // 缓存的宽高再写一次 size；缓存只在 yabai 自己做过 size 写之后才有
                    // 吸附值。state.yabaiSawSizeWrite 模拟这条时间线。
                    var frame = state.bounds ?? source
                    let yabaiSize = CGSize(width: target.width + state.snappedWidth,
                                           height: target.height)
                    if args.contains("--move") {
                        frame.origin = target.origin
                        if state.yabaiSawSizeWrite { frame.size = yabaiSize }
                    }
                    if args.contains("--resize") {
                        frame.size = yabaiSize
                        state.yabaiSawSizeWrite = true
                    }
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
                pollSleep: { _ in })
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
            state.snappedWidth = 0
            state.yabaiSawSizeWrite = false
        }
        func run() -> Bool {
            wm.moveWindowToFrameViaYabai(
                windowID: 7101, frame: target, op: "ut-yabai", stage: "ut",
                sourceVisibleFrame: source, environment: makeEnv())
        }

        // A. 管理窗 + AX 不可写：yabai 两段写入，写序自适应（收窄 → resize 先行）。
        reset()
        let a = run()
        check("yabaiSeam A1: 管理窗 AX 不可写 → yabai 双段写入后收敛", a == true)
        check("yabaiSeam A2: move 与 resize 均经 yabai 发令（两段路径各自成条）",
              state.yabaiArgs.filter { $0.contains("--move") }.count >= 1
              && state.yabaiArgs.filter { $0.contains("--resize") }.count >= 1)
        check("yabaiSeam A3: 每条消息只含一个动作（无合发）",
              state.yabaiArgs.allSatisfy { args in
                  let hasMove = args.contains("--move"), hasResize = args.contains("--resize")
                  return (hasMove || hasResize) && !(hasMove && hasResize)
              })
        let firstResize = state.yabaiArgs.firstIndex { $0.contains("--resize") }
        let firstMove = state.yabaiArgs.firstIndex { $0.contains("--move") }
        check("yabaiSeam A4: 收窄场景 resize 先于 move（写序自适应）",
              firstResize != nil && firstMove != nil && firstResize! < firstMove!)

        // B. AX 可写：尺寸走 AX（不进 yabai），位置恒走 yabai（跨屏唯一通道）。
        reset()
        state.axFound = true
        state.axSettable = true
        let b = run()
        check("yabaiSeam B1: AX resize 通道成功 → 收敛", b == true)
        check("yabaiSeam B2: resize 未走 yabai（AX 择优生效）",
              !state.yabaiArgs.contains { $0.contains("--resize") })
        check("yabaiSeam B3: AX resize 至少一次", state.axResizeCalls >= 1)
        check("yabaiSeam B4: 位置恒走 yabai --move", state.yabaiArgs.contains { $0.contains("--move") })

        // C. AX resize 失败 → 降级 yabai resize 补发。
        reset()
        state.axFound = true
        state.axSettable = true
        state.axResizeResult = false
        let c = run()
        check("yabaiSeam C1: AX 写失败后降级 yabai → 收敛", c == true)
        check("yabaiSeam C2: AX 尝试过且随后出现 yabai resize",
              state.axResizeCalls >= 1 && state.yabaiArgs.contains { $0.contains("--resize") })

        // D. 写原语全部不生效：预算内轮询后如实 false。
        reset()
        state.ensureConverged = false
        let d = run()
        check("yabaiSeam D1: 写不生效 → false（不谎报成功）", d == false)
        check("yabaiSeam D2: 失败前确有写入尝试",
              state.yabaiArgs.contains { $0.contains("--move") })

        // E. AX 属性不可写 → 全走 yabai。
        reset()
        state.axFound = true
        state.axSettable = false
        let e = run()
        check("yabaiSeam E1: AX 属性不可写 → yabai 通道收敛", e == true)
        check("yabaiSeam E2: 零 AX resize 尝试", state.axResizeCalls == 0)

        // F. 终端吸附场景：yabai 的 size 写落 664（iTerm2 字符网格 +24）。
        //    AX 可写时尺寸全程走 AX，yabai 只负责位置——最终收敛到目标值。
        reset()
        state.axFound = true
        state.axSettable = true
        state.snappedWidth = 24
        state.yabaiSawSizeWrite = true
        let f = run()
        check("yabaiSeam F1: 吸附场景下 AX 尺寸通道仍收敛到目标", f == true)
        check("yabaiSeam F2: 吸附场景全程不发 yabai --resize（它永远回到 664）",
              !state.yabaiArgs.contains { $0.contains("--resize") })

        // G. 同样起点但 AX 不可用 → 只能靠 yabai，如实不收敛（不谎报 640）。
        reset()
        state.snappedWidth = 24
        state.yabaiSawSizeWrite = true
        check("yabaiSeam G1: 吸附 + AX 不可用 → 如实 false",
              run() == false)

        // H. 跨屏目标：位置仍走 yabai（AX 跨屏 position 已被真机否掉，见文件头）。
        reset()
        state.axFound = true
        state.axSettable = true
        let crossTarget = CGRect(x: 1200, y: 900, width: 500, height: 400)
        _ = wm.moveWindowToFrameViaYabai(
            windowID: 7101, frame: crossTarget, op: "ut-yabai", stage: "ut",
            sourceVisibleFrame: source, environment: makeEnv())
        check("yabaiSeam H1: 跨屏目标 → 位置走 yabai --move",
              state.yabaiArgs.contains { $0.contains("--move") })
        check("yabaiSeam H2: 跨屏目标 → 尺寸仍优先 AX（精度不丢）",
              state.axResizeCalls >= 1)
    }
}
