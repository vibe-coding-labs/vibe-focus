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
            log(
                "[HookEventHandler] \(triggerName) no binding found, skipping",
                level: .warn,
                fields: ["sessionID": payload.sessionID]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "no_binding_skip",
                    message: "No session binding, skipping window move",
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
        // 验证 windowID 的当前 owner PID 是否与绑定时一致
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

        // 安全检查：确保绑定的是终端/IDE 窗口
        let isTerminalBinding = Self.isTerminalOrIDEApp(
            appName: binding.appName,
            bundleIdentifier: binding.bundleIdentifier
        )

        if !isTerminalBinding {
            SessionWindowRegistry.shared.setLastEventDescription(
                "\(triggerName) 绑定窗口非终端应用：\(binding.appName ?? "Unknown")"
            )
            log(
                "[HookEventHandler] \(triggerName) bound window is non-terminal app, skipping",
                level: .warn,
                fields: [
                    "sessionID": payload.sessionID,
                    "app": binding.appName ?? "unknown",
                    "bundleID": binding.bundleIdentifier ?? "nil",
                    "windowID": String(windowID)
                ]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "non_terminal_binding",
                    message: "Bound window is not a terminal/IDE app, skipping",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        log(
            "[HookEventHandler] \(triggerName) moving window",
            fields: [
                "sessionID": payload.sessionID,
                "app": binding.appName ?? "unknown",
                "title": binding.title ?? "untitled",
                "windowID": String(windowID),
                "pid": String(binding.pid),
                "cwd": payload.cwd ?? "nil",
                "bindingAge": String(Int(bindingAge))
            ]
        )

        let identity = WindowIdentity(
            windowID: windowID,
            pid: binding.pid,
            bundleIdentifier: binding.bundleIdentifier,
            appName: binding.appName,
            windowNumber: binding.axWindowNumber,
            title: binding.title,
            capturedAt: binding.createdAt
        )

        let moved = WindowManager.shared.moveWindowToMainScreen(
            identity: identity,
            reason: .claudeSessionEnd,
            sessionID: payload.sessionID
        )
        if moved {
            SessionWindowRegistry.shared.markCompleted(sessionID: payload.sessionID)
            log(
                "[HookEventHandler] \(triggerName) window moved successfully",
                fields: [
                    "sessionID": payload.sessionID,
                    "app": binding.appName ?? "unknown",
                    "title": binding.title ?? "untitled"
                ]
            )
            Task { @MainActor in
                SoundManager.shared.playCompletionSound()
                DockBadgeManager.shared.showBadge(
                    targetBundleID: binding.bundleIdentifier,
                    targetAppName: binding.appName
                )
            }
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "window_focused",
                    message: "Window moved to main screen and maximized",
                    sessionID: payload.sessionID, handled: true
                )
            )
        }

        SessionWindowRegistry.shared.touch(
            sessionID: payload.sessionID,
            message: "\(triggerName) 命中绑定，但移动窗口失败"
        )
        log(
            "[HookEventHandler] \(triggerName) window move failed",
            level: .error,
            fields: [
                "sessionID": payload.sessionID,
                "app": binding.appName ?? "unknown",
                "windowID": String(windowID)
            ]
        )
        return (
            409,
            ClaudeHookResponse(
                ok: false, code: "window_move_failed",
                message: "Found session binding but failed to move window",
                sessionID: payload.sessionID, handled: false
            )
        )
    }
}

