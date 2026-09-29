import Foundation

/// 提交归位在途标记（2026-09-28 日志审计批；0.0.92 起语义微调）。
///
/// 0.0.92 失焦归位后，气泡/UPS 提交决策点只登记 SubmitRestoreDeferral（幂等），
/// 不再在决策点占位；本注册表的 mark 仅由**执行点**（SubmitRestoreDeferral.
/// executePending 及其它真实开跑 restore 管线的入口）打——新鲜期内后到的重复
/// 触发（同窗二次提交/气泡登记撞上节拍开跑）诚实跳过，不重复跑全量 restore
/// 管线（含视角守卫 focus 链）。占位由新鲜期自然失效，不需要完成回调
/// （restore 管线在后台队列，成败不影响去重语义）。
final class RestoreInFlightRegistry: @unchecked Sendable {
    static let shared = RestoreInFlightRegistry()

    /// 标记新鲜期（秒）：气泡决策→UPS 到达实测 ≤2.5s；restore 全程最差 ~6s。
    static let freshnessSeconds: TimeInterval = 8

    private let lock = NSLock()
    private var markedAt: [UInt32: Date] = [:]

    /// 可注入时钟，测试用；生产恒为系统当前时间
    var now: () -> Date = { Date() }

    /// internal（非 private）：Runner 测试注入独立实例（MoveCooldownRegistry 同款）
    init() {}

    /// 纯函数：给定占位时刻与当前时间，判断标记是否仍新鲜
    static func isRecent(
        markedAt: Date?,
        now: Date,
        freshnessSeconds: TimeInterval = RestoreInFlightRegistry.freshnessSeconds
    ) -> Bool {
        guard let markedAt else { return false }
        return now.timeIntervalSince(markedAt) < freshnessSeconds
    }

    /// 该窗口是否有新鲜在途标记
    func isRecent(windowID: UInt32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return Self.isRecent(markedAt: markedAt[windowID], now: now())
    }

    /// 决策点占位（幂等，刷新时刻）
    func mark(windowID: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        markedAt[windowID] = now()
    }

    /// 测试复位
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        markedAt.removeAll()
    }
}
