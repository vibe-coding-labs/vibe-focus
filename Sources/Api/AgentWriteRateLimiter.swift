import Foundation

// Agent 命令接口写操作限流（审计收官报告剩余风险台账核销项）。
// 威胁模型：token 泄露或 agent 失控循环时，把「每秒都在动窗口」的最坏情形
// 钳到「数秒一次」；60 秒滑动窗口、按写操作（POST 端点）计数，读操作不限
// （读无破坏性且是感知通道）。进程内内存态——重启即清，无需持久化。

@MainActor
enum AgentWriteRateLimiter {

    static let windowSeconds: TimeInterval = 60
    static let maxWrites = 30

    private static var timestamps: [Date] = []

    /// 纯判定（Runner 直测）：滑动窗口内的写次数仍低于上限 → 放行。
    static func decide(timestamps: [Date], now: Date, windowSeconds: TimeInterval, maxWrites: Int) -> Bool {
        let inWindow = timestamps.filter { now.timeIntervalSince($0) < windowSeconds }
        return inWindow.count < maxWrites
    }

    /// 写操作登记 + 判定。true=放行，false=限流（调用方回 429 rate_limited）。
    @discardableResult
    static func registerWrite(now: Date = Date()) -> Bool {
        let allowed = decide(timestamps: timestamps, now: now,
                             windowSeconds: windowSeconds, maxWrites: maxWrites)
        guard allowed else { return false }
        timestamps.append(now)
        // 顺带清出窗口外旧戳，防长会话无界增长
        timestamps.removeAll { now.timeIntervalSince($0) >= windowSeconds }
        return true
    }

    /// 测试隔离（Runner 域共享静态态，批 21 结果盒错位同款教训）。
    static func resetForTesting() {
        timestamps.removeAll()
    }
}
