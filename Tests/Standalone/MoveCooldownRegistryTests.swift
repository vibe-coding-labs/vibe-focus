// Tests/Standalone/MoveCooldownRegistryTests.swift
// Verification: MoveCooldownRegistry 冷却注册表逻辑（判定纯函数 + 剩余秒数 + 注册表操作语义）
// Mirrors: Sources/Support/MoveCooldownRegistry.swift
//          （isInCooldown / remainingSeconds / setCooldown / clearCooldown，
//            Hook→Window→Hook 断环后的中立共享状态）
// Run: swift Tests/Standalone/MoveCooldownRegistryTests.swift
//
// 背景（playbook 2.16 第七刀）：冷却原为 HookEventHandler 私有字典，WindowManager
// 直接增删形成单例环。抽成中立注册表后两侧只依赖本类型。本测试锁定冷却语义：
// 30s 窗口、严格 < 边界、覆盖写、清除即放行、剩余秒数向上取整。

import Foundation

// MARK: - Extracted pure logic

/// Mirrors MoveCooldownRegistry.isInCooldown(lastMove:now:cooldownSeconds:)
func mirrorIsInCooldown(lastMove: Date?, now: Date, cooldownSeconds: TimeInterval = 30) -> Bool {
    guard let lastMove else { return false }
    return now.timeIntervalSince(lastMove) < cooldownSeconds
}

/// Mirrors MoveCooldownRegistry.remainingSeconds(lastMove:now:cooldownSeconds:)
func mirrorRemainingSeconds(lastMove: Date?, now: Date, cooldownSeconds: TimeInterval = 30) -> Int {
    guard let lastMove else { return 0 }
    let remaining = cooldownSeconds - now.timeIntervalSince(lastMove)
    return remaining > 0 ? Int(remaining.rounded(.up)) : 0
}

/// Mirrors MoveCooldownRegistry 注册表操作（set 覆盖写 / clear 放行）
struct MirrorCooldownStore {
    private var lastMoveByWindowID: [UInt32: Date] = [:]

