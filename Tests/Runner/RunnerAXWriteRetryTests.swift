import AppKit
import ApplicationServices.HIServices
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerAXWriteRetryTests.swift — 覆盖率批次 29（B260）：
// WindowManager+AXWrite 的 writeSizeWithReadback/writePosition 提缝 internal
// （B260 提缝，仅可见性零行为变更）后直测无授权失败分支——生产「AX 不可写 →
// fallback yabai」降级链的核心重试编排。systemWide 元素零授权创建；
// settleDelayMicros=0 让重试循环毫秒级完成（参数化正是为了测试可控）。

extension RunnerHarness {
    func runAXWriteRetryTests() {
        let wm = WindowManager.shared
        let systemWide = AXUIElementCreateSystemWide()
        let target = CGRect(x: 10, y: 20, width: 800, height: 600)

        // writeSizeWithReadback：无授权 → 全部尝试失败 → axOK=false（重试 2 次耗尽）。
        let sizeOutcome = wm.writeSizeWithReadback(
            targetFrame: target, window: systemWide,
            attempts: 2, settleDelayMicros: 0,
            op: "b260-test", stage: "size", windowID: 0xB260)
        check("axWriteRetry: size readback 无授权 axOK=false（降级链入口）",
              sizeOutcome.axOK == false && sizeOutcome.matched == false)
        check("axWriteRetry: 失败时耗时字段仍如实落账",
              sizeOutcome.writeSetMs >= 0 && sizeOutcome.readbackMs >= 0)

        // writePosition：无授权 → AXValueCreate 成功但 AXUIElementSetAttributeValue
        // 失败 → false（writeMs inout 参数由调用方持有）。
        var positionWriteMs = 0
        let positionOK = wm.writePosition(
            targetFrame: target, window: systemWide,
            op: "b260-test", stage: "position", writeMs: &positionWriteMs)
        check("axWriteRetry: position 无授权 → false",
              positionOK == false)
        check("axWriteRetry: position writeMs inout 回写非负",
              positionWriteMs >= 0)
    }
}
