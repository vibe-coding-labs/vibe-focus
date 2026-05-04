import Foundation
import Cocoa

@MainActor
final class HookEventHandler {
    static let shared = HookEventHandler()

    /// 记录每个 session 最后收到 UserPromptSubmit 的时间，用于 Stop 防抖
    private var lastActivityBySession: [String: Date] = [:]
    /// Stop 防抖阈值：超过此时间无活动才视为真正结束
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

        // 唯一绑定路径：通过 terminal context (TTY/PPID 进程树) 精确匹配
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
            terminalSessionID: payload.terminalCtx?.termSessionID ?? payload.terminalCtx?.itermSessionID
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

        // 严格检查：必须有 binding 且 binding 必须通过验证
        guard let binding = SessionWindowRegistry.shared.binding(for: payload.sessionID) else {
            log(
                "[HookEventHandler] UserPromptSubmit no binding found, skipping",
                level: .warn,
                fields: [
                    "sessionID": payload.sessionID,
                    "savedStatesCount": String(WindowManager.shared.savedWindowStates.count)
                ]
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

        // 验证 binding：确认窗口 PID + windowID 仍然有效
        guard SessionWindowRegistry.shared.verifyBinding(binding) else {
            log(
                "[HookEventHandler] UserPromptSubmit binding verification failed, skipping",
                level: .warn,
                fields: [
                    "sessionID": payload.sessionID,
                    "windowID": String(binding.windowIdentity.windowID),
                    "pid": String(binding.windowIdentity.pid)
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

        let targetWindowID = binding.windowIdentity.windowID
        let targetPID = binding.windowIdentity.pid
        let store = WindowStateStore.shared
        let wm = WindowManager.shared

        log(
            "[HookEventHandler] UserPromptSubmit searching saved state via SQLite",
            fields: [
                "sessionID": payload.sessionID,
                "bindingWindowID": String(targetWindowID),
                "bindingPID": String(targetPID),
                "sqliteStatesCount": String(store.statesCount)
            ]
        )

        // 优先级 1: windowID + session 精确匹配
        if let matchedState = store.findState(windowID: targetWindowID, sessionID: payload.sessionID) {
            if !wm.isSavedStateCorrupted(matchedState) {
                return performRestore(
                    payload: payload, matchedState: matchedState,
                    matchLevel: "exact_binding_match_session_scoped"
                )
            } else {
                wm.clearSavedWindowState(id: matchedState.id)
            }
        }

        // 优先级 2: 窗口在主屏 + 同会话同 app 的 saved state
        let isOnMain = wm.isWindowOnMainScreen(windowID: targetWindowID)
        if isOnMain {
            if let appState = store.findStateByApp(
                appName: binding.windowIdentity.appName ?? "",
                sessionID: payload.sessionID
            ) {
                if !wm.isSavedStateCorrupted(appState) {
                    log(
                        "[HookEventHandler] UserPromptSubmit session-scoped app fallback (SQLite)",
                        fields: [
                            "sessionID": payload.sessionID,
                            "stateApp": appState.appName ?? "unknown",
                            "bindingWindowID": String(targetWindowID)
                        ]
                    )
                    return performRestore(
                        payload: payload, matchedState: appState,
                        matchLevel: "app_fallback_session_scoped"
                    )
                }
            }
        }

        log(
            "[HookEventHandler] UserPromptSubmit no matching state in SQLite",
            fields: [
                "sessionID": payload.sessionID,
                "windowOnMainScreen": String(isOnMain)
            ]
        )
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "no_action_needed",
                message: "No matching saved state in SQLite",
                sessionID: payload.sessionID, handled: false
            )
        )
    }

    // MARK: - Perform Restore

    private func performRestore(
        payload: ClaudeHookPayload,
        matchedState: WindowManager.SavedWindowState,
        matchLevel: String
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        WindowManager.shared.hydrateMemory(from: matchedState, window: nil)

        log(
            "[HookEventHandler] UserPromptSubmit restoring window",
            fields: [
                "sessionID": payload.sessionID,
                "matchLevel": matchLevel,
                "stateID": matchedState.id,
                "app": matchedState.appName ?? "unknown",
                "windowID": String(describing: matchedState.windowID),
                "originalFrame": String(describing: matchedState.originalFrame.cgRect),
                "targetFrame": String(describing: matchedState.targetFrame.cgRect)
            ]
        )

        WindowManager.shared.restore(
            operationID: makeOperationID(prefix: "hook-restore"),
            triggerSource: "user_prompt_submit"
        )

        SessionWindowRegistry.shared.reactivate(sessionID: payload.sessionID)

        SessionWindowRegistry.shared.setLastEventDescription(
            "UserPromptSubmit 恢复窗口（\(matchLevel)）：\(matchedState.appName ?? "Unknown")"
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
        // 防抖：如果 session 最近有 UserPromptSubmit，Stop 是中间态不是真正结束
        if let lastActivity = lastActivityBySession[payload.sessionID] {
            let elapsed = Date().timeIntervalSince(lastActivity)
            if elapsed < stopDebounceInterval {
                log(
                    "[HookEventHandler] Stop debounced — session was active \(String(format: "%.1f", elapsed))s ago (threshold: \(String(format: "%.0f", stopDebounceInterval))s)",
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

        // 防抖通过 + trigger 已启用 → 清理活动记录
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

        // 严格检查：必须有 binding 且通过验证
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
                "[HookEventHandler] \(triggerName) binding verification failed, skipping",
                level: .warn,
                fields: [
                    "sessionID": payload.sessionID,
                    "windowID": String(binding.windowIdentity.windowID),
                    "pid": String(binding.windowIdentity.pid)
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
        binding: SessionWindowBinding,
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

        // 预检：如果窗口已在主屏幕上，跳过移动
        // 防止对已在主屏的窗口执行无意义移动，避免保存错误状态
        if WindowManager.shared.isWindowOnMainScreen(windowID: binding.windowIdentity.windowID) {
            SessionWindowRegistry.shared.setLastEventDescription(
                "\(triggerName) 窗口已在主屏幕，跳过移动"
            )
            log(
                "[HookEventHandler] \(triggerName) window already on main screen, skipping move",
                fields: [
                    "sessionID": payload.sessionID,
                    "windowID": String(binding.windowIdentity.windowID),
                    "app": binding.windowIdentity.appName ?? "unknown"
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
        // SessionStart 可能绑定到非终端窗口（Chrome、飞书等），这类窗口不应被自动移动
        let terminalAppNames: Set<String> = [
            "Terminal", "iTerm2", "Warp", "Ghostty", "Alacritty", "kitty",
            "Cursor", "Code", "Visual Studio Code",
            "com.apple.Terminal", "com.googlecode.iterm2",
            "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"
        ]
        let isTerminalBinding: Bool = {
            if let appName = binding.windowIdentity.appName, terminalAppNames.contains(appName) {
                return true
            }
            if let bundleID = binding.windowIdentity.bundleIdentifier, terminalAppNames.contains(bundleID) {
                return true
            }
            return false
        }()

        if !isTerminalBinding {
            SessionWindowRegistry.shared.setLastEventDescription(
                "\(triggerName) 绑定窗口非终端应用：\(binding.windowIdentity.appName ?? "Unknown")"
            )
            log(
                "[HookEventHandler] \(triggerName) bound window is non-terminal app, skipping",
                level: .warn,
                fields: [
                    "sessionID": payload.sessionID,
                    "app": binding.windowIdentity.appName ?? "unknown",
                    "bundleID": binding.windowIdentity.bundleIdentifier ?? "nil",
                    "windowID": String(binding.windowIdentity.windowID)
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
                "app": binding.windowIdentity.appName ?? "unknown",
                "title": binding.windowIdentity.title ?? "untitled",
                "windowID": String(binding.windowIdentity.windowID),
                "pid": String(binding.windowIdentity.pid)
            ]
        )

        let moved = WindowManager.shared.moveWindowToMainScreen(
            identity: binding.windowIdentity,
            reason: .claudeSessionEnd,
            sessionID: payload.sessionID
        )
        if moved {
            SessionWindowRegistry.shared.markCompleted(sessionID: payload.sessionID)
            log(
                "[HookEventHandler] \(triggerName) window moved successfully",
                fields: [
                    "sessionID": payload.sessionID,
                    "app": binding.windowIdentity.appName ?? "unknown",
                    "title": binding.windowIdentity.title ?? "untitled"
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
                "app": binding.windowIdentity.appName ?? "unknown",
                "windowID": String(binding.windowIdentity.windowID)
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
