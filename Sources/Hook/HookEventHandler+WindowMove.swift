import AppKit
import Foundation

@MainActor
extension HookEventHandler {
    // MARK: - Window Move Trigger (Stop / SessionEnd)

    func handleWindowMoveTrigger(
        payload: ClaudeHookPayload,
        triggerName: String
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        log(
            "[HookEventHandler] \(triggerName) triggered",
            fields: [
                "sessionID": payload.sessionID,
                "autoFocusEnabled": String(ClaudeHookPreferences.autoFocusOnSessionEnd),
                "cwd": payload.cwd ?? "nil"
            ]
        )

        guard ClaudeHookPreferences.autoFocusOnSessionEnd else {
            SessionWindowRegistry.shared.touch(
                sessionID: payload.sessionID,
                message: "\(triggerName) 收到（自动聚焦已关闭）"
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "auto_focus_disabled",
                    message: "\(triggerName) received, auto focus disabled",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        guard let binding = SessionWindowRegistry.shared.binding(for: payload.sessionID) else {
            // 无绑定 — 尝试 terminal context 降级（app 重启后绑定丢失的场景）
            log(
                "[HookEventHandler] \(triggerName) no binding found, trying terminal context fallback",
                level: .warn,
                fields: ["sessionID": payload.sessionID]
            )

            if let terminalCtx = payload.terminalCtx, terminalCtx.hasUsefulContext,
               let identity = WindowManager.shared.findWindowByTerminalContext(terminalCtx) {
                return moveTerminalContextWindowToMainScreen(
                    identity: identity, payload: payload, triggerName: triggerName
                )
            }

            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "no_binding_skip",
                    message: "No session binding or terminal context, skipping window move",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        guard SessionWindowRegistry.shared.verifyBinding(binding) else {
            log(
                "[HookEventHandler] \(triggerName) binding verification failed",
                level: .warn,
                fields: [
                    "sessionID": payload.sessionID,
                    "windowID": String(describing: binding.windowID),
                    "pid": String(binding.pid)
                ]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "binding_verification_failed",
                    message: "Binding verification failed, skipping window move",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        return moveBindingToMainScreen(binding: binding, payload: payload, triggerName: triggerName)
    }

    // MARK: - Terminal/IDE App Detection

    static func isTerminalOrIDEApp(appName: String?, bundleIdentifier: String?) -> Bool {
        TerminalRegistry.isTerminalOrIDEApp(appName: appName, bundleIdentifier: bundleIdentifier)
    }

    // MARK: - Move Binding to Main Screen

    private func moveBindingToMainScreen(
        binding: WindowState,
        payload: ClaudeHookPayload,
        triggerName: String
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        if binding.isCompleted {
            log(
                "[HookEventHandler] \(triggerName) already completed",
                fields: ["sessionID": payload.sessionID]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "already_completed",
                    message: "Session already completed",
                    sessionID: payload.sessionID, handled: false
                )
            )
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

        // 绑定年龄校验：超过 30 分钟的绑定可能已过期（CGWindowNumber 被回收）
        if bindingAge > 1800 {
            let options: CGWindowListOption = [.optionAll]
            if let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]],
               let matchedWindow = windowList.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == windowID }) {
                let actualPID = matchedWindow[kCGWindowOwnerPID as String] as? Int32
                if actualPID != binding.pid {
                    log(
                        "[HookEventHandler] \(triggerName) stale binding: window PID mismatch (binding age: \(Int(bindingAge))s)",
                        level: .warn,
                        fields: [
                            "sessionID": payload.sessionID,
                            "windowID": String(windowID),
                            "boundPID": String(binding.pid),
                            "actualPID": String(describing: actualPID),
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

        return moveWindowToMainScreenAndRespond(
            identity: identity,
            payload: payload,
            triggerName: triggerName,
            source: "binding",
            bindingAge: bindingAge,
            onComplete: { SessionWindowRegistry.shared.markCompleted(sessionID: payload.sessionID) }
        )
    }

    // MARK: - Terminal Context Fallback（无绑定时通过终端上下文定位窗口）

    private func moveTerminalContextWindowToMainScreen(
        identity: WindowIdentity,
        payload: ClaudeHookPayload,
        triggerName: String
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        return moveWindowToMainScreenAndRespond(
            identity: identity,
            payload: payload,
            triggerName: triggerName,
            source: "terminalCtx"
        )
    }

    // MARK: - Shared Move + Respond

    private func moveWindowToMainScreenAndRespond(
        identity: WindowIdentity,
        payload: ClaudeHookPayload,
        triggerName: String,
        source: String,
        bindingAge: TimeInterval? = nil,
        onComplete: (() -> Void)? = nil
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        // 预检：如果窗口已在主屏幕上，跳过移动
        if WindowManager.shared.isWindowOnMainScreen(windowID: identity.windowID) {
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

