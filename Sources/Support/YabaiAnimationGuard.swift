// YabaiAnimationGuard.swift
// VibeFocus — 切换零动画总闸（2026-11-22）
//
// ## 为什么必须由 App 主动关掉 yabai 的窗口动画
// yabai 的帧写入原语最终都落到 `window_manager_animate_window()`（window_manager.c）：
//   - `window --move abs:x:y`   → window_manager_move_window_relative → animate_window
//   - `window --resize abs:w:h` → window_manager_resize_window_relative(animate: true) → animate_window
// 该函数**唯一**的分支条件就是全局配置 `window_animation_duration`：
//   ```
//   if (g_window_manager.window_animation_duration) {
//       window_manager_animate_window_list_async(...);  // 建 SLS proxy + CVDisplayLink 插值
//   } else {
//       window_manager_set_window_frame(...);           // AX 直写，瞬时到位
//   }
//   ```
// message.c 里 `--move` / `--resize` 的 animate 参数是硬编码 true，**没有任何 per-call
// 旁路**（`handle_message` 一条消息只解析一个域，也不能把 config 与 window 串进同一次调用）。
// 所以只要用户 yabairc 里设过这个值，VibeFocus 每写一次 frame 就被拉成一段动画——
// 一个以「按键即到位」为卖点的效率工具，反而比手点还慢。用户 2026-11-22 的诉求是
// 「切换窗口的时候不要动画」，动画在这里没有任何信息价值。
//
// ## 不止 --move/--resize：所有会改窗口 frame 的写命令
// 2026-11-22 二次加固（用户再次投诉「切换的时候不要动画」）。`window_manager_animate_window`
// 的调用点远不止两个帧写入原语（yabai 源码实测）：
//   - `--move` / `--resize`：window_manager.c:342（move_window_relative）、:359 / :403
//     （resize_window_relative 的 animate 分支）；
//   - **`--toggle float` 脱管后的布局重摆**：message.c 走 window_manager_make_window_floating
//     → space_manager_untile_window → `window_node_flush` → view.c:378
//     `window_manager_animate_window_list`。float 脱管是 vf 每次切换的第一步，
//     所以「一按就看见窗口自己滑一下」正是它；
//   - `--toggle windowed-fullscreen` / `--zoom-fullscreen`（window_manager.c:2394 / :2399）；
//   - 任何触发 view 重摆的命令（`--space` / `--insert` / `--warp` / 布局配置变更…）。
// 这些命令走的是**同一个**全局总闸——没有 per-call 旁路。只覆盖 --move/--resize 意味着
// float 重摆那一跳在总闸被 yabairc reload 掉后照样播动画。故判定改为：
// 只要这条 yabai 命令属于「写窗口布局」域就断言（读查询除外）。
//
// ## 策略
// - **只降不升**：断言 `window_animation_duration = 0.0`，从不恢复用户原值。恢复等于把
//   用户明确要删掉的动画重新塞回来。
// - **启动断言 + 写入前/后节流复断言**：yabai 只在 yabairc 被重新 source 时改配置
//   （`yabai -m config --load-sa` 等），因此启动断言之后，任何写命令前后各做一次 30s
//   节流的复断言即可覆盖「用户 reload 了 yabairc」的场景；常态下写入路径零额外 fork。
// - **单一咽喉点**：接线在 `SpaceController.runYabai`（所有 yabai 写命令都从这里发令），
//   不散落在各调用点，新增写通道自动受保护。
//
// ## 语义契约（Runner YabaiAnimationGuard 域锁定）
// - 断言参数逐字为 `["-m", "config", "window_animation_duration", "0.0"]`；
// - `requiresAnimationOff(arguments:)`：写窗口布局域 → true；纯读查询（query / config 查询）→ false；
// - 节流窗口内不重复发令，跨过窗口后必再发一次（含并发调用只发一次）；
// - 查询解析失败/空输出返回 nil，不猜默认值。

import Foundation

/// yabai 动画配置的参数与判定（纯函数，无 IO）。
enum YabaiAnimationConfig {
    static let key = "window_animation_duration"
    /// 关断动画的发令参数（`-m config window_animation_duration 0.0`）。
    static let disableArguments = ["-m", "config", key, "0.0"]
    /// 读当前值的查询参数（yabai 无值形式打印 `%f`，见 message.c handle_domain_config）。
    static let queryArguments = ["-m", "config", key]
    /// 复断言节流窗口：30s 内最多一次，常态写入路径零额外 fork。
    static let reassertInterval: TimeInterval = 30

