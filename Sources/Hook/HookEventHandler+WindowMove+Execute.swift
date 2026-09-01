// HookEventHandler+WindowMove+Execute.swift
// VibeFocus — Window move 执行逻辑（绑定移动 + 共享响应）
// 从 HookEventHandler+WindowMove.swift 中提取
// 决策不在本文件：调用方必须已通过 decideWindowMove 得到 .proceedToMove 才可进入。

import AppKit
import Foundation

@MainActor
extension HookEventHandler {

    // MARK: - Shared Move + Respond

    /// 执行已决策（.proceedToMove）的主屏移动并产生成功/失败响应。
    /// 场景注释：本函数不做任何跳过类决策（onMain/冷却/非终端等已由
    /// handleWindowMoveTrigger 内的 decideWindowMove 统一裁决），
    /// 只负责 moveWindowToMainScreen 的结果二分与完成副作用（markCompleted + 冷却 + 声音/角标）。
    /// 竞态风险：决策与执行之间窗口可能被并发移动——以 moveWindowToMainScreen
    /// 的实际返回为准，不做二次预检（历史双重预检曾与决策树漂移出不同顺序）。
    func moveWindowToMainScreenAndRespond(
        identity: WindowIdentity,
        payload: ClaudeHookPayload,
        triggerName: String,
        source: String,
        bindingAge: TimeInterval? = nil,
        onComplete: (() -> Void)? = nil
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        // P-INST-47: moveWindowToMainScreenAndRespond 总耗时 + outcome（hook 移动核心执行；
        // 区分 moved 含 moveWindowToMainScreen P-INST-3 vs move_failed skip；
        // P-INST-31 handleWindowMoveTrigger 已覆盖调用方总耗时，此埋点补本函数归因）。
        let mwtStart = Date()
        var outcome: String = "proceed"
        defer {
            log("[HookEventHandler] moveWindowToMainScreenAndRespond finished", level: .debug, fields: [
                "sessionID": payload.sessionID, "triggerName": triggerName, "source": source,
                "outcome": outcome,
                "durationMs": String(elapsedMilliseconds(since: mwtStart))
            ])
        }
        log(
            "[HookEventHandler] \(triggerName) [\(source)] moving window",
            fields: [
                "sessionID": payload.sessionID,
                "app": identity.appName ?? "unknown",
                "windowID": String(identity.windowID),
                "pid": String(identity.pid)
            ]
        )

        let moved = WindowManager.shared.moveWindowToMainScreen(
            identity: identity,
            reason: .claudeSessionEnd,
            sessionID: payload.sessionID
        )
        if moved {
            outcome = "moved"
            onComplete?()
            log(
                "[HookEventHandler] \(triggerName) [\(source)] window moved successfully",
                fields: [
                    "sessionID": payload.sessionID,
                    "app": identity.appName ?? "unknown"
                ]
            )
            Task { @MainActor in
                SoundManager.shared.playCompletionSound()
                DockBadgeManager.shared.showBadge(
                    targetBundleID: identity.bundleIdentifier,
                    targetAppName: identity.appName
                )
            }
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "window_focused",
                    message: "Window moved to main screen",
                    sessionID: payload.sessionID, handled: true
                )
            )
        }

        outcome = "move_failed"
        SessionWindowRegistry.shared.touch(
            sessionID: payload.sessionID,
            message: "\(triggerName) 命中绑定，但移动窗口失败"
        )
        log(
            "[HookEventHandler] \(triggerName) [\(source)] window move failed",
            level: .error,
            fields: [
                "sessionID": payload.sessionID,
                "app": identity.appName ?? "unknown",
                "windowID": String(identity.windowID)
            ]
        )
        return (
            409,
            ClaudeHookResponse(
                ok: false, code: "window_move_failed",
                message: "Failed to move window to main screen",
                sessionID: payload.sessionID, handled: false
            )
        )
    }
}
