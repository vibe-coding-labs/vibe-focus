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

        // 区分本地绑定和远程映射
        let identity: WindowIdentity
        if terminalCtx.isRemote, let label = terminalCtx.machineLabel {
            // 远程机器：通过 machine_label 查映射表
            guard let resolved = resolveRemoteBinding(label: label, sessionID: payload.sessionID) else {
                return (
                    409,
                    ClaudeHookResponse(
                        ok: false, code: "remote_binding_failed",
                        message: "Remote machine label '\(label)' not mapped to a window",
                        sessionID: payload.sessionID, handled: false
                    )
                )
            }
            identity = resolved
        } else {
            // 本地机器：用 PPID/TTY 进程树匹配（原有逻辑）
            guard let localIdentity = WindowManager.shared.findWindowByTerminalContext(terminalCtx) else {
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
            identity = localIdentity
        }

        log(
            "[HookEventHandler] SessionStart matched",
            fields: [
                "sessionID": payload.sessionID,
                "isRemote": String(terminalCtx.isRemote),
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

        // Auto-set terminal title to project name
        if let axWindow = WindowManager.shared.resolveWindow(identity: identity) {
            TitleEditorService.shared.autoSetTitle(
                cwd: payload.cwd,
                pid: identity.pid,
                bundleID: identity.bundleIdentifier ?? "",
                window: axWindow
            )
        } else {
            log(
                "[HookEventHandler] SessionStart autoSetTitle skipped: could not resolve AX window",
                level: .debug,
                fields: ["windowID": String(identity.windowID)]
            )
        }

        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "session_bound",
                message: "Session bound to terminal window via \(terminalCtx.isRemote ? "remote_label" : "TTY/PPID")",
                sessionID: payload.sessionID, handled: true
            )
        )
    }

    // MARK: - User Prompt Submit

    func handleUserPromptSubmit(
        payload: ClaudeHookPayload
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        let traceID = makeOperationID(prefix: "ups")
        let handleStartedAt = Date()
        lastActivityBySession[payload.sessionID] = Date()

        log(
            "[HookEventHandler] UserPromptSubmit triggered",
            fields: [
                "traceID": traceID,
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
                        "traceID": traceID,
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
                windowID: state.windowID,
                pid: state.pid,
                bundleIdentifier: state.bundleIdentifier,
                appName: state.appName,
                windowNumber: state.axWindowNumber,
                title: state.title,
                capturedAt: state.createdAt
            )
            log(
                "[HookEventHandler] UserPromptSubmit binding resolved",
                level: .debug,
                fields: [
                    "traceID": traceID,
                    "sessionID": payload.sessionID,
                    "windowID": String(state.windowID),
                    "resolveDurationMs": String(elapsedMilliseconds(since: handleStartedAt))
                ]
            )
        } else if let terminalCtx = payload.terminalCtx, terminalCtx.hasUsefulContext {
            let terminalResolveStart = Date()
            identity = WindowManager.shared.findWindowByTerminalContext(terminalCtx)
            let terminalResolveMs = elapsedMilliseconds(since: terminalResolveStart)
            if let identity {
                log(
                    "[HookEventHandler] UserPromptSubmit resolved via terminal context",
                    fields: [
                        "traceID": traceID,
                        "sessionID": payload.sessionID,
                        "resolvedWindowID": String(identity.windowID),
                        "app": identity.appName ?? "unknown",
                        "terminalResolveMs": String(terminalResolveMs)
                    ]
                )
            } else {
                log(
                    "[HookEventHandler] UserPromptSubmit terminal context resolve returned nil",
                    level: .warn,
                    fields: [
                        "traceID": traceID,
                        "sessionID": payload.sessionID,
                        "terminalResolveMs": String(terminalResolveMs)
                    ]
                )
            }
        } else {
            log(
                "[HookEventHandler] UserPromptSubmit no binding and no terminal context",
                level: .warn,
                fields: [
                    "traceID": traceID,
                    "sessionID": payload.sessionID
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
                    "traceID": traceID,
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

        // 新路径：ToggleEngine 直接查 SQLite，不走内存缓存
        let engine = ToggleEngine.shared
        if let record = engine.load(windowID: identity.windowID) {
            guard let mainScreen = wm.getMainScreen() else {
                return (200, ClaudeHookResponse(ok: true, code: "no_main_screen", message: "No main screen", sessionID: payload.sessionID, handled: false))
            }

            if record.isValid(mainScreenFrame: mainScreen.frame) {
                let restoreStart = Date()
                log(
                    "[HookEventHandler] UserPromptSubmit calling ToggleEngine.restore",
                    level: .info,
                    fields: [
                        "traceID": traceID,
                        "windowID": String(identity.windowID),
                        "preRestoreMs": String(elapsedMilliseconds(since: handleStartedAt))
                    ]
                )
                let success = engine.restore(
                    windowID: identity.windowID,
                    triggerSource: "user_prompt_submit",
                    traceID: traceID
                )
                let restoreMs = elapsedMilliseconds(since: restoreStart)
                log(
                    "[HookEventHandler] UserPromptSubmit restore completed",
                    level: success ? .info : .warn,
                    fields: [
                        "traceID": traceID,
                        "success": String(success),
                        "restoreMs": String(restoreMs),
                        "totalMs": String(elapsedMilliseconds(since: handleStartedAt))
                    ]
                )
                if success {
                    return (
                        200,
                        ClaudeHookResponse(
                            ok: true,
                            code: "restored",
                            message: "Window restored to original position",
                            sessionID: payload.sessionID,
                            handled: true
                        )
                    )
                } else {
                    return (
                        200,
                        ClaudeHookResponse(
                            ok: true,
                            code: "restore_failed",
                            message: "Restore attempt failed",
                            sessionID: payload.sessionID,
                            handled: false
                        )
                    )
                }
            } else {
                engine.clear(windowID: identity.windowID)
                log(
                    "[HookEventHandler] UserPromptSubmit toggle record corrupted, cleared",
                    level: .warn,
                    fields: [
                        "traceID": traceID,
                        "windowID": String(identity.windowID)
                    ]
                )
            }
        }

        log(
            "[HookEventHandler] UserPromptSubmit no toggle state found",
            fields: [
                "traceID": traceID,
                "sessionID": payload.sessionID,
                "windowID": String(identity.windowID),
                "totalMs": String(elapsedMilliseconds(since: handleStartedAt))
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

}
