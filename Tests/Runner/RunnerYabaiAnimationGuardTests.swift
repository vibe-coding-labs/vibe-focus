import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerYabaiAnimationGuardTests.swift
// 靶：切换零动画总闸（2026-11-22）——参数逐字、节流窗口、查询解析、并发单发。
// 背景（yabai 源码 message.c / window_manager.c）：--move 与 --resize 的 animate 参数
// 硬编码 true，唯一开关是全局 window_animation_duration，没有 per-call 旁路。

final class YabaiAnimationGuardTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String]] = []
    /// 查询命令的 stdout（nil = fork 失败）。
    var stdout: String?

    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func record(_ args: [String]) {
        lock.lock(); defer { lock.unlock() }
        storage.append(args)
    }
}

extension RunnerHarness {
    func runYabaiAnimationGuardTests() {
        // A. 参数与纯判定
        do {
            check("yabaiAnim A1: 关断参数逐字为 -m config window_animation_duration 0.0",
                  YabaiAnimationConfig.disableArguments
                  == ["-m", "config", "window_animation_duration", "0.0"])
            check("yabaiAnim A2: 查询参数为 -m config window_animation_duration（无值）",
                  YabaiAnimationConfig.queryArguments
                  == ["-m", "config", "window_animation_duration"])
            check("yabaiAnim A3: 从未断言过 → 必须断言",
                  YabaiAnimationConfig.shouldAssert(last: nil, now: Date()))
            let now = Date()
            check("yabaiAnim A4: 节流窗口内（29s）不复断言",
                  !YabaiAnimationConfig.shouldAssert(
                    last: now.addingTimeInterval(-29), now: now))
            check("yabaiAnim A5: 跨过窗口（30s）必须复断言",
                  YabaiAnimationConfig.shouldAssert(
                    last: now.addingTimeInterval(-30), now: now))
        }

        // B. 查询解析：读到才认，读不到不猜
        do {
            check("yabaiAnim B1: 解析 yabai %f 输出 0.400000 → 0.4",
                  YabaiAnimationConfig.parseDuration("0.400000\n") == 0.4)
            check("yabaiAnim B2: 已经是 0 时解析为 0（不误判成 nil）",
                  YabaiAnimationConfig.parseDuration("0.000000") == 0)
            check("yabaiAnim B3: 空输出 → nil",
                  YabaiAnimationConfig.parseDuration("  \n") == nil)
            check("yabaiAnim B4: 非数值 → nil",
                  YabaiAnimationConfig.parseDuration("not-a-number") == nil)
        }

        // C. 节流语义：一次窗口只发一次令
        do {
            let state = YabaiAnimationGuardTestState()
            let unit = YabaiAnimationGuard { args in
                state.record(args)
                return nil
            }
            let t0 = Date()
            let first = unit.assertDisabled(now: t0, reason: "ut-first")
            check("yabaiAnim C1: 首次断言发令并返回 true", first)
            check("yabaiAnim C2: 首次发令参数 = 关断参数（仅此一条）",
                  state.calls == [YabaiAnimationConfig.disableArguments])
            let second = unit.assertDisabled(now: t0.addingTimeInterval(10), reason: "ut-second")
            check("yabaiAnim C3: 窗口内第二次断言被节流（返回 false、零新增发令）",
                  !second && state.calls.count == 1)
            let third = unit.assertDisabled(now: t0.addingTimeInterval(29.5), reason: "ut-third")
            check("yabaiAnim C4: 29.5s 仍在窗口内 → 不再发令",
                  !third && state.calls.count == 1)
            let fourth = unit.assertDisabled(now: t0.addingTimeInterval(30), reason: "ut-fourth")
            check("yabaiAnim C5: 满 30s → 再发一次令",
                  fourth && state.calls.count == 2)
            check("yabaiAnim C6: 两次发令参数完全一致（reason 不影响命令）",
                  state.calls == [YabaiAnimationConfig.disableArguments,
                                  YabaiAnimationConfig.disableArguments])
        }

        // D. 查询通道（currentDuration）
        do {
            let state = YabaiAnimationGuardTestState()
            let unit = YabaiAnimationGuard { args in
                state.record(args)
                return state.stdout
            }
            state.stdout = "0.250000\n"
            check("yabaiAnim D1: 读到当前值 0.25",
                  unit.currentDuration() == 0.25)
            check("yabaiAnim D2: 查询用的是无值形式（不会误改配置）",
                  state.calls == [YabaiAnimationConfig.queryArguments])
            state.stdout = nil
            check("yabaiAnim D3: fork 失败（nil stdout）→ nil，不猜默认值",
                  unit.currentDuration() == nil)
            state.stdout = ""
            check("yabaiAnim D4: 空 stdout → nil",
                  unit.currentDuration() == nil)
        }

        // E. 并发：多个线程同一时刻断言只发一次令（帧写入来自多线程）
        do {
            let state = YabaiAnimationGuardTestState()
            let unit = YabaiAnimationGuard { args in
                state.record(args)
                return nil
            }
            let now = Date()
            DispatchQueue.concurrentPerform(iterations: 16) { index in
                _ = unit.assertDisabled(now: now, reason: "ut-concurrent-\(index)")
            }
            check("yabaiAnim E1: 并发 16 次同刻断言只发一次令",
                  state.calls.count == 1)
        }
    }
}
