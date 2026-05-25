import Foundation
import Cocoa

@MainActor
final class HookEventHandler {
    static let shared = HookEventHandler()

    private var lastActivityBySession: [String: Date] = [:]
    private let stopDebounceInterval: TimeInterval = 30.0

    private static let autoRestoreCooldownSeconds: TimeInterval = 30
    private var lastAutoRestoreByWindowID: [UInt32: Date] = [:]

    private init() {}

    // MARK: - Pure Decision Helpers (extracted for testability)

    /// Pure: should a Stop event be debounced because the session was recently active?
    static func shouldDebounceStop(elapsed: TimeInterval, threshold: TimeInterval = 30.0) -> Bool {
        elapsed < threshold
    }

    /// Pure: is a window still in the auto-restore cooldown period?
    static func isInCooldown(lastRestore: Date?, now: Date = Date(), cooldownSeconds: TimeInterval = 30) -> Bool {
        guard let lastRestore else { return false }
        return now.timeIntervalSince(lastRestore) < cooldownSeconds
    }

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
        AuditLogger.shared.record(
            eventType: "session_bind",
            windowID: identity.windowID,
            pid: identity.pid,
            sessionID: payload.sessionID,
            details: [
                "app": identity.appName ?? "unknown",
                "isRemote": String(terminalCtx.isRemote),
                "cwd": payload.cwd ?? "nil"
            ]
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

        // 1. 解析窗口身份
        guard let identity = resolveWindowIdentity(payload: payload, traceID: traceID, startedAt: handleStartedAt) else {
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "no_binding_skip",
                    message: "Could not resolve window identity",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 2. 冷却检查：同一窗口在冷却期内不重复 auto-restore
        if let lastRestore = lastAutoRestoreByWindowID[identity.windowID],
           Date().timeIntervalSince(lastRestore) < Self.autoRestoreCooldownSeconds {
            let remaining = Int(Self.autoRestoreCooldownSeconds - Date().timeIntervalSince(lastRestore))
            log(
                "[HookEventHandler] UserPromptSubmit: auto-restore cooldown active, skipping",
                level: .info,
                fields: [
                    "traceID": traceID,
                    "windowID": String(identity.windowID),
                    "cooldownRemaining": String(remaining) + "s"
                ]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "cooldown_active",
                    message: "Auto-restore cooldown active (\(remaining)s remaining)",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 3. 验证是否应该 restore
        guard let validation = validateRestoreEligibility(identity: identity, traceID: traceID) else {
            // 无 ToggleRecord（如远程 session 从未被 toggle 过）→ fallback: 直接移到主屏
            if !WindowManager.shared.isWindowOnMainScreen(windowID: identity.windowID) {
                log(
                    "[HookEventHandler] UserPromptSubmit: no toggle record, falling back to moveWindowToMainScreen",
                    fields: [
                        "traceID": traceID,
                        "sessionID": payload.sessionID,
                        "windowID": String(identity.windowID)
                    ]
                )
                let moved = WindowManager.shared.moveWindowToMainScreen(
                    identity: identity,
                    reason: .claudeSessionEnd,
                    sessionID: payload.sessionID
                )
                if moved {
                    lastAutoRestoreByWindowID[identity.windowID] = Date()
                }
                return (
                    200,
                    ClaudeHookResponse(
                        ok: true,
                        code: moved ? "window_moved" : "window_move_failed",
                        message: moved ? "Window moved to main screen (no toggle record)" : "Move to main screen failed",
                        sessionID: payload.sessionID,
                        handled: moved
                    )
                )
            }
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "no_action_needed",
                    message: "Window not eligible for restore",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 4. 执行 restore
        let success = executeRestore(identity: identity, validation: validation, traceID: traceID, startedAt: handleStartedAt, sessionID: payload.sessionID)

        if success {
            lastAutoRestoreByWindowID[identity.windowID] = Date()
        }

        return (
            200,
            ClaudeHookResponse(
                ok: true,
                code: success ? "restored" : "restore_failed",
                message: success ? "Window restored to original position" : "Restore attempt failed",
                sessionID: payload.sessionID,
                handled: success
            )
        )
    }

    // MARK: - UserPromptSubmit Sub-steps

    /// Window identity resolution decision — extracted for testability.
    enum WindowResolutionSource {
        case binding(WindowIdentity)
        case terminalContext(WindowIdentity)
        case bindingFailedTerminalFallback(WindowIdentity)
    }

    /// Pure decision logic for resolveWindowIdentity.
    /// Returns the resolution source or nil if no window can be identified.
    static func decideWindowResolution(
        hasBinding: Bool,
        bindingVerified: Bool,
        bindingIdentity: WindowIdentity?,
        hasTerminalContext: Bool,
        terminalContextIdentity: WindowIdentity?
    ) -> WindowResolutionSource? {
        if hasBinding {
            if bindingVerified, let identity = bindingIdentity {
                return .binding(identity)
            }
            // Binding failed verification — try terminal context fallback
            if hasTerminalContext, let identity = terminalContextIdentity {
                return .bindingFailedTerminalFallback(identity)
            }
            return nil
        }
        // No binding — try terminal context
        if hasTerminalContext, let identity = terminalContextIdentity {
            return .terminalContext(identity)
        }
        return nil
    }

    private func resolveWindowIdentity(
        payload: ClaudeHookPayload,
        traceID: String,
        startedAt: Date
    ) -> WindowIdentity? {
        let state = SessionWindowRegistry.shared.binding(for: payload.sessionID)

        if let state {
            if SessionWindowRegistry.shared.verifyBinding(state) {
                return WindowIdentity(from: state)
            }
            // 绑定验证失败 — 降级到 terminal context
            log(
                "[HookEventHandler] binding verification failed, trying terminal context fallback",
                level: .warn,
                fields: [
                    "traceID": traceID,
                    "sessionID": payload.sessionID,
                    "boundWindowID": String(state.windowID)
                ]
            )
            if let terminalCtx = payload.terminalCtx, terminalCtx.hasUsefulContext {
                if let identity = WindowManager.shared.findWindowByTerminalContext(terminalCtx) {
                    return identity
                }
            }
            return nil
        }

        // 无绑定 — 尝试 terminal context
        if let terminalCtx = payload.terminalCtx, terminalCtx.hasUsefulContext {
            return WindowManager.shared.findWindowByTerminalContext(terminalCtx)
        }

        return nil
    }

    private struct RestoreValidation {
        let record: ToggleRecord
        let mainScreen: NSScreen
    }

    /// Restore eligibility decision — extracted for testability.
    enum RestoreEligibility {
        case eligible(record: ToggleRecord, mainScreenFrame: CGRect)
        case toggleInFlight
        case windowNotOnMainScreen
        case noRecord
        case recordInvalid(windowID: UInt32)
    }

    /// Pure decision logic for validateRestoreEligibility.
    static func decideRestoreEligibility(
        isToggleInFlight: Bool,
        isWindowOnMainScreen: Bool,
        record: ToggleRecord?,
        mainScreenFrame: CGRect?
    ) -> RestoreEligibility {
        if isToggleInFlight { return .toggleInFlight }
        if !isWindowOnMainScreen { return .windowNotOnMainScreen }
        guard let record else { return .noRecord }
        guard let mainScreenFrame, record.isValid(mainScreenFrame: mainScreenFrame) else {
            return .recordInvalid(windowID: record.windowID)
        }
        return .eligible(record: record, mainScreenFrame: mainScreenFrame)
    }

    private func validateRestoreEligibility(
        identity: WindowIdentity,
        traceID: String
    ) -> RestoreValidation? {
        // 防止与手动热键 toggle 冲突
        if HotKeyManager.shared.isToggleInFlight {
            return nil
        }

        // 窗口必须在主屏上
        guard WindowManager.shared.isWindowOnMainScreen(windowID: identity.windowID) else {
            return nil
        }

        // 必须有有效的 toggle record
        let engine = ToggleEngine.shared
        guard let record = engine.load(windowID: identity.windowID) else {
            return nil
        }

        // record 必须通过验证
        guard let mainScreen = WindowManager.shared.getMainScreen(),
              record.isValid(mainScreenFrame: mainScreen.frame) else {
            log(
                "[HookEventHandler] toggle record failed validation",
                level: .warn,
                fields: [
                    "traceID": traceID,
                    "windowID": String(identity.windowID)
                ]
            )
            return nil
        }

        return RestoreValidation(record: record, mainScreen: mainScreen)
    }

    @discardableResult
    private func executeRestore(
        identity: WindowIdentity,
        validation: RestoreValidation,
        traceID: String,
        startedAt: Date,
        sessionID: String
    ) -> Bool {
        let engine = ToggleEngine.shared
        let restoreStart = Date()

        log(
            "[HookEventHandler] UserPromptSubmit calling ToggleEngine.restore",
            level: .info,
            fields: [
                "traceID": traceID,
                "windowID": String(identity.windowID),
                "preRestoreMs": String(elapsedMilliseconds(since: startedAt))
            ]
        )

        let success = engine.restore(
            windowID: identity.windowID,
            fallbackPID: identity.pid,
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
                "totalMs": String(elapsedMilliseconds(since: startedAt))
            ]
        )
        AuditLogger.shared.record(
            eventType: success ? "user_prompt_restore" : "user_prompt_restore_failed",
            windowID: identity.windowID,
            pid: identity.pid,
            sessionID: sessionID,
            details: [
                "restoreMs": String(restoreMs),
                "totalMs": String(elapsedMilliseconds(since: startedAt))
            ]
        )

        return success
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

    func clearAutoRestoreCooldown(windowID: UInt32) {
        lastAutoRestoreByWindowID.removeValue(forKey: windowID)
    }

}
