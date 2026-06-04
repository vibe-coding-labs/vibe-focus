import AppKit
import Foundation

@MainActor
extension HookEventHandler {

    // MARK: - Window Move Decision Logic (extracted for testability)

    /// Window move trigger decision — all possible outcomes.
    enum WindowMoveDecision: Equatable {
        case autoFocusDisabled
        case localBindingSkip
        case noBindingSkip
        case bindingVerificationFailed
        case alreadyCompleted
        case alreadyOnMainScreen
        case restoreCooldownActive
        case staleBindingPIDMismatch
        case nonTerminalWindow
        case proceedToMove(source: String)
    }

    /// Pure decision logic for handleWindowMoveTrigger.
    /// Decision based on physical window state, not session flags.
    static func decideWindowMove(
        autoFocusEnabled: Bool,
        hasBinding: Bool,
        bindingVerified: Bool,
        isWindowOnMainScreen: Bool,
        isInCooldown: Bool,
        bindingAge: TimeInterval,
        pidMatches: Bool?,
        isTerminalOrIDE: Bool,
        remoteOnly: Bool = false,
        isLocalBinding: Bool = false,
        hasMachineLabel: Bool = false
    ) -> WindowMoveDecision {
        guard autoFocusEnabled else { return .autoFocusDisabled }

        // remoteOnly=true → triggerOnStop=false → 跳过所有绑定，不区分 local/remote
        if remoteOnly { return .localBindingSkip }

        if !hasBinding {
            return .noBindingSkip
        }

        guard bindingVerified else { return .bindingVerificationFailed }

        if isWindowOnMainScreen { return .alreadyOnMainScreen }

        if isInCooldown { return .restoreCooldownActive }

        if bindingAge > 1800 && pidMatches == false {
            return .staleBindingPIDMismatch
        }

        guard isTerminalOrIDE else { return .nonTerminalWindow }

        return .proceedToMove(source: hasBinding ? "binding" : "terminalCtx")
    }

    // MARK: - Window Move Trigger (Stop / SessionEnd)

    func handleWindowMoveTrigger(
        payload: ClaudeHookPayload,
        triggerName: String,
        remoteOnly: Bool = false
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

        // 尝试获取 binding，无 binding 时通过 machineLabel 自愈远程 session
        let binding: WindowState
        if let existing = SessionWindowRegistry.shared.binding(for: payload.sessionID) {
            binding = existing
        } else if let label = payload.terminalCtx?.machineLabel, !label.isEmpty,
                  let identity = resolveRemoteBinding(label: label, sessionID: payload.sessionID) {
            log(
                "[HookEventHandler] \(triggerName) self-heal: resolved remote binding via machineLabel",
                level: .info,
                fields: [
                    "sessionID": payload.sessionID,
                    "machineLabel": label,
                    "windowID": String(identity.windowID),
                    "app": identity.appName ?? "unknown"
                ]
            )
            SessionWindowRegistry.shared.bind(
                sessionID: payload.sessionID,
                windowIdentity: identity,
                terminalTTY: payload.terminalCtx?.tty,
                terminalSessionID: payload.terminalCtx?.termSessionID,
                itermSessionID: payload.terminalCtx?.itermSessionID,
                cwd: payload.cwd,
                model: payload.model,
                bindingType: .remote
            )
            guard let healed = SessionWindowRegistry.shared.binding(for: payload.sessionID) else {
                return (
                    200,
                    ClaudeHookResponse(
                        ok: true, code: "no_binding_skip",
                        message: "Self-heal binding lost after registration",
                        sessionID: payload.sessionID, handled: false
                    )
                )
            }
            binding = healed
        } else {
            log(
                "[HookEventHandler] \(triggerName) no binding found, skipping",
                level: .warn,
                fields: [
                    "sessionID": payload.sessionID,
                    "machineLabel": payload.terminalCtx?.machineLabel ?? "nil",
                    "isRemote": String(payload.terminalCtx?.isRemote ?? false)
                ]
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

        // remoteOnly 模式：triggerOnStop=false 时跳过所有绑定（不区分 local/remote）
        // 之前的逻辑只跳过 local 绑定，允许 remote 绑定通过。但用户关闭 triggerOnStop
        // 意味着"不希望任何 Stop 事件移动窗口"，不论绑定类型。
        // 如果 remote 绑定通过，窗口仍会被移动，违背用户意图。
        if remoteOnly {
            SessionWindowRegistry.shared.touch(
                sessionID: payload.sessionID,
                message: "\(triggerName) 跳过（remoteOnly 模式，triggerOnStop=false）"
            )
            log(
                "[HookEventHandler] \(triggerName) skipped (remoteOnly mode, triggerOnStop=false)",
                level: .debug,
                fields: [
                    "sessionID": payload.sessionID,
                    "windowID": String(binding.windowID),
                    "bindingType": binding.bindingType.rawValue,
                    "machineLabel": payload.terminalCtx?.machineLabel ?? "nil"
                ]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "trigger_disabled_skip",
                    message: "\(triggerName) skipped (triggerOnStop=false, no window movement)",
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

