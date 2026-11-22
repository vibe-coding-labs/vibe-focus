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

        // A'. 写命令判定：所有会改窗口 frame 的命令都受总闸保护（2026-11-22 二次加固）
        // 背景：`--toggle float` 脱管后的布局重摆同样走 window_manager_animate_window
        // （view.c window_node_flush → animate_window_list），只覆盖 --move/--resize
        // 会让「切换」第一步先滑一下。
        do {
            func off(_ args: String...) -> Bool {
                YabaiAnimationConfig.requiresAnimationOff(arguments: args)
            }
            check("yabaiAnim A'1: --move/--resize 合发 → 需要断言",
                  off("-m", "window", "123", "--move", "abs:0:0", "--resize", "abs:10:10"))
            check("yabaiAnim A'2: --toggle float（脱管重摆会播动画）→ 需要断言",
                  off("-m", "window", "123", "--toggle", "float"))
            check("yabaiAnim A'3: window --focus → 需要断言",
                  off("-m", "window", "--focus", "123"))
            check("yabaiAnim A'4: space --focus → 需要断言",
                  off("-m", "space", "--focus", "2"))
            check("yabaiAnim A'5: window --zoom-fullscreen → 需要断言",
                  off("-m", "window", "123", "--zoom-fullscreen", "abs"))
            check("yabaiAnim A'6: config 带值（写全局配置）→ 需要断言",
                  off("-m", "config", "window_gap", "10"))
            check("yabaiAnim A'7: 未知域（未来新增写域）→ 保守断言",
                  off("-m", "map", "some", "command"))
            check("yabaiAnim A'8: --restart → 需要断言（重排全部窗口）",
                  off("--restart"))

            check("yabaiAnim A'9: query 域 → 不断言（纯读）",
                  !off("-m", "query", "--windows"))
            check("yabaiAnim A'10: config 无值（读当前值）→ 不断言",
                  !off("-m", "config", "window_animation_duration"))
            check("yabaiAnim A'11: signal 域 → 不断言",
                  !off("-m", "signal", "--remove", "vibefocus-space-changed"))
            check("yabaiAnim A'12: space <sel> 无子命令（只读选中）→ 不断言",
                  !off("-m", "space"))
            check("yabaiAnim A'13: window <sel> 无子命令（只读选中）→ 不断言",
                  !off("-m", "window"))
            check("yabaiAnim A'14: --load-sa → 不断言（不重排窗口）",
                  !off("--load-sa"))
            check("yabaiAnim A'15: 总闸自己的关断命令绝不递归断言",
                  !off("-m", "config", "window_animation_duration", "0.0"))
            check("yabaiAnim A'16: 总闸自己的查询命令绝不递归断言",
                  !off("-m", "config", "window_animation_duration"))

            // A''：读域白名单余项与畸形入参（判据是「白名单读」反推，漏一个读域就会
            // 给每条查询多挂一次 config 写；白名单外一律保守断言）。
            check("yabaiAnim A'17: display 域只改焦点显示器 → 不断言",
                  !off("-m", "display", "1"))
            check("yabaiAnim A'18: rule 域改规则表不立即重排 → 不断言",
                  !off("-m", "rule", "--add", "app=Terminal", "manage=off"))
            check("yabaiAnim A'19: 裸 -m（无域）→ 不断言且不越界",
                  !off("-m"))
            check("yabaiAnim A'20: -m 后跟未知域 → 保守断言",
                  off("-m", "mouse", "--zoom"))
            check("yabaiAnim A'21: 非 -m 顶层开关（--version）→ 不断言",
                  !off("--version"))
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

        // F. 写命令 + 发令前后双断言
        do {
            let state = YabaiAnimationGuardTestState()
            let unit = YabaiAnimationGuard { args in
                state.record(args)
                return nil
            }
            let t0 = Date()
            // 模拟普通写命令的 before/after 两次非强制调用（同一 now，窗口内）。
            _ = unit.assertDisabled(now: t0, reason: "yabai_write")
            _ = unit.assertDisabled(now: t0, reason: "yabai_write_after")
            check("yabaiAnim F1: 节流窗口内的前后双断言只落一次 config fork",
                  state.calls == [YabaiAnimationConfig.disableArguments])

            // 帧写入命令的后置收口是 force：即使节流窗口内也必发——那正是
            // 「这条命令自己的事件钩子把 yabairc 重新 source 了」要被堵上的时刻。
            let forced = unit.assertDisabled(now: t0, reason: "yabai_write_after", force: true)
            check("yabaiAnim F2: force 无视节流必发一次令",
                  forced && state.calls == [YabaiAnimationConfig.disableArguments,
                                            YabaiAnimationConfig.disableArguments])
            check("yabaiAnim F3: force 之后重置节流基准（紧接着的非强制断言被压掉）",
                  !unit.assertDisabled(now: t0.addingTimeInterval(1), reason: "next")
                  && state.calls.count == 2)
        }

        // F'. 启动断言（AppDelegate 在后台队列调用的那个函数本体）
        //
        // 启动编排（applicationDidFinishLaunching 里那行 DispatchQueue.async）是 C1 生命周期
        // 胶水，重入即重复启动，不可直测；但**被调函数**本身没有副作用边界，注入 runYabai
        // 即可直测——这轮动画修复的原始故障正是「判据对了但没接上」，所以这个函数必须有断言。
        do {
            let state = YabaiAnimationGuardTestState()
            let unit = YabaiAnimationGuard { args in
                state.record(args)
                return args == YabaiAnimationConfig.queryArguments ? "0.400000\n" : nil
            }
            unit.assertDisabledOnLaunch()
            let calls = state.calls
            check("yabaiAnim F'1: 启动先读原值再关断（query → config 写 两步）",
                  calls == [YabaiAnimationConfig.queryArguments,
                            YabaiAnimationConfig.disableArguments])
            check("yabaiAnim F'2: 启动断言不受节流影响（首次必有令）",
                  calls.contains(YabaiAnimationConfig.disableArguments))

            // 读不到原值（fork 失败）→ 仍然关断（不能让「读失败」挡住总闸）
            let blind = YabaiAnimationGuardTestState()
            let blindUnit = YabaiAnimationGuard { args in
                blind.record(args)
                return nil
            }
            blindUnit.assertDisabledOnLaunch()
            check("yabaiAnim F'3: 读不到原值仍关断总闸",
                  blind.calls == [YabaiAnimationConfig.queryArguments,
                                  YabaiAnimationConfig.disableArguments])
        }

        // G. 帧写入判定（决定后置断言是否 force）
        do {
            func frame(_ args: String...) -> Bool {
                YabaiAnimationConfig.mutatesWindowFrame(arguments: args)
            }
            check("yabaiAnim G1: --move/--resize 合发 → 是帧写入",
                  frame("-m", "window", "1", "--move", "abs:0:0", "--resize", "abs:9:9"))
            check("yabaiAnim G2: --toggle float → 是帧写入",
                  frame("-m", "window", "1", "--toggle", "float"))
            check("yabaiAnim G3: --zoom-fullscreen → 是帧写入",
                  frame("-m", "window", "1", "--zoom-fullscreen", "abs"))
            check("yabaiAnim G4: --toggle windowed-fullscreen → 是帧写入",
                  frame("-m", "window", "1", "--toggle", "windowed-fullscreen"))
            check("yabaiAnim G4b: --toggle zoom-fullscreen → 是帧写入",
                  frame("-m", "window", "1", "--toggle", "zoom-fullscreen"))
            // 只缺 size 的补发走单发 --resize（FrameWriteExecutor 段二 adaptive/robust），
            // 这条分支决定补发后是否强制复断言——生产高频，必须单独锁定。
            check("yabaiAnim G4c: 单发 --resize（无 --move/--toggle）→ 是帧写入",
                  frame("-m", "window", "1", "--resize", "abs:800:600"))
            check("yabaiAnim G4d: 只改位置的单发 --move → 是帧写入",
                  frame("-m", "window", "1", "--move", "abs:10:20"))
            check("yabaiAnim G4e: window 子命令但既不 move 也不 resize（--raise）→ 不是帧写入",
                  !frame("-m", "window", "1", "--raise"))
            check("yabaiAnim G5: --toggle shadow（不动机位）→ 不是帧写入",
                  !frame("-m", "window", "1", "--toggle", "shadow"))
            check("yabaiAnim G6: space --focus（不动窗口 frame）→ 不是帧写入",
                  !frame("-m", "space", "--focus", "2"))
            check("yabaiAnim G7: window --focus（不改 frame）→ 不是帧写入",
                  !frame("-m", "window", "--focus", "1"))
            check("yabaiAnim G8: query → 不是帧写入",
                  !frame("-m", "query", "--windows"))
        }
    }
}
