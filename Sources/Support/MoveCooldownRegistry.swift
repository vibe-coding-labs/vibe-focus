// MoveCooldownRegistry.swift
// VibeFocus — 窗口自动恢复冷却注册表（hook 层与引擎层之间的中立共享状态）

import Foundation

/// 记录"窗口刚被移动/恢复"的时刻，供 hook 事件（Stop/UserPromptSubmit）在冷却期内
/// 跳过对同一窗口的重复移动。冷却窗口 30s（严格小于）。
///
/// 历史注（playbook 2.16 第七刀）：原为 HookEventHandler 私有字典
/// `lastAutoRestoreByWindowID`，WindowManager（引擎层）restore/move_to_main 后直接调
/// HookEventHandler.shared 增删，形成 Hook→Window→Hook 单例环。抽出本中立注册表后，
/// 两侧只依赖本类型，环断开；冷却语义与时长不变。
///
/// 竞态风险：B180 起 hook 移动链在 WindowWorkExecutor 执行、B191 起手动 toggle
/// 重核心同样下放——读（hook 事件决策，主线程）与写（移动完成回调，执行队列/
/// 主线程混布）不再天然串行，改 NSLock 守护（临界区只有字典读写，µs 级）；
/// 冷却起点即落定时刻，语义不变。
final class MoveCooldownRegistry: @unchecked Sendable {
    static let shared = MoveCooldownRegistry()

    /// 冷却窗口时长（秒）；边界语义：恰好 30s 前的记录不算冷却（严格 <）
    static let cooldownSeconds: TimeInterval = 30

    private let lock = NSLock()
    private var lastMoveByWindowID: [UInt32: Date] = [:]

    /// 可注入时钟，测试用；生产恒为系统当前时间
    var now: () -> Date = { Date() }

    init() {}

    // MARK: - Pure Logic

    /// 纯函数：给定最近移动时刻与当前时间，判断是否仍在冷却期内
    static func isInCooldown(
        lastMove: Date?,
        now: Date,
        cooldownSeconds: TimeInterval = MoveCooldownRegistry.cooldownSeconds
    ) -> Bool {
        guard let lastMove else { return false }
        return now.timeIntervalSince(lastMove) < cooldownSeconds
    }

    /// 冷却剩余秒数（向上取整，仅供日志展示）；无记录时返回 0
    static func remainingSeconds(lastMove: Date?, now: Date, cooldownSeconds: TimeInterval = MoveCooldownRegistry.cooldownSeconds) -> Int {
        guard let lastMove else { return 0 }
        let remaining = cooldownSeconds - now.timeIntervalSince(lastMove)
        return remaining > 0 ? Int(remaining.rounded(.up)) : 0
    }

    // MARK: - Registry Ops

    /// 窗口是否仍在冷却期内
    func isInCooldown(windowID: UInt32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return Self.isInCooldown(lastMove: lastMoveByWindowID[windowID], now: now())
    }

    /// 冷却剩余秒数（日志展示用）；无记录时返回 0
    func remainingSeconds(windowID: UInt32) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return Self.remainingSeconds(lastMove: lastMoveByWindowID[windowID], now: now())
    }

    /// 标记窗口进入冷却（移动/恢复成功后调用）
    func setCooldown(windowID: UInt32) {
        lock.lock()
        lastMoveByWindowID[windowID] = now()
        lock.unlock()
    }

    /// 解除窗口冷却（引擎手动 move_to_main 后调用，允许后续 hook 立即操作该窗口）
    func clearCooldown(windowID: UInt32) {
        lock.lock()
        lastMoveByWindowID.removeValue(forKey: windowID)
        lock.unlock()
    }
}