    mutating func setCooldown(windowID: UInt32, at: Date) { lastMoveByWindowID[windowID] = at }
    mutating func clearCooldown(windowID: UInt32) { lastMoveByWindowID.removeValue(forKey: windowID) }
    func isInCooldown(windowID: UInt32, now: Date) -> Bool {
        mirrorIsInCooldown(lastMove: lastMoveByWindowID[windowID], now: now)
    }
    func remainingSeconds(windowID: UInt32, now: Date) -> Int {
        mirrorRemainingSeconds(lastMove: lastMoveByWindowID[windowID], now: now)
    }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

// MARK: 1. 判定纯函数 — 冷却窗口与边界

print("1. isInCooldown — 冷却窗口与边界")

let now = Date()
check("无记录 → 不在冷却", !mirrorIsInCooldown(lastMove: nil, now: now))
check("5s 前移动 → 在冷却", mirrorIsInCooldown(lastMove: now.addingTimeInterval(-5), now: now))
check("29.9s 前移动 → 在冷却", mirrorIsInCooldown(lastMove: now.addingTimeInterval(-29.9), now: now))
check("恰好 30s 前 → 不在冷却（严格 <）", !mirrorIsInCooldown(lastMove: now.addingTimeInterval(-30), now: now))
check("31s 前 → 不在冷却", !mirrorIsInCooldown(lastMove: now.addingTimeInterval(-31), now: now))
check("未来时刻 → 在冷却（时钟回拨防御，宽进严出）", mirrorIsInCooldown(lastMove: now.addingTimeInterval(5), now: now))
check("cooldown=0 → 永不在冷却", !mirrorIsInCooldown(lastMove: now.addingTimeInterval(-0.001), now: now, cooldownSeconds: 0))

// MARK: 2. 剩余秒数 — 向上取整语义（仅日志展示）

print("\n2. remainingSeconds — 展示语义")

check("无记录 → 0", mirrorRemainingSeconds(lastMove: nil, now: now) == 0)
check("5s 前移动 → 剩 25", mirrorRemainingSeconds(lastMove: now.addingTimeInterval(-5), now: now) == 25)
check("29.1s 前移动 → 剩 1（0.9 向上取整）", mirrorRemainingSeconds(lastMove: now.addingTimeInterval(-29.1), now: now) == 1)
check("29.9s 前移动 → 剩 1（0.1 向上取整）", mirrorRemainingSeconds(lastMove: now.addingTimeInterval(-29.9), now: now) == 1)
check("恰好 30s → 剩 0", mirrorRemainingSeconds(lastMove: now.addingTimeInterval(-30), now: now) == 0)
check("35s 前（已过期）→ 0（不返回负数）", mirrorRemainingSeconds(lastMove: now.addingTimeInterval(-35), now: now) == 0)

// MARK: 3. 注册表操作语义 — set 覆盖写 / clear 放行 / 窗口隔离

print("\n3. 注册表语义 — set/clear/窗口隔离")

var store = MirrorCooldownStore()
let t0 = now

store.setCooldown(windowID: 42, at: t0)
check("set 后立即在冷却", store.isInCooldown(windowID: 42, now: t0.addingTimeInterval(1)))

store.setCooldown(windowID: 42, at: t0.addingTimeInterval(20))
check("覆盖写：第二次 set 重置冷却起点（20s 时刻再判，剩 10s 冷却）",
      store.isInCooldown(windowID: 42, now: t0.addingTimeInterval(40)))
check("覆盖写：若按第一次起点 20s 已过期，按第二次起点仍在冷却",
      store.remainingSeconds(windowID: 42, now: t0.addingTimeInterval(40)) == 10)

store.clearCooldown(windowID: 42)
check("clear 后不在冷却（引擎 move_to_main 放行 hook 立即操作）",
      !store.isInCooldown(windowID: 42, now: t0.addingTimeInterval(41)))
check("clear 后剩余为 0", store.remainingSeconds(windowID: 42, now: t0.addingTimeInterval(41)) == 0)

store.setCooldown(windowID: 7, at: t0)
check("窗口隔离：窗口 7 在冷却不影响窗口 8", !store.isInCooldown(windowID: 8, now: t0.addingTimeInterval(1)))
check("窗口隔离：窗口 7 自己在冷却", store.isInCooldown(windowID: 7, now: t0.addingTimeInterval(1)))

// 对不存在的窗口 clear 是无害空操作
store.clearCooldown(windowID: 999)
check("clear 未知窗口 → 无害", !store.isInCooldown(windowID: 999, now: now))

// MARK: 4. 断环契约 — 依赖方向（静态约束的文档化断言）

print("\n4. 断环契约 — 冷却归属中立注册表")

// 语义断言：冷却状态必须独立于任何 hook 会话/处理器生命周期。
// 场景：Stop 移动设置冷却 → （任何事件路径）→ UPS 30s 内不得再动同一窗口；
// 引擎手动 move_to_main 清除冷却 → UPS 立即可操作。
var flow = MirrorCooldownStore()
flow.setCooldown(windowID: 100, at: t0)                                   // Stop 移动成功 → set
check("Stop 移动后 UPS 30s 内被冷却拦下", flow.isInCooldown(windowID: 100, now: t0.addingTimeInterval(2)))
flow.clearCooldown(windowID: 100)                                          // 引擎手动 move_to_main → clear
check("引擎手动归位后 UPS 立即可操作", !flow.isInCooldown(windowID: 100, now: t0.addingTimeInterval(3)))
flow.setCooldown(windowID: 100, at: t0.addingTimeInterval(3))              // UPS 移动成功 → set
check("UPS 移动后 Stop 在冷却期内跳过", flow.isInCooldown(windowID: 100, now: t0.addingTimeInterval(4)))

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