    /// 距上次断言是否已过节流窗口（`last == nil` 视为必须断言）。
    static func shouldAssert(
        last: Date?,
        now: Date,
        interval: TimeInterval = reassertInterval
    ) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// 解析 `yabai -m config window_animation_duration` 的 stdout（`"%f\n"`）。
    /// 空/非数值返回 nil——不把「没读到」误判成「已经是 0」。
    static func parseDuration(_ text: String) -> Float? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Float(trimmed)
    }

    /// 这条 yabai 命令是否可能让 yabai 播窗口动画（必须先把总闸拉到 0 再发）。
    ///
    /// 判据刻意取「白名单读命令」而不是「黑名单写命令」：新增的写命令（yabai 版本
    /// 升级带来新域）默认受保护，漏网的是只读，只会多一次无害的幂等 config 写。
    /// 读命令清单（yabai -m 的全部非写域）：
    ///   - `-m query ...`（所有查询）
    ///   - `-m config <key>`（无值形式 = 读当前值，见 message.c handle_domain_config）
    ///   - `-m signal ...`（发信号，不改窗口）
    ///   - `-m display ...`（display 域只改焦点显示器，窗口 frame 不动）
    ///   - `-m rule ...`（改规则表，不立即重排）
    ///   - `--load-sa` / `--version` / `--help`（SA 装载与自述）
    ///   - `-m space <sel>`（无子命令 = 只读选中 space，见 message.c：无 command 时直接返回）
    ///   - `-m window <sel>`（无子命令 = 只读，同理）
    /// 其余一律视为写：`window`/`space` 带子命令、`config <key> <value>`、`mouse`、
    /// `--restart` 等。
    static func requiresAnimationOff(arguments: [String]) -> Bool {
        // 总闸自己的命令绝不递归触发断言（`config <key> <value>` 形式本身会被判为写）。
        if arguments == disableArguments || arguments == queryArguments { return false }
        guard arguments.first == "-m" else {
            // 非 `-m` 形式的顶层开关（--load-sa / --restart / --version …）：只有
            // --restart 会重新加载配置并重排全部窗口，其余无窗口影响。
            return arguments.contains("--restart")
        }
        guard arguments.count >= 2 else { return false }
        switch arguments[1] {
        case "query", "signal", "display", "rule":
            return false
        case "config":
            // 无值 = 读；有值 = 写（yabai 唯一改全局配置的通道）。
            return arguments.count > 3
        case "space", "window":
            // 域选择器之后还有子命令才是写（`-m space --focus N`），无子命令是读。
            return arguments.count > 2
        default:
            // 未知域（含未来新增的写域 map/mouse 等）：保守断言。
            return true
        }
    }
}

/// 动画总闸：节流断言 `window_animation_duration = 0.0`。
/// 线程安全（写入发令来自窗口作业队列 / 主线程 / hook 路径多处）。
final class YabaiAnimationGuard: @unchecked Sendable {
    /// 生产单例：发令与查询都走 `SpaceController.runYabai`（统一日志与错误处理）。
    /// 先探二进制：没装 yabai 时静默返回 nil，不让启动路径刷一条 error 级日志。
    static let shared = YabaiAnimationGuard { arguments in
        guard SpaceController.shared.locateYabai() != nil else { return nil }
        return SpaceController.shared.runYabai(
            arguments: arguments,
            operation: "animation-guard",
            operationID: "animation-guard"
        )?.stdout
    }

    private let lock = NSLock()
    private var lastAssertedAt: Date?
    private let runYabai: ([String]) -> String?

    init(runYabai: @escaping ([String]) -> String?) {
        self.runYabai = runYabai
    }

    /// 必要时关断动画；返回本次是否真的发了令（节流命中返回 false）。
    @discardableResult
    func assertDisabled(now: Date = Date(), reason: String) -> Bool {
        lock.lock()
        let due = YabaiAnimationConfig.shouldAssert(last: lastAssertedAt, now: now)
        if due { lastAssertedAt = now }
        lock.unlock()
        guard due else { return false }
        _ = runYabai(YabaiAnimationConfig.disableArguments)
        log("[YabaiAnimationGuard] window_animation_duration set to 0.0", fields: [
            "reason": reason
        ])
        return true
    }

    /// 读当前动画时长（仅供启动时留证；读不到返回 nil）。
    func currentDuration() -> Float? {
        runYabai(YabaiAnimationConfig.queryArguments)
            .flatMap(YabaiAnimationConfig.parseDuration)
    }

    /// 启动时先记下原值再关断——日志里能看到「用户原来设的是多少」，
    /// 便于日后排查「我明明关了 yabai 动画怎么还在」这类问题。
    func assertDisabledOnLaunch() {
        let before = currentDuration()
        let disabled = assertDisabled(reason: "launch")
        log("[YabaiAnimationGuard] launch check", fields: [
            "previousDuration": before.map { String($0) } ?? "unknown",
            "disabled": String(disabled)
        ])
    }
}
