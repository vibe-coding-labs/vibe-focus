import Foundation

/// Session 级 UPS（UserPromptSubmit）滑动窗口限流器（Batch 14 从
/// HookEventHandler 内嵌 UPSRateWindow 提取为 internal——防自动化/循环会话
/// 无限搬窗的限流决策可单测穷尽）。
///
/// ## 场景
/// 远程机器 54+ 会话全部映射到同一窗口 → UPS 连发 → 窗口反复跳动。
/// 滑动窗口内注册事件数达到阈值即判限流。
///
/// ## 语义契约（Tests/Runner 真身穷尽锁定）
/// - 先剪枝（严格 `now - t < windowDuration` 为存活）后计数，再注册本次事件；
/// - 限流判定基于「本次注册前」的窗口内事件数（`>= maxEvents` 即限流）；
/// - 被限流的事件同样注册（计数持续增长，连发会持续被限）；
/// - 过期时间戳按值剪除（同一事件不会计两次）。
struct UPSRateLimiter {
    let windowDuration: TimeInterval
    let maxEvents: Int

    private var timestamps: [Date] = []

    init(windowDuration: TimeInterval, maxEvents: Int) {
        self.windowDuration = windowDuration
        self.maxEvents = maxEvents
    }

    /// 注册本次事件并判定是否限流。
    /// - Returns: `limited` = 窗口内存量事件数（不含本次）`>= maxEvents`；
    ///            `recentCount` = 剪枝后的窗口内存量事件数（供响应文案）。
    mutating func registerAndEvaluate(now: Date) -> (limited: Bool, recentCount: Int) {
        timestamps = timestamps.filter { now.timeIntervalSince($0) < windowDuration }
        let recentCount = timestamps.count
        timestamps.append(now)
        return (recentCount >= maxEvents, recentCount)
    }
}
