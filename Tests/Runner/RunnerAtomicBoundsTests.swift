import AppKit
import ApplicationServices
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerAtomicBoundsTests.swift
// 靶：iTerm2 原子 bounds 通道（2026-11-24，探针实证后的新通道）——
// A. 白名单（仅 com.googlecode.iterm2；Terminal 的 set bounds 是「当前屏局部坐标」
//    语义跨屏必漂移，走历史两段）
// B. 脚本文本契约（quartz 角点 {x1,y1,x2,y2}；主屏正 y / 副屏负 y 双形态，2026-11-23
//    真机探针双向零中间态、偏差和=0 的通道即本脚本文本）
// C. 跨屏门控判定（displayID 任一端解析失败 → 保守判同屏走历史路径）
// D. 编排契约（YabaiMoveEnvironment.attemptAtomicBounds 注入缝）：
//    原子成功 → 两段路径零发令；原子失败 → 两段照常收敛（只加速不依赖）。
// 零 fork、零真实窗口移动、零真实等待。
//
// ## 与 2026-11-23「物理不可行」结论的关系（必读，防止再被改回去）
// 旧结论「跨屏改尺寸一步完成物理不存在」的三条硬约束全部只针对 AX/yabai 通道：
// yabai --move 缓存三连写 / iTerm2 对 AX 写的网格吸附与吞写 / AX 跨屏动画。
// AppleScript set bounds 是当时未尝试的第三通道——2026-11-23 真机 4ms 采样实证
// 单帧、像素精确、双向成立，故「一步」在 iTerm2 上存在，且避免多段写楔死
// iTerm2 状态机的隐患（同日真机事故）。相关真机证据见 AtomicBoundsChannel.swift 头注。

final class AtomicBoundsSeamState: @unchecked Sendable {
    let source = CGRect(x: 0, y: -700, width: 640, height: 525)
    let target = CGRect(x: 120, y: 60, width: 1653, height: 1010)
    var bounds: CGRect
    var yabaiArgs: [[String]] = []
    var atomicAttempted = 0

    init(bounds: CGRect? = nil) {
        self.bounds = bounds ?? CGRect(x: 0, y: -700, width: 640, height: 525)
    }

    func makeEnv() -> YabaiMoveEnvironment {
        YabaiMoveEnvironment(
            queryWindow: { _ in
                YabaiWindowInfo(
                    id: 88, pid: 4242, app: "iTerm2", title: "t",
                    space: 1, display: 2,
                    frame: YabaiWindowInfo.Frame(x: 0, y: -700, w: 640, h: 525),
                    isFloatingRaw: true, hasAXReferenceRaw: true)
            },
            cgWindowBounds: { [weak self] _ in self?.bounds },
            runYabai: { [weak self] args in
                guard let self else { return }
                self.yabaiArgs.append(args)
                var frame = self.bounds
                if args.contains("--move") { frame.origin = self.target.origin }
                if args.contains("--resize") { frame.size = self.target.size }
                self.bounds = frame
            },
            findAXWindow: { _, _ in nil },
            isSettable: { _, _ in false },
            resizeViaAX: { _, _ in true },
            pollSleep: { _ in })
    }
}

