import AppKit
import CoreGraphics
import Foundation

/// 原生事件通道：Mission Control 关闭 + SLS/SkyLight 符号可用性诊断。
///
/// ## 场景
/// - dismissMissionControl：Mission Control 展开期间所有 space 切换命令必失败的
///   现成解除通道。旧消费方 switchDisplayToSpace 已随旧机制下线（2026-09-02 P2-1），
///   当前无自动调用方，保留作显式接线基础设施（见回归防护文档「明确不修」清单）；
/// - logAvailability：AppDelegate 启动诊断。
///
/// ## 历史注（2026-09-01 清理）
/// SLSMoveWindowsToManagedSpace moveWindow / CGEvent Ctrl+Arrow focusSpace(steps:) /
/// CGEvent 鼠标拖拽 dragWindowToDisplay 全部为零调用死代码，已删除——SLS move 需
/// "universal owner connection"（yabai issue #2593）权限不足预期失败，从未真正可用。
@MainActor
enum NativeSpaceBridge {

    // MARK: - Mission Control Dismissal

    /// 发送 Escape 键关闭 Mission Control
    /// 当 yabai 报 "mission-control is active" 错误时，Mission Control 正在显示中
    /// 此时所有 space 切换命令（yabai + 键盘事件）都会失败
    static func dismissMissionControl(operationID: String? = nil) {
        let op = operationID ?? "none"
        // P-INST-20: dismissMissionControl 完成耗时（含 150ms usleep 等 Mission Control 动画）。
        let dismissStart = Date()
        log("[NativeSpaceBridge] dismissing Mission Control via Escape key", fields: ["op": op])
        let escapeDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: true)
        escapeDown?.post(tap: .cghidEventTap)
        let escapeUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: false)
        escapeUp?.post(tap: .cghidEventTap)
        usleep(WindowSettle.missionControlDismissSettleMicros) // 等待 Mission Control 动画结束
        log("[NativeSpaceBridge] dismissMissionControl done", fields: [
            "op": op,
            "durationMs": String(elapsedMilliseconds(since: dismissStart))
        ])
    }

    // MARK: - Diagnostics

    /// 启动诊断：记录 SkyLight 私有符号是否可加载（仅日志，无消费方依赖其结果）
    static func logAvailability() {
        // P-INST-230: SLS 符号可用性诊断耗时（dlopen + dlsym 探测 + 循环 log；诊断/启动调用）。
        #if PERF_INSTRUMENT
        let laStart = Date()
        defer {
            log("[NativeSpaceBridge] logAvailability finished", level: .debug, fields: ["durationMs": String(elapsedMilliseconds(since: laStart))])
        }
        #endif
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            log("[NativeSpaceBridge] symbol check", fields: ["framework": "SkyLight", "loaded": "false"])
            return
        }
        defer { dlclose(handle) }
        for name in ["SLSMainConnectionID", "SLSMoveWindowsToManagedSpace"] {
            let loaded = dlsym(handle, name) != nil
            log(
                "[NativeSpaceBridge] symbol check",
                fields: ["symbol": name, "loaded": loaded ? "true" : "false"]
            )
        }
    }
}
