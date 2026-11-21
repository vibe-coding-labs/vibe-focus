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
// ## 策略
// - **只降不升**：断言 `window_animation_duration = 0.0`，从不恢复用户原值。恢复等于把
//   用户明确要删掉的动画重新塞回来。
// - **启动断言 + 写入前节流复断言**：yabai 只在 yabairc 被重新 source 时改配置
//   （`yabai -m config --load-sa` 等），因此启动断言之后，任何帧写入前再做一次 30s
//   节流的复断言即可覆盖「用户 reload 了 yabairc」的场景；常态下写入路径零额外 fork。
// - **单一咽喉点**：接线在 `SpaceController.runYabai`（所有 yabai 帧写入都从这里发令），
//   不散落在各调用点，新增写通道自动受保护。
//
// ## 语义契约（Runner YabaiAnimationGuard 域锁定）
// - 断言参数逐字为 `["-m", "config", "window_animation_duration", "0.0"]`；
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
