import AppKit
import Foundation

// MARK: - Toggle 无窗口前台兜底（windowless-frontmost fallback）
// 真机实证（2026-09-06 toggle-00000182）：前台是 SystemUIServer 这类「没有 layer-0 可见窗口」
// 的系统进程时，三级焦点解析（CGWindowList candidatesCount=0 → yabai "could not retrieve
// window details" → AX 空）全部落空，toggle 以 "focused window identity missing" 死终——
// 用户视角就是 ⌃Q 按了没反应，且焦点停在系统表面期间每次按都如此。
//
// 兜底语义：前台 app 存在但一个候选窗口都没有 = 焦点被系统表面劫持（常见于 toggle 自身
// focus 失败、app 被杀后的残留态）。此时用户按 ⌃Q 的意图是「翻当前最前面的普通窗口」，
// 故取 CGWindowList z-order 最先命中的普通用户窗口继续走正常决策
// （有 record → restore；主屏 → stuck 解堵；其余 → move_to_main），并留 fallback 日志字段。

/// z-order 最前的可 toggle 普通用户窗口（纯函数，便于单测；z-order 前→后取第一个命中）。
///
/// ## 边界（为什么不是通用 fallback）
/// - 仅当「前台 app 本身没有任何候选窗口」时调用：正常 app 解析失败（yabai 挂 / AX 阻塞）
///   时禁用——多窗口 app 的 CGWindowList z-order ≠ AX focus（P0.3 教训），乱兜底会翻错窗口。
/// - 无状态、每次实时计算：焦点身份禁止缓存（P3.4 回归：缓存命中导致永远操作旧窗口）。
///
/// - Parameters:
///   - snapshot: `cgWindowListAll()` 快照（z-order 前→后）。
///   - ownPID: 本进程 pid——overlay 等自身窗口必须排除，否则 ⌃Q 会翻 VibeFocus 自己的浮层。
///   - activationPolicyOf: pid → 激活策略（生产用 `NSRunningApplication`；测试注入纯表）。
///     仅 `.regular` 合格：SystemUIServer/Dock/ControlCenter 等 .accessory/.prohibited 进程
///     即使有 layer-0 窗口也不可充当 toggle 目标。
func pickFallbackFrontWindow(
    snapshot: [CGWindowEntry],
    ownPID: pid_t,
    activationPolicyOf: (pid_t) -> NSApplication.ActivationPolicy?
) -> CGWindowEntry? {
    snapshot.first { entry in
        guard entry.layer == 0, entry.isOnScreen, entry.ownerPID != ownPID else { return false }
        // 1x1 占位窗（辅助进程的透明 spacer）不算可操作窗口。
        guard let b = entry.bounds, b.width > 1, b.height > 1 else { return false }
        return activationPolicyOf(entry.ownerPID) == .regular
    }
}

@MainActor
extension WindowManager {

    /// 无窗口前台兜底解析：`resolveFocusedWindowForToggle` 全空且前台 app 无候选窗口时，
    /// 用 `pickFallbackFrontWindow` 构造 toggle 目标。命中与否都写入 toggleContext
    /// （fallbackRequested / fallbackUsed / fallbackReason），日志可归因。
    ///
    /// ## 场景
    /// - 仅 `toggle(operationID:triggerSource:)` 入口在 identity==nil 且 candidatesCount==0
    ///   时调用（每次一次，主线程同步）。
    /// - 返回 nil = 系统里确实没有可操作窗口（全屏遮挡/全被排除），调用方维持原死终路径
    ///   但日志已有 fallbackRequested=false 归因。
    func resolveFallbackWindowForToggle(
        cachedMainScreen: NSScreen?,
        toggleContext: inout [String: String]
    ) -> ToggleWindowResolution? {
        toggleContext["fallbackRequested"] = "true"
        let probeStart = Date()
        let snapshot = cgWindowListAll()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let entry = pickFallbackFrontWindow(
            snapshot: snapshot,
            ownPID: ownPID,
            activationPolicyOf: { NSRunningApplication(processIdentifier: $0)?.activationPolicy }
        ) else {
            toggleContext["fallbackUsed"] = "false"
            toggleContext["fallbackReason"] = "no_regular_window_in_zorder"
            log(
                "[WindowManager] toggle fallback: no toggleable window in z-order",
                level: .warn,
                fields: [
                    "op": toggleContext["op"] ?? "nil",
                    "frontBefore": toggleContext["frontBefore"] ?? "nil"
                ]
            )
            return nil
        }
        guard let frame = entry.bounds,
              let app = NSRunningApplication(processIdentifier: entry.ownerPID) else {
            toggleContext["fallbackUsed"] = "false"
            toggleContext["fallbackReason"] = "owner_app_gone"
            return nil
        }
        let identity = WindowIdentity(
            windowID: entry.windowID,
            pid: entry.ownerPID,
            bundleIdentifier: app.bundleIdentifier,
            appName: app.localizedName,
            windowNumber: Int(entry.windowID),
            title: entry.name
        )
        let onMain = cachedMainScreen.map { CoordinateKit.isOnMainScreen(frame, mainScreenFrame: $0.frame) }
        // 与 adopt() 同契约：typed 字段 + 日志字典同步填充，让下游 decision/move 路由无感知。
        toggleContext["windowID"] = String(entry.windowID)
        toggleContext["windowFrame"] = String(describing: frame)
        if let onMain { toggleContext["onMainScreen"] = String(onMain) }
        toggleContext["windowTitle"] = truncateForLog(entry.name ?? "", limit: 60)
        toggleContext["fallbackUsed"] = "true"
        toggleContext["fallbackReason"] = "windowless_frontmost"
        toggleContext["fallbackMs"] = String(elapsedMilliseconds(since: probeStart))
        log(
            "[WindowManager] toggle fallback: windowless frontmost, using front z-order window",
            level: .warn,
            fields: [
                "op": toggleContext["op"] ?? "nil",
                "frontBefore": toggleContext["frontBefore"] ?? "nil",
                "fallbackWindowID": String(entry.windowID),
                "fallbackApp": app.localizedName ?? "nil"
            ]
        )
        return ToggleWindowResolution(
            windowID: entry.windowID,
            windowAX: nil,
            identity: identity,
            windowFrame: frame,
            onMainScreen: onMain,
            source: "fallback_front_window",
            branchMs: elapsedMilliseconds(since: probeStart)
        )
    }
}
