import Foundation
import CoreGraphics
@testable import VibeFocusKit

// 0.0.93 延迟归位（第六次收敛）：提交归位「提交后 ~3 秒执行，气泡正在输入则
// 顺延」。0.0.91 瞬间拽走与 0.0.92 失焦保持均被用户裁决否弃后的终局时机语义。
// 本文件锁定：DelayDecision 纯判定矩阵 / arm 幂等刷新（sessionID 保真）/
// 节拍状态机（到点 fire、气泡占用顺延、占用释放后下一拍即 fire、fire 消费登记）。
// executePending 的资格门复核复用 AutoRestoreRecordGate（E1~E7 已锁）+
// ToggleEngine.restore（restore 链路直测已锁），此处只锁分派缝。

extension RunnerHarness {
    func runSubmitRestoreDeferralTests() {
        print("\n=== SubmitRestoreDeferral (0.0.93 延迟归位) ===")

        // --- DelayDecision 纯判定矩阵 ---
        let armedAt = Date(timeIntervalSince1970: 1_000_000)
        func delay(now: Date, busy: Bool = false, delaySecs: TimeInterval = 3) -> SubmitRestoreDeferral.DelayDecision {
            SubmitRestoreDeferral.evaluateDelay(
                armedAt: armedAt, now: now, delaySeconds: delaySecs, isBusy: busy
            )
        }
        check("delay D1: 未到延迟 → keepWaiting(剩余秒)",
              delay(now: armedAt.addingTimeInterval(2)) == .keepWaiting(remainingSeconds: 1))
        check("delay D2: 恰到延迟且空闲 → fire",
              delay(now: armedAt.addingTimeInterval(3)) == .fire(elapsedSeconds: 3))
        check("delay D3: 过延迟且空闲 → fire",
              delay(now: armedAt.addingTimeInterval(3.5)) == .fire(elapsedSeconds: 3.5))
        check("delay D4: 到点但气泡正在输入 → postponedBusy（不 fire）",
              delay(now: armedAt.addingTimeInterval(30), busy: true) == .postponedBusy)
        check("delay D5: 未到点即使空闲也 keepWaiting（busy 与否不影响等待段）",
              delay(now: armedAt.addingTimeInterval(1), busy: true) == .keepWaiting(remainingSeconds: 2))
        check("delay D6: 自定义延迟窗生效",
              delay(now: armedAt.addingTimeInterval(5), busy: false, delaySecs: 10)
              == .keepWaiting(remainingSeconds: 5))
        check("delay D7: 时钟回拨（负耗时）不 fire",
              delay(now: armedAt.addingTimeInterval(-1)) == .keepWaiting(remainingSeconds: 4))

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

            // 前 2 拍未到点：keepWaiting 不 fire
            var busyTable: [UInt32: Bool] = [:]
            deferral.activityHoldProbe = { busyTable[$0] ?? false }
            deferral.evaluateBeat(now: t1.addingTimeInterval(1))
            deferral.evaluateBeat(now: t1.addingTimeInterval(2))
            check("beat C3: 延迟窗内不 fire，登记保留", fired.isEmpty
                  && deferral.pendingEntry(for: 42) != nil)

            // 第 3 秒到点：fire 并消费登记
            deferral.evaluateBeat(now: t1.addingTimeInterval(3))
            check("beat C4: 到点 fire 一次并消费登记",
                  fired.count == 1 && fired[0].windowID == 42
                  && fired[0].triggerSource == "input_bubble_submit"
                  && deferral.pendingWindowIDs.isEmpty)

            // 气泡占用顺延：到点但气泡开着 → 不 fire；关闭后下一拍即 fire
            deferral.arm(windowID: 7, triggerSource: "input_bubble_submit", sessionID: nil)
            let tBase = t1.addingTimeInterval(10)
            busyTable[7] = true
            deferral.evaluateBeat(now: tBase.addingTimeInterval(5))
            check("beat C5: 到点但气泡正在输入 → 顺延不 fire", fired.count == 1
                  && deferral.pendingEntry(for: 7) != nil)
            deferral.evaluateBeat(now: tBase.addingTimeInterval(20))
            check("beat C6: 占用持续仍不 fire（无最长持有上限=用户控制）", fired.count == 1)
            busyTable[7] = false
            deferral.evaluateBeat(now: tBase.addingTimeInterval(21))
            check("beat C7: 气泡关闭后下一拍即 fire", fired.count == 2 && fired[1].windowID == 7)

            // 登记被外部消费（⌃Q 手动还原）后节拍空转不误 fire
            deferral.arm(windowID: 9, triggerSource: "hook_user_prompt_submit", sessionID: nil)
            deferral.cancel(windowID: 9)
            deferral.evaluateBeat(now: tBase.addingTimeInterval(60))
            check("beat C8: 登记已被消费时节拍空转不误 fire", fired.count == 2)

            check("arm C9: 独立实例与生产 shared 互不串扰（Runner 内 shared 未被 arm）",
                  SubmitRestoreDeferral.shared.pendingWindowIDs.isEmpty)
            deferral.reset()
        }

        // --- 常量契约 ---
        check("const C10: 延迟=3s、节拍=1s（语义固化）",
              SubmitRestoreDeferral.restoreDelaySeconds == 3
              && SubmitRestoreDeferral.evaluationInterval == 1.0)

        print("=== SubmitRestoreDeferral done ===\n")
    }
}
