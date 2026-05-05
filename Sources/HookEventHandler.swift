import Foundation
import Cocoa

@MainActor
final class HookEventHandler {
    static let shared = HookEventHandler()

    private var lastActivityBySession: [String: Date] = [:]
    private let stopDebounceInterval: TimeInterval = 30.0

    private init() {}

    // MARK: - Session Start

    func handleSessionStart(
        payload: ClaudeHookPayload
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        log(
            "[handleSessionStart] called",
            level: .debug,
            fields: [
                "sessionID": payload.sessionID,
                "cwd": payload.cwd ?? "nil",
                "hasTerminalCtx": String(payload.terminalCtx != nil),
                "terminalCtxUseful": String(payload.terminalCtx?.hasUsefulContext ?? false)
            ]
        )

        guard let terminalCtx = payload.terminalCtx, terminalCtx.hasUsefulContext else {
            log(
                "[handleSessionStart] no terminal context, cannot bind",
                level: .warn,
                fields: ["sessionID": payload.sessionID]
            )
            SessionWindowRegistry.shared.setLastEventDescription("SessionStart 失败：无终端上下文")
            return (
                409,
                ClaudeHookResponse(
                    ok: false, code: "no_terminal_context",
                    message: "No terminal context available for precise binding",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        guard let identity = WindowManager.shared.findWindowByTerminalContext(terminalCtx) else {
            log(
                "[handleSessionStart] terminal context match failed",
                level: .warn,
                fields: [
                    "sessionID": payload.sessionID,
                    "tty": terminalCtx.tty ?? "nil",
                    "ppid": terminalCtx.ppid ?? "nil"
                ]
            )
            SessionWindowRegistry.shared.setLastEventDescription("SessionStart 失败：终端上下文无法匹配窗口")
            return (
                409,
                ClaudeHookResponse(
                    ok: false, code: "terminal_context_match_failed",
                    message: "Terminal context could not be resolved to a window",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        log(
            "[HookEventHandler] SessionStart matched via terminal context",
            fields: [
                "sessionID": payload.sessionID,
                "app": identity.appName ?? "unknown",
                "title": identity.title ?? "untitled",
                "windowID": String(identity.windowID)
            ]
        )
        SessionWindowRegistry.shared.bind(
            sessionID: payload.sessionID,
            windowIdentity: identity,
            terminalTTY: payload.terminalCtx?.tty,
            terminalSessionID: payload.terminalCtx?.termSessionID,
            itermSessionID: payload.terminalCtx?.itermSessionID,
            cwd: payload.cwd,
            model: payload.model
        )
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "session_bound",
                message: "Session bound to terminal window via TTY/PPID",
                sessionID: payload.sessionID, handled: true
            )
        )
    }

    // MARK: - User Prompt Submit

    func handleUserPromptSubmit(
        payload: ClaudeHookPayload
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        lastActivityBySession[payload.sessionID] = Date()

        log(
            "[HookEventHandler] UserPromptSubmit triggered",
            fields: [
                "sessionID": payload.sessionID,
                "autoRestoreEnabled": String(ClaudeHookPreferences.autoRestoreOnPromptSubmit),
                "cwd": payload.cwd ?? "nil"
            ]
        )

        guard ClaudeHookPreferences.autoRestoreOnPromptSubmit else {
            SessionWindowRegistry.shared.touch(
                sessionID: payload.sessionID,
                message: "UserPromptSubmit 收到（自动恢复已关闭）"
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "auto_restore_disabled",
                    message: "UserPromptSubmit received, auto restore disabled",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 通过 sessionID 找到窗口状态
        let state = SessionWindowRegistry.shared.binding(for: payload.sessionID)
        let identity: WindowIdentity?

        if let state {
            guard SessionWindowRegistry.shared.verifyBinding(state) else {
                log(
                    "[HookEventHandler] UserPromptSubmit binding verification failed",
                    level: .warn,
                    fields: [
                        "sessionID": payload.sessionID,
                        "pid": String(state.pid),
                        "tty": state.tty ?? "nil"
                    ]
                )
                return (
                    200,
                    ClaudeHookResponse(
                        ok: true, code: "binding_verification_failed",
                        message: "Binding verification failed, skipping restore",
                        sessionID: payload.sessionID, handled: false
                    )
                )
            }
            identity = WindowIdentity(
                windowID: state.windowID ?? 0,
                pid: state.pid,
                bundleIdentifier: state.bundleIdentifier,
                appName: state.appName,
                windowNumber: state.axWindowNumber,
                title: state.title,
                capturedAt: state.createdAt
            )
        } else if let terminalCtx = payload.terminalCtx, terminalCtx.hasUsefulContext {
            identity = WindowManager.shared.findWindowByTerminalContext(terminalCtx)
            if let identity {
                log(
                    "[HookEventHandler] UserPromptSubmit no binding, resolved via terminal context",
                    fields: [
                        "sessionID": payload.sessionID,
                        "resolvedWindowID": String(identity.windowID),
                        "app": identity.appName ?? "unknown"
                    ]
                )
            }
        } else {
            log(
                "[HookEventHandler] UserPromptSubmit no binding and no terminal context",
                level: .warn,
                fields: ["sessionID": payload.sessionID]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "no_binding_skip",
                    message: "No session binding, skipping restore",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        guard let identity else {
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "no_binding_skip",
                    message: "Could not resolve window identity",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        let wm = WindowManager.shared
        let isOnMain = wm.isWindowOnMainScreen(windowID: identity.windowID)

        guard isOnMain else {
            log(
                "[HookEventHandler] UserPromptSubmit window not on main screen",
                fields: [
                    "sessionID": payload.sessionID,
                    "windowID": String(identity.windowID)
                ]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "no_action_needed",
                    message: "Window not on main screen",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 通过 (pid, tty) 在同一行查找 toggle state — 无需跨表匹配
        let tty = state?.tty ?? payload.terminalCtx?.tty
        if let toggleState = SessionWindowRegistry.shared.findState(pid: identity.pid, tty: tty) {
            if toggleState.hasToggleState {
                // 验证 toggle state 的 windowID 与当前窗口匹配
                // 同 PID+TTY 可能有多个窗口（如 Terminal.app 多窗口），防止恢复到错误窗口
                if let stateWID = toggleState.windowID, stateWID != identity.windowID {
                    log(
                        "[HookEventHandler] UserPromptSubmit toggle state windowID mismatch, skipping pid_tty_direct",
                        level: .warn,
                        fields: [
                            "sessionID": payload.sessionID,
                            "identityWindowID": String(identity.windowID),
                            "stateWindowID": String(stateWID),
                            "pid": String(identity.pid),
                            "tty": tty ?? "nil"
                        ]
                    )
                } else {
                    guard let mainScreen = wm.getMainScreen() else {
                        return (200, ClaudeHookResponse(ok: true, code: "no_main_screen", message: "No main screen", sessionID: payload.sessionID, handled: false))
                    }
                    if !toggleState.isCorrupted(mainScreenFrame: mainScreen.frame) {
                        return performRestoreFromState(
                            payload: payload, toggleState: toggleState,
                            matchLevel: "pid_tty_direct"
                        )
                    } else {
                        SessionWindowRegistry.shared.clearToggleState(pid: identity.pid, tty: tty)
                    }
                }
            }
        }

        // Fallback: 按 windowID 查找
        if let windowState = SessionWindowRegistry.shared.findStateByWindowID(identity.windowID, expectedPID: identity.pid) {
            if windowState.hasToggleState {
                guard let mainScreen = wm.getMainScreen() else {
                    return (200, ClaudeHookResponse(ok: true, code: "no_main_screen", message: "No main screen", sessionID: payload.sessionID, handled: false))
                }
                if !windowState.isCorrupted(mainScreenFrame: mainScreen.frame) {
                    return performRestoreFromState(
                        payload: payload, toggleState: windowState,
                        matchLevel: "windowid_fallback"
                    )
                } else {
                    SessionWindowRegistry.shared.clearToggleState(pid: windowState.pid, tty: windowState.tty)
                }
            }
        }

        log(
            "[HookEventHandler] UserPromptSubmit no toggle state found",
            fields: [
                "sessionID": payload.sessionID,
                "pid": String(identity.pid),
                "tty": tty ?? "nil",
                "windowOnMainScreen": String(isOnMain)
            ]
        )
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "no_action_needed",
                message: "No toggle state found for window",
                sessionID: payload.sessionID, handled: false
            )
        )
    }

    // MARK: - Perform Restore

    private func performRestoreFromState(
        payload: ClaudeHookPayload,
        toggleState: WindowState,
        matchLevel: String
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        let wm = WindowManager.shared

        guard let origFrame = toggleState.originalFrame,
              let tgtFrame = toggleState.targetFrame else {
            return (200, ClaudeHookResponse(ok: true, code: "no_frame_data", message: "No frame data", sessionID: payload.sessionID, handled: false))
        }

        let savedState = WindowManager.SavedWindowState(
            id: "\(toggleState.pid)_\(toggleState.tty ?? "none")",
            pid: toggleState.pid,
            bundleIdentifier: toggleState.bundleIdentifier,
            appName: toggleState.appName,
            windowID: toggleState.windowID,
            windowNumber: toggleState.axWindowNumber,
            title: toggleState.title,
            originalFrame: WindowManager.RectPayload(origFrame),
            targetFrame: WindowManager.RectPayload(tgtFrame),
            sourceSpaceIndex: toggleState.sourceSpace,
            targetSpaceIndex: nil,
            sourceYabaiDisplayIndex: toggleState.sourceYabaiDisp,
            sourceDisplaySpaceIndex: toggleState.sourceDispSpace,
            sourceDisplayIndex: toggleState.sourceDisplay,
            sourceDisplayID: nil,
            targetDisplayIndex: toggleState.targetDisplay,
            restoreReason: toggleState.toggleReason,
            sessionID: toggleState.sessionID,
            savedAt: toggleState.toggledAt ?? Date()
        )

        wm.hydrateMemory(from: savedState, window: nil)

        // 验证找到的窗口确实在 targetFrame 附近
        if let resolvedWindow = wm.lastWindowElement,
           let resolvedFrame = wm.frame(of: resolvedWindow) {
            if !toggleState.isNearTarget(currentFrame: resolvedFrame) {
                log(
                    "[HookEventHandler] UserPromptSubmit restore aborted: window moved from target pos resolvedX=\(resolvedFrame.origin.x) resolvedY=\(resolvedFrame.origin.y)",
                    level: .warn,
                    fields: ["sessionID": payload.sessionID]
                )
                SessionWindowRegistry.shared.clearToggleState(pid: toggleState.pid, tty: toggleState.tty)
                return (
                    200,
                    ClaudeHookResponse(
                        ok: true, code: "window_moved_skip",
                        message: "Window position changed, skipping stale restore",
                        sessionID: payload.sessionID, handled: false
                    )
                )
            }
        }

        log(
            "[HookEventHandler] UserPromptSubmit restoring window",
            fields: [
                "sessionID": payload.sessionID,
                "matchLevel": matchLevel,
                "pid": String(toggleState.pid),
                "tty": toggleState.tty ?? "nil",
                "app": toggleState.appName ?? "unknown",
                "windowID": String(describing: toggleState.windowID),
                "originalFrame": String(describing: origFrame),
                "targetFrame": String(describing: tgtFrame)
            ]
        )

        wm.restore(
            operationID: makeOperationID(prefix: "hook-restore"),
            triggerSource: "user_prompt_submit"
        )

        SessionWindowRegistry.shared.reactivate(sessionID: payload.sessionID)
        SessionWindowRegistry.shared.clearToggleState(pid: toggleState.pid, tty: toggleState.tty)

        SessionWindowRegistry.shared.setLastEventDescription(
            "UserPromptSubmit 恢复窗口（\(matchLevel)）：\(toggleState.appName ?? "Unknown")"
        )
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "window_restored",
                message: "Window restored to original position",
                sessionID: payload.sessionID, handled: true
            )
        )
    }

    // MARK: - Stop

    func handleStop(
        payload: ClaudeHookPayload
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        if let lastActivity = lastActivityBySession[payload.sessionID] {
            let elapsed = Date().timeIntervalSince(lastActivity)
            if elapsed < stopDebounceInterval {
                log(
                    "[HookEventHandler] Stop debounced — session was active \(String(format: "%.1f", elapsed))s ago",
                    fields: [
                        "sessionID": payload.sessionID,
                        "elapsedSinceActivity": String(format: "%.1f", elapsed),
                        "debounceThreshold": String(format: "%.0f", stopDebounceInterval)
                    ]
                )
                SessionWindowRegistry.shared.touch(
                    sessionID: payload.sessionID,
                    message: "Stop 收到（防抖中：会话仍活跃）"
                )
                return (
                    200,
                    ClaudeHookResponse(
                        ok: true, code: "stop_debounced",
                        message: "Stop debounced — session still active",
                        sessionID: payload.sessionID, handled: false
                    )
                )
            }
        }

        guard ClaudeHookPreferences.triggerOnStop else {
            SessionWindowRegistry.shared.touch(
                sessionID: payload.sessionID,
                message: "Stop 收到（Stop 触发已关闭）"
            )
            log(
                "[HookEventHandler] Stop received but trigger disabled",
                fields: ["sessionID": payload.sessionID]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "stop_trigger_disabled",
                    message: "Stop received, trigger disabled",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        lastActivityBySession.removeValue(forKey: payload.sessionID)
        return handleWindowMoveTrigger(payload: payload, triggerName: "Stop")
    }

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

    private static let terminalAppNames: Set<String> = [
        "Terminal", "iTerm2", "Warp", "Ghostty", "Alacritty", "kitty",
        "Cursor", "Code", "Visual Studio Code",
        "com.apple.Terminal", "com.googlecode.iterm2",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"
    ]

    static func isTerminalOrIDEApp(appName: String?, bundleIdentifier: String?) -> Bool {
        if let appName, terminalAppNames.contains(appName) { return true }
        if let bundleIdentifier, terminalAppNames.contains(bundleIdentifier) { return true }
        return false
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

        guard let windowID = binding.windowID else {
            log(
                "[HookEventHandler] \(triggerName) binding has no windowID",
                level: .warn,
                fields: ["sessionID": payload.sessionID]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "no_window_id",
                    message: "Binding has no windowID",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

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
                "pid": String(binding.pid)
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
