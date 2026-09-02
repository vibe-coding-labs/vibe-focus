// ConditionPolling.swift
// VibeFocus — 等到位有界轮询唯一骨架（check → sleep → check → …，预算内即返回）
//
// 与 FrameConvergence（帧写入收敛）同属等待语义骨架族，但消费方向相反：
//   FrameConvergence：写 → 等 → 读回验证「写是否到位」；
//   ConditionPolling：轮询外部状态「是否到位」（space 可见性、float 状态等 yabai 异步落定）。
// 收敛此前 restore 链路的固定 usleep（拍脑袋值：等短了被 yabai 异步重摆覆盖，
// 等长了白耗时——2026-09-02 P1-2 等落定改等到位）。
// 预算/节拍常量唯一事实源为 WindowSettle（2.16 第九刀约定沿用）。

import Foundation

/// 等到位轮询结果。satisfied 携带在预算内第几次检查满足（1 = 首查即满足，未 sleep）；
/// exhausted 表示预算耗尽仍未满足。
enum ConditionPollOutcome: Equatable {
    case satisfied(checks: Int)
    case exhausted

    /// 是否在预算内到位（exhausted=false；调用方据此决定如实上报/降级）。
    var satisfied: Bool {
        if case .satisfied = self { return true }
        return false
    }
}

enum ConditionPolling {

    /// 有界轮询：先查后睡，budgetMs 内每 intervalMs 查一次；满足即返回。
    ///
    /// ## 语义契约（ConditionPollingTests 分支穷尽锁定）
    /// - 首查在首睡之前：状态已满足时零等待；
    /// - 每轮 sleep 时长 = min(intervalMs, 剩余预算)——最后一轮不长睡超预算；
    /// - budgetMs == 0：只做首查，不睡（退化为主观立即判定）；
    /// - 返回 satisfied(checks:) 或 exhausted，由调用方决定超时语义（重试/降级/如实上报）。
    static func waitUntil(
        intervalMs: UInt32,
        budgetMs: UInt32,
        sleep: (UInt32) -> Void = { usleep(useconds_t($0) * 1_000) },
        condition: () -> Bool
    ) -> ConditionPollOutcome {
        var checks = 0
        var waitedMs: UInt32 = 0
        checks += 1
        if condition() {
            return .satisfied(checks: checks)
        }
        while waitedMs < budgetMs {
            let remaining = budgetMs - waitedMs
            let nap = min(intervalMs, remaining)
            sleep(nap)
            waitedMs += nap
            checks += 1
            if condition() {
                return .satisfied(checks: checks)
            }
        }
        return .exhausted
    }
}
