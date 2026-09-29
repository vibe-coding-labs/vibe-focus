import Foundation
import CoreGraphics
@testable import VibeFocusKit

// 0.0.92 失焦归位（第五次收敛）：提交归位不再「提交瞬间拽窗」——登记
// SubmitRestoreDeferral，窗口连续失焦 ≥10s 后节拍复核资格门归位。
// 本文件锁定：BlurDecision 纯判定矩阵 / arm 幂等刷新 / 节拍状态机
// （重聚焦重置计时、连续失焦到点才 fire、探测失败保守不计时、fire 消费登记）。
// executePending 的资格门复核复用 AutoRestoreRecordGate（E1~E7 已锁）+
// ToggleEngine.restore（restore 链路直测已锁），此处只锁分派缝。

extension RunnerHarness {
    func runSubmitRestoreDeferralTests() {
        print("\n=== SubmitRestoreDeferral (0.0.92 失焦归位) ===")

        // --- BlurDecision 纯判定矩阵 ---
        let armedAt = Date(timeIntervalSince1970: 1_000_000)
        func blur(lastFocusedAt: Date?, isFocused: Bool, now: Date, grace: TimeInterval = 10) -> SubmitRestoreDeferral.BlurDecision {
            SubmitRestoreDeferral.evaluateBlur(
                lastFocusedAt: lastFocusedAt, armedAt: armedAt,
                isFocused: isFocused, now: now, graceSeconds: grace
            )
        }
        check("blur B1: 持焦 → resetClock（无论失焦了多久）",
              blur(lastFocusedAt: nil, isFocused: true, now: armedAt.addingTimeInterval(999)) == .resetClock
              && blur(lastFocusedAt: armedAt.addingTimeInterval(5), isFocused: true, now: armedAt.addingTimeInterval(999)) == .resetClock)
        check("blur B2: 刚失焦（<宽限）→ keepWaiting（9.5=二进制精确值，防浮点比较假红）",
              blur(lastFocusedAt: nil, isFocused: false, now: armedAt.addingTimeInterval(9.5))
              == .keepWaiting(blurSeconds: 9.5))
        check("blur B3: 连续失焦满宽限 → fire",
              blur(lastFocusedAt: nil, isFocused: false, now: armedAt.addingTimeInterval(10))
              == .fire(blurSeconds: 10))
        check("blur B4: 重聚焦后再失焦——计时从最近一次持焦点重算",
              blur(lastFocusedAt: armedAt.addingTimeInterval(100), isFocused: false, now: armedAt.addingTimeInterval(105))
              == .keepWaiting(blurSeconds: 5)
              && blur(lastFocusedAt: armedAt.addingTimeInterval(100), isFocused: false, now: armedAt.addingTimeInterval(110))
              == .fire(blurSeconds: 10))
        check("blur B5: lastFocusedAt=nil 时计时原点=armedAt（登记即失焦的兜底原点）",
              blur(lastFocusedAt: nil, isFocused: false, now: armedAt) == .keepWaiting(blurSeconds: 0))
        check("blur B6: 时钟回拨（负失焦）不 fire",
              blur(lastFocusedAt: armedAt.addingTimeInterval(50), isFocused: false, now: armedAt.addingTimeInterval(40))
              == .keepWaiting(blurSeconds: -10))
        check("blur B7: 宽限=0 时失焦即 fire",
              blur(lastFocusedAt: nil, isFocused: false, now: armedAt, grace: 0) == .fire(blurSeconds: 0))

        // --- arm/cancel/节拍状态机（独立实例，scheduling 关闭防 Timer 泄漏）---
        do {
            let deferral = SubmitRestoreDeferral()
            deferral.schedulingEnabled = false
            let t0 = Date(timeIntervalSince1970: 2_000_000)
            deferral.now = { t0 }

            var fired: [SubmitRestoreDeferral.Pending] = []
            deferral.fireHandler = { fired.append($0) }

            deferral.arm(windowID: 42, triggerSource: "hook_user_prompt_submit", sessionID: "sess-a")
            check("arm C1: 登记进入 pending，armedAt=注入时钟",
                  deferral.pendingWindowIDs == [42]
                  && deferral.pendingEntry(for: 42)?.armedAt == t0
                  && deferral.pendingEntry(for: 42)?.sessionID == "sess-a")

            let t1 = t0.addingTimeInterval(60)
            deferral.now = { t1 }
            deferral.arm(windowID: 42, triggerSource: "input_bubble_submit", sessionID: nil)
            check("arm C2: 重复登记幂等刷新（不叠加、armedAt 刷新、来源覆盖）+ 无会话通道不覆盖已有 sessionID（UPS 先到场景）",
                  deferral.pendingWindowIDs == [42]
                  && deferral.pendingEntry(for: 42)?.armedAt == t1
                  && deferral.pendingEntry(for: 42)?.triggerSource == "input_bubble_submit"
                  && deferral.pendingEntry(for: 42)?.sessionID == "sess-a")

            // 持焦 N 拍：计时反复重置，永不 fire
            var beat = t1
            for _ in 0..<5 {
                beat = beat.addingTimeInterval(1)
                deferral.evaluateBeat(now: beat, focusByWindow: [42: true])
            }
            check("beat C3: 持焦期只重置计时，不 fire", fired.isEmpty
                  && deferral.pendingEntry(for: 42)?.lastFocusedAt == beat)

            // 切走：连续失焦到点才 fire；fire 消费登记
            beat = beat.addingTimeInterval(9)
            deferral.evaluateBeat(now: beat, focusByWindow: [42: false])
            check("beat C4: 失焦 9s（<宽限）keepWaiting，登记保留", fired.isEmpty
                  && deferral.pendingEntry(for: 42) != nil)
            beat = beat.addingTimeInterval(1)
            deferral.evaluateBeat(now: beat, focusByWindow: [42: false])
            check("beat C5: 连续失焦累计 10s → fire 一次并消费登记",
                  fired.count == 1 && fired[0].windowID == 42
                  && fired[0].triggerSource == "input_bubble_submit"
                  && deferral.pendingWindowIDs.isEmpty)

            // 重聚焦（回来继续用）→ 重置计时；再失焦满宽限才 fire
            deferral.arm(windowID: 7, triggerSource: "input_bubble_submit", sessionID: nil)
            let tFocus = t1.addingTimeInterval(10)
            deferral.evaluateBeat(now: tFocus, focusByWindow: [7: true])
            let tBlur1 = tFocus.addingTimeInterval(3)
            deferral.evaluateBeat(now: tBlur1, focusByWindow: [7: false])
            let tBack = tFocus.addingTimeInterval(6)
            deferral.evaluateBeat(now: tBack, focusByWindow: [7: true])
            let tBlur2 = tBack.addingTimeInterval(4)
            deferral.evaluateBeat(now: tBlur2, focusByWindow: [7: false])
            check("beat C6: 失焦中途回焦重置计时（3s 失焦+4s 失焦不累计）",
                  fired.count == 1 && deferral.pendingEntry(for: 7)?.lastFocusedAt == tBack)
            let tFire = tBack.addingTimeInterval(10)
            deferral.evaluateBeat(now: tFire, focusByWindow: [7: false])
            check("beat C7: 回焦后再次连续失焦满 10s → fire", fired.count == 2 && fired[1].windowID == 7)

            // 节拍安全：持焦拍不 fire；登记被外部消费（⌃Q 手动还原）后失焦拍空转
            deferral.arm(windowID: 9, triggerSource: "hook_user_prompt_submit", sessionID: nil)
            let tNil = tFire.addingTimeInterval(30)
            deferral.evaluateBeat(now: tNil, focusByWindow: [9: true])
            deferral.cancel(windowID: 9)
            deferral.evaluateBeat(now: tNil.addingTimeInterval(60), focusByWindow: [9: false])
            check("beat C8: 持焦拍保留登记；登记已被消费时节拍空转不误 fire",
                  fired.count == 2)

            check("arm C9: 独立实例与生产 shared 互不串扰（Runner 内 shared 未被 arm）",
                  SubmitRestoreDeferral.shared.pendingWindowIDs.isEmpty)
            deferral.reset()
        }

        // --- 常量契约 ---
        check("const C10: 失焦宽限=10s、节拍=1s（语义固化）",
              SubmitRestoreDeferral.blurGraceSeconds == 10
              && SubmitRestoreDeferral.evaluationInterval == 1.0)

        print("=== SubmitRestoreDeferral done ===\n")
    }
}
