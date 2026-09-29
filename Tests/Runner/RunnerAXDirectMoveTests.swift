import AppKit
import ApplicationServices.HIServices
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerAXDirectMoveTests.swift — Terminal.app ⌃Q 支持拍（2026-09-29）。
// yabai-blind 窗口（SA 无法注入的 Apple 自家 app）的 AX 直写移动通道：
// ①MoveChannelPolicy 通道选择真值表（分流唯一入口）；
// ②ownerPID CGWindowList 快照解析（假快照）；
// ③matchAXWindow AX 元素匹配（handle 闭包注入）；
// ④runAXFrameWrite 假 IO 写序/收敛语义（FrameWriteExecutor 接线锁定）。

/// 写事件记录盒（@escaping 闭包捕获用）。读回状态按「已发生的写事件」驱动，
/// 而非调用序号——虚拟时间（no-op sleep）下轮询 busy-spin 会瞬间烧穿按序号
/// 预设的读回序列（首跑实测 attempt 恒 1 的教训）。
private final class AXWriteRecorder {
    var events: [String] = []
    var moveWrites = 0

    /// 未发 move 前（段间等待期）读 nil；move 第 1 次后读旧帧（触发补发）；
    /// move 第 2 次后读达标（收敛 attempt≥2）。
    func read(target: CGRect) -> CGRect? {
        if moveWrites == 0 { return nil }
        if moveWrites == 1 { return CGRect(x: 9999, y: 9999, width: target.width, height: target.height) }
        return target
    }
}

extension RunnerHarness {

    func runAXDirectMoveTests() {
        print("\n=== AXDirectMove (Terminal.app ⌃Q 支持拍) ===")

        // ===== A. MoveChannelPolicy 真值表 =====
        do {
            check("axdirect: yabai 认识窗口 → yabai 通道",
                  MoveChannelPolicy.channel(yabaiKnowsWindow: true) == .yabai)
            check("axdirect: yabai-blind → axDirect 通道",
                  MoveChannelPolicy.channel(yabaiKnowsWindow: false) == .axDirect)
        }

        // ===== B. ownerPID 快照解析 =====
        do {
            let snapshot: [[String: Any]] = [
                ["kCGWindowNumber": NSNumber(value: 8064), "kCGWindowOwnerPID": NSNumber(value: 87_536)],
                ["kCGWindowNumber": NSNumber(value: 1234), "kCGWindowOwnerPID": "not-a-number"],
                ["kCGWindowNumber": NSNumber(value: 5678)],
            ]
            check("axdirect: ownerPID 命中",
                  WindowManager.ownerPID(fromSnapshot: snapshot, windowID: 8064) == 87_536)
            check("axdirect: ownerPID pid 非数字 → nil",
                  WindowManager.ownerPID(fromSnapshot: snapshot, windowID: 1234) == nil)
            check("axdirect: ownerPID 缺 pid 键 → nil",
                  WindowManager.ownerPID(fromSnapshot: snapshot, windowID: 5678) == nil)
            check("axdirect: ownerPID 查无此窗 → nil",
                  WindowManager.ownerPID(fromSnapshot: snapshot, windowID: 99) == nil)
            check("axdirect: ownerPID 空快照 → nil",
                  WindowManager.ownerPID(fromSnapshot: [], windowID: 1) == nil)
        }

        // ===== C. matchAXWindow 匹配 =====
        do {
            let w1 = AXUIElementCreateApplication(1)
            let w2 = AXUIElementCreateApplication(2)
            let windows = [w1, w2]
            check("axdirect: matchAXWindow 命中",
                  WindowManager.matchAXWindow(windows, windowID: 42, handle: { $0 === w2 ? 42 : nil }) != nil)
            check("axdirect: matchAXWindow 全 nil handle → nil",
                  WindowManager.matchAXWindow(windows, windowID: 42, handle: { _ in nil }) == nil)
            check("axdirect: matchAXWindow 无匹配 → nil",
                  WindowManager.matchAXWindow(windows, windowID: 42, handle: { _ in 7 }) == nil)
            check("axdirect: matchAXWindow 空数组 → nil",
                  WindowManager.matchAXWindow([], windowID: 42, handle: { _ in 42 }) == nil)
        }

        // ===== D. runAXFrameWrite 假 IO：写序与收敛 =====
        do {
            let target = CGRect(x: 72, y: 38, width: 1656, height: 1079)
            let noSleep: (UInt32) -> Void = { _ in }
            let rec = AXWriteRecorder()

            // D1. 收窄序（resize→move），读回立即达标 → converged，事件序 [resize, move]。
            do {
                let outcome = WindowManager.runAXFrameWrite(
                    read: { target },
                    writeMove: { rec.events.append("move") },
                    writeResize: { rec.events.append("resize") },
                    target: target,
                    order: .resizeThenMove,
                    tolerance: 20,
                    op: "axd1", stage: "test", windowID: 1,
                    pollSleep: noSleep)
                check("axdirect: 收窄序事件序 [resize, move]", rec.events == ["resize", "move"])
                if case .converged = outcome { check("axdirect: 首轮达标 → converged", true) }
                else { check("axdirect: 首轮达标 → converged", false) }
            }

            // D2. 放大序（move→resize）。
            do {
                rec.events = []
                let outcome = WindowManager.runAXFrameWrite(
                    read: { target },
                    writeMove: { rec.events.append("move") },
                    writeResize: { rec.events.append("resize") },
                    target: target,
                    order: .moveThenResize,
                    tolerance: 20,
                    op: "axd2", stage: "test", windowID: 1,
                    pollSleep: noSleep)
                check("axdirect: 放大序事件序 [move, resize]", rec.events == ["move", "resize"])
                if case .converged = outcome { check("axdirect: 放大序首轮达标 → converged", true) }
                else { check("axdirect: 放大序首轮达标 → converged", false) }
            }

            // D3. AX 写异步落地（迟到读回）：move 后连续 4 读旧帧触发停滞幂等补发
            // （补发不算新一轮，见 convergeFramePolling），第二次 move 后读达标。
            // 行为锁 = converged + move 写 ≥2 次（写丢失/落地慢被读回驱动的重发自愈）。
            do {
                rec.events = []
                rec.moveWrites = 0
                let outcome = WindowManager.runAXFrameWrite(
                    read: { rec.read(target: target) },
                    writeMove: { rec.events.append("move"); rec.moveWrites += 1 },
                    writeResize: { rec.events.append("resize") },
                    target: target,
                    order: .resizeThenMove,
                    tolerance: 20,
                    op: "axd3", stage: "test", windowID: 1,
                    pollSleep: noSleep)
                if case .converged = outcome {
                    check("axdirect: 迟到读回收敛 → converged", true)
                } else {
                    check("axdirect: 迟到读回收敛 → converged", false)
                }
                check("axdirect: 迟到读回收敛 move 补发 ≥2 次", rec.moveWrites >= 2)
            }

            // D4. 永不达标 → mismatched（诚实失败，调用方按不收敛处置/回滚）。
            do {
                rec.events = []
                let outcome = WindowManager.runAXFrameWrite(
                    read: { nil },
                    writeMove: { rec.events.append("move") },
                    writeResize: { rec.events.append("resize") },
                    target: target,
                    order: .resizeThenMove,
                    tolerance: 20,
                    op: "axd4", stage: "test", windowID: 1,
                    pollSleep: noSleep)
                if case .mismatched = outcome { check("axdirect: 永不达标 → mismatched", true) }
                else { check("axdirect: 永不达标 → mismatched", false) }
                check("axdirect: 不收敛仍有补发写", rec.events.count > 2)
            }
        }
    }
}
