import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerRestoreInFlightTests.swift — 2026-09-28 日志审计批：
// 气泡/UPS 双通道提交归位在途标记（RestoreInFlightRegistry）。
// 背景：B176 假设「气泡先清记录、~2s 后到达的 UPS 见无记录 → stay」实测不总
// 成立（UPS 常更快到达），两条全量 restore 管线（含视角守卫 focus 链）背靠背
// 执行（09-28 当天 bubble restore 42 次 vs UPS restore 19 次的竞速实录）。
// 修法 = 双方决策点（主线程）先查后占，后到者诚实跳过；占位由新鲜期自然失效。

extension RunnerHarness {

    func runRestoreInFlightTests() {

        do {
            let reg = RestoreInFlightRegistry()
            var t = Date(timeIntervalSince1970: 1_000_000)
            reg.now = { t }

            check("inflight: 无标记 → 不在途", !reg.isRecent(windowID: 7))
            reg.mark(windowID: 7)
            check("inflight: 占位后新鲜期内 → 在途", reg.isRecent(windowID: 7))
            t = t.addingTimeInterval(RestoreInFlightRegistry.freshnessSeconds - 1)
            check("inflight: 新鲜期边界内（严格 <）仍在途", reg.isRecent(windowID: 7))
            t = t.addingTimeInterval(2)
            check("inflight: 超新鲜期自然失效（无完成回调依赖）", !reg.isRecent(windowID: 7))
            reg.mark(windowID: 7)
            check("inflight: 重复占位幂等刷新时刻", reg.isRecent(windowID: 7))
            check("inflight: 其它窗口互不干扰", !reg.isRecent(windowID: 8))
            reg.reset()
            check("inflight: reset 清空全部标记", !reg.isRecent(windowID: 7) && !reg.isRecent(windowID: 8))

            // 纯函数边界
            check("inflight 纯函数: nil → false",
                  !RestoreInFlightRegistry.isRecent(markedAt: nil, now: t))
            check("inflight 纯函数: 恰在新鲜期边界已过期（严格 <）",
                  !RestoreInFlightRegistry.isRecent(
                    markedAt: t.addingTimeInterval(-RestoreInFlightRegistry.freshnessSeconds), now: t))
            check("inflight 纯函数: 新鲜期内为真",
                  RestoreInFlightRegistry.isRecent(markedAt: t.addingTimeInterval(-1), now: t))
            check("inflight 生产参数: 新鲜期 8s（覆盖气泡决策→UPS 到达 ≤2.5s 实测 + restore 全程）",
                  RestoreInFlightRegistry.freshnessSeconds == 8)
        }
    }
}