extension RunnerHarness {
    func runAtomicBoundsTests() {
        // MARK: A. 白名单
        do {
            check("atomic A1: iterm2 支持", AtomicBoundsChannel.supports(bundleID: "com.googlecode.iterm2"))
            check("atomic A2: Terminal 不支持（set bounds 局部坐标语义跨屏必漂移，2026-09-04 实证）",
                  AtomicBoundsChannel.supports(bundleID: "com.apple.Terminal") == false)
            check("atomic A3: nil 不支持", AtomicBoundsChannel.supports(bundleID: nil) == false)
            check("atomic A4: 其他 app 不支持", AtomicBoundsChannel.supports(bundleID: "com.google.Chrome") == false)
        }

        // MARK: B. 脚本文本契约
        do {
            let mainFrame = CGRect(x: 120, y: 60, width: 1653, height: 1010)
            check("atomic B1: 主屏正坐标角点 {x1,y1,x2,y2}",
                  AtomicBoundsChannel.iterm2Script(windowID: 42, frame: mainFrame)
                      == "tell application id \"com.googlecode.iterm2\" to set bounds of window id 42 to {120, 60, 1773, 1070}")
            let subFrame = CGRect(x: 1100, y: -700, width: 640, height: 525)
            check("atomic B2: 副屏负 y 角点（还原方向）",
                  AtomicBoundsChannel.iterm2Script(windowID: 7, frame: subFrame)
                      == "tell application id \"com.googlecode.iterm2\" to set bounds of window id 7 to {1100, -700, 1740, -175}")
            let halfPoint = CGRect(x: 10.4, y: 20.6, width: 100.2, height: 200.7)
            check("atomic B3: 小数四舍五入取整",
                  AtomicBoundsChannel.iterm2Script(windowID: 9, frame: halfPoint)
                      == "tell application id \"com.googlecode.iterm2\" to set bounds of window id 9 to {10, 21, 111, 221}")
        }

        // MARK: C. 跨屏门控判定（保守 nil 语义）
        do {
            check("atomic C1: 任一端 displayID nil → 判同屏（保守走历史路径）",
                  WindowManager.isCrossDisplayTarget(currentDisplayID: nil, targetDisplayID: 1) == false
                      && WindowManager.isCrossDisplayTarget(currentDisplayID: 1, targetDisplayID: nil) == false)
            check("atomic C2: 同屏 → 不启用", WindowManager.isCrossDisplayTarget(currentDisplayID: 1, targetDisplayID: 1) == false)
            check("atomic C3: 跨屏 → 启用", WindowManager.isCrossDisplayTarget(currentDisplayID: 1, targetDisplayID: 2))
        }

        // MARK: D. 编排契约（注入缝）
        do {
            // D1/D2: 原子成功 → 短路返回，两段路径零发令
            let state = AtomicBoundsSeamState()
            var env = state.makeEnv()
            env.attemptAtomicBounds = { [weak state] _, _ in
                state?.atomicAttempted += 1
                return true
            }
            let ok = WindowManager.shared.moveWindowToFrameViaYabai(
                windowID: 88, frame: state.target, op: "atomic-t", stage: "atomic_d1",
                sourceVisibleFrame: nil, environment: env)
            check("atomic D1: 原子成功返回 true", ok)
            check("atomic D2: 原子成功两段零发令", state.yabaiArgs.isEmpty)
            check("atomic D3: 原子缝恰好被尝试一次", state.atomicAttempted == 1)

            // D4/D5: 原子失败 → 落回两段并收敛（只加速不依赖）
            let state2 = AtomicBoundsSeamState()
            var env2 = state2.makeEnv()
            env2.attemptAtomicBounds = { [weak state2] _, _ in
                state2?.atomicAttempted += 1
                return false
            }
            let ok2 = WindowManager.shared.moveWindowToFrameViaYabai(
                windowID: 88, frame: state2.target, op: "atomic-t", stage: "atomic_d4",
                sourceVisibleFrame: nil, environment: env2)
            check("atomic D4: 原子失败两段仍收敛", ok2)
            check("atomic D5: 原子失败两段有发令", state2.yabaiArgs.isEmpty == false)
            check("atomic D6: 原子缝尝试过一次", state2.atomicAttempted == 1)

            // D7: 注入环境但无缝（历史用例形态）→ 不进原子通道，直接两段
            let state3 = AtomicBoundsSeamState()
            let env3 = state3.makeEnv()
            let ok3 = WindowManager.shared.moveWindowToFrameViaYabai(
                windowID: 88, frame: state3.target, op: "atomic-t", stage: "atomic_d7",
                sourceVisibleFrame: nil, environment: env3)
            check("atomic D7: 注入环境无缝不进原子通道且两段收敛", ok3)
            check("atomic D8: 两段有发令", state3.yabaiArgs.isEmpty == false)
        }
    }
}
