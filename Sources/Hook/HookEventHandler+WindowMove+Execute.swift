// HookEventHandler+WindowMove+Execute.swift
// VibeFocus — Window move 执行逻辑（绑定移动 + 共享响应）
// 从 HookEventHandler+WindowMove.swift 中提取

import AppKit
import Foundation

@MainActor
extension HookEventHandler {

    // MARK: - Move Binding to Main Screen

    func moveBindingToMainScreen(
        binding: WindowState,
        payload: ClaudeHookPayload,
        triggerName: String
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        // P-INST-104: moveBindingToMainScreen hook window-move 执行耗时（isWindowOnMainScreen 预检 P-INST-61 + moveWindowToMainScreen P-INST-3 yabai 跨屏移动 + setWindowFloat + AX apply + 可能 refreshOverlays/playCompletionSound；handleWindowMoveTrigger P-INST-31 line 159 调用，hook 窗口移动核心执行；补本执行器各阶段归因）。
        let mbmStart = Date()
        defer {
            log("[HookEventHandler] moveBindingToMainScreen finished", level: .debug, fields: [
                "sessionID": payload.sessionID, "triggerName": triggerName,
                "windowID": String(binding.windowID),
                "durationMs": String(elapsedMilliseconds(since: mbmStart))
            ])
        }
        let windowID = binding.windowID
        let bindingAge = Date().timeIntervalSince(binding.createdAt)

        // 预检：如果窗口已在主屏幕上，跳过移动
        if WindowManager.shared.isWindowOnMainScreen(windowID: windowID) {
            SessionWindowRegistry.shared.setLastEventDescription(
                "\(triggerName) 窗口已在主屏幕，跳过移动"
            )
            log(
                "[HookEventHandler] \(triggerName) window already on main screen, skipping move",
                fields: [
                    "sessionID": payload.sessionID,
                    "windowID": String(windowID),
                    "app": binding.appName ?? "unknown"
                ]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "already_on_main_screen",
                    message: "Window already on main screen, no action needed",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 冷却检查：窗口刚被用户恢复（手动热键或 UPS 自动恢复），不重复拉到主屏
        // 多个远程 session 共享同一窗口时，防止 Stop 事件反复拉窗
        if isWindowInMoveCooldown(windowID: windowID) {
            SessionWindowRegistry.shared.setLastEventDescription(
                "\(triggerName) 窗口刚被恢复，跳过移动（冷却中）"
            )
            log(
                "[HookEventHandler] \(triggerName) window recently restored, skipping move (cooldown)",
                level: .info,
                fields: [
                    "sessionID": payload.sessionID,
                    "windowID": String(windowID),
                    "app": binding.appName ?? "unknown"
                ]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "restore_cooldown_active",
                    message: "Window recently restored, skipping move (cooldown active)",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 绑定年龄校验：超过 30 分钟的绑定可能已过期（CGWindowNumber 被回收）
        if bindingAge > 1800 {
            let windows = cgWindowListAll()
            if let matchedEntry = windows.first(where: { $0.windowID == windowID }) {
                if matchedEntry.ownerPID != binding.pid {
                    log(
                        "[HookEventHandler] \(triggerName) stale binding: window PID mismatch (binding age: \(Int(bindingAge))s)",
                        level: .warn,
                        fields: [
                            "sessionID": payload.sessionID,
                            "windowID": String(windowID),
                            "boundPID": String(binding.pid),
                            "actualPID": String(matchedEntry.ownerPID),
                            "bindingAge": String(Int(bindingAge))
                        ]
                    )
                    SessionWindowRegistry.shared.markCompleted(sessionID: payload.sessionID)
                    return (
                        200,
                        ClaudeHookResponse(
                            ok: true, code: "stale_binding_pid_mismatch",
                            message: "Stale binding: window PID no longer matches",
                            sessionID: payload.sessionID, handled: false
                        )
                    )
                }
            }
        }

        let identity = WindowIdentity(from: binding)

        log(
            "[HookEventHandler] \(triggerName) proceeding to move binding window",
            fields: [
                "sessionID": payload.sessionID,
                "windowID": String(windowID),
                "bindingType": binding.bindingType.rawValue,
                "app": binding.appName ?? "unknown",
                "bindingAge": String(Int(bindingAge)) + "s"
            ]
        )

        return moveWindowToMainScreenAndRespond(
            identity: identity,
            payload: payload,
            triggerName: triggerName,
            source: "binding",
            bindingAge: bindingAge,
            onComplete: {
                SessionWindowRegistry.shared.markCompleted(sessionID: payload.sessionID)
                HookEventHandler.shared.setMoveCooldown(windowID: binding.windowID)
            }
        )
    }

    // MARK: - Shared Move + Respond

    func moveWindowToMainScreenAndRespond(
        identity: WindowIdentity,
        payload: ClaudeHookPayload,
        triggerName: String,
        source: String,
        bindingAge: TimeInterval? = nil,
        onComplete: (() -> Void)? = nil
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        // P-INST-47: moveWindowToMainScreenAndRespond 总耗时 + outcome（hook 移动核心；区分 already_on_main 快路径 vs moved 含 moveWindowToMainScreen P-INST-3 vs non_terminal/move_failed skip；P-INST-31 handleWindowMoveTrigger 已覆盖调用方总耗时，此埋点补本函数各阶段归因）。
        let mwtStart = Date()
        var outcome = "unknown"
        defer {
            log("[HookEventHandler] moveWindowToMainScreenAndRespond finished", level: .debug, fields: [
                "sessionID": payload.sessionID, "triggerName": triggerName, "source": source,
                "outcome": outcome,
                "durationMs": String(elapsedMilliseconds(since: mwtStart))
            ])
        }
        // 预检：如果窗口已在主屏幕上，跳过移动
        if WindowManager.shared.isWindowOnMainScreen(windowID: identity.windowID) {
            outcome = "already_on_main"
            log(
                "[HookEventHandler] \(triggerName) [\(source)] window already on main screen, skipping",
                fields: [
                    "sessionID": payload.sessionID,
                    "windowID": String(identity.windowID),
                    "app": identity.appName ?? "unknown"
                ]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "already_on_main_screen",
                    message: "Window already on main screen, no action needed",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 安全检查：确保是终端/IDE 窗口
        let isTerminal = Self.isTerminalOrIDEApp(
            appName: identity.appName,
            bundleIdentifier: identity.bundleIdentifier
        )
        if !isTerminal {
            outcome = "non_terminal"
            log(
                "[HookEventHandler] \(triggerName) [\(source)] window is non-terminal, skipping",
                level: .warn,
                fields: [
                    "sessionID": payload.sessionID,
                    "app": identity.appName ?? "unknown",
                    "bundleID": identity.bundleIdentifier ?? "nil"
                ]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "non_terminal_window",
                    message: "Resolved window is not a terminal/IDE app, skipping",
                    sessionID: payload.sessionID, handled: false
                )
            )
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
