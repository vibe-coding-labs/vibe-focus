import Foundation
import Cocoa

@MainActor
final class HookEventHandler {
    static let shared = HookEventHandler()

    private static let autoRestoreCooldownSeconds: TimeInterval = 30
    private var lastAutoRestoreByWindowID: [UInt32: Date] = [:]

    private init() {}

    // MARK: - Pure Decision Helpers (extracted for testability)

    /// Pure: is a window still in the auto-restore cooldown period?
    static func isInCooldown(lastRestore: Date?, now: Date = Date(), cooldownSeconds: TimeInterval = 30) -> Bool {
        guard let lastRestore else { return false }
        return now.timeIntervalSince(lastRestore) < cooldownSeconds
    }

    /// Check if a window is in move cooldown — recently restored by user or UPS.
    /// Used by Stop handler to avoid re-moving a window the user just put back.
    func isWindowInMoveCooldown(windowID: UInt32) -> Bool {
        return Self.isInCooldown(lastRestore: lastAutoRestoreByWindowID[windowID])
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
                "terminalCtxUseful": String(payload.terminalCtx?.hasUsefulContext ?? false),
                "isRemote": String(payload.terminalCtx?.isRemote ?? false),
                "machineLabel": payload.terminalCtx?.machineLabel ?? "nil"
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
            log(
                "[handleSessionStart] remote session detected, resolving via machine_label",
                level: .debug,
                fields: [
                    "sessionID": payload.sessionID,
                    "machineLabel": label,
                    "tty": terminalCtx.tty ?? "nil",
                    "ppid": terminalCtx.ppid ?? "nil"
                ]
            )
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
            // 本地机器：用 PPID/TTY 进程树匹配
            log(
                "[handleSessionStart] local session, resolving via TTY/PPID",
                level: .debug,
                fields: [
                    "sessionID": payload.sessionID,
                    "tty": terminalCtx.tty ?? "nil",
                    "ppid": terminalCtx.ppid ?? "nil",
                    "termSessionID": terminalCtx.termSessionID ?? "nil"
                ]
            )
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
        let resolvedBindingType: WindowState.BindingType = terminalCtx.isRemote ? .remote : .local
        SessionWindowRegistry.shared.bind(
            sessionID: payload.sessionID,
            windowIdentity: identity,
            terminalTTY: payload.terminalCtx?.tty,
            terminalSessionID: payload.terminalCtx?.termSessionID,
            itermSessionID: payload.terminalCtx?.itermSessionID,
            cwd: payload.cwd,
            model: payload.model,
            bindingType: resolvedBindingType
        )
        AuditLogger.shared.record(
            eventType: "session_bind",
            windowID: identity.windowID,
            pid: identity.pid,
            sessionID: payload.sessionID,
            details: [
                "app": identity.appName ?? "unknown",
                "isRemote": String(terminalCtx.isRemote),
                "bindingType": String(describing: resolvedBindingType),
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

    /// UserPromptSubmit 事件处理：确保终端窗口在主屏可见。
    ///
    /// **设计原则（单向移动）**：只在窗口不在主屏时将其拉到主屏，永远不会把窗口推离主屏。
    /// 旧逻辑使用 ToggleEngine.restore() 会把窗口移回 origFrame（副屏），
    /// 导致 Stop→UPS→Stop→UPS 无限循环，窗口在主屏和副屏之间反复跳动。
    func handleUserPromptSubmit(
        payload: ClaudeHookPayload
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        let traceID = makeOperationID(prefix: "ups")

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
        guard let identity = resolveWindowIdentity(payload: payload, traceID: traceID, startedAt: Date()) else {
            log(
                "[HookEventHandler] UserPromptSubmit: window identity resolution failed",
                level: .warn,
                fields: [
                    "traceID": traceID,
                    "sessionID": payload.sessionID,
                    "hasTerminalCtx": String(payload.terminalCtx != nil),
                    "machineLabel": payload.terminalCtx?.machineLabel ?? "nil"
                ]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "no_binding_skip",
                    message: "Could not resolve window identity",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 2. 窗口已在主屏 → 无需操作
        if WindowManager.shared.isWindowOnMainScreen(windowID: identity.windowID) {
            log(
                "[HookEventHandler] UserPromptSubmit: window already on main screen, skipping",
                fields: [
                    "traceID": traceID,
                    "windowID": String(identity.windowID),
                    "sessionID": payload.sessionID
                ]
            )
            SessionWindowRegistry.shared.reactivate(sessionID: payload.sessionID)
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "already_on_main_screen",
                    message: "Window already on main screen, no action needed",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 3. 冷却检查：同一窗口在冷却期内不重复移动
        if let lastRestore = lastAutoRestoreByWindowID[identity.windowID],
           Date().timeIntervalSince(lastRestore) < Self.autoRestoreCooldownSeconds {
            let remaining = Int(Self.autoRestoreCooldownSeconds - Date().timeIntervalSince(lastRestore))
            log(
                "[HookEventHandler] UserPromptSubmit: cooldown active, skipping",
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

        // 4. 窗口不在主屏 → 移到主屏（单向操作，不会推离主屏）
        log(
            "[HookEventHandler] UserPromptSubmit: moving window to main screen",
            level: .info,
            fields: [
                "traceID": traceID,
                "windowID": String(identity.windowID),
                "app": identity.appName ?? "unknown",
                "sessionID": payload.sessionID
            ]
        )

        let moved = WindowManager.shared.moveWindowToMainScreen(
            identity: identity,
            reason: .userPromptSubmit,
            sessionID: payload.sessionID
        )

        if moved {
            lastAutoRestoreByWindowID[identity.windowID] = Date()
            SessionWindowRegistry.shared.reactivate(sessionID: payload.sessionID)
        }

        return (
            200,
            ClaudeHookResponse(
                ok: true,
                code: moved ? "moved_to_main" : "move_failed",
                message: moved ? "Window moved to main screen" : "Failed to move window to main screen",
                sessionID: payload.sessionID,
                handled: moved
            )
        )
    }

    // MARK: - UserPromptSubmit Sub-steps

    /// Window identity resolution decision — extracted for testability.
    enum WindowResolutionSource {
        case binding(WindowIdentity)
    }

    /// Pure decision logic for resolveWindowIdentity.
    /// Returns the resolution source or nil if no window can be identified.
    static func decideWindowResolution(
        hasBinding: Bool,
        bindingVerified: Bool,
        bindingIdentity: WindowIdentity?
    ) -> WindowResolutionSource? {
        if hasBinding {
            if bindingVerified, let identity = bindingIdentity {
                return .binding(identity)
            }
            return nil
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
            log(
                "[HookEventHandler] resolveWindowIdentity: found binding",
                level: .debug,
                fields: [
                    "traceID": traceID,
                    "sessionID": payload.sessionID,
                    "windowID": String(state.windowID),
                    "bindingType": String(describing: state.bindingType),
                    "app": state.appName ?? "unknown"
                ]
            )
            if SessionWindowRegistry.shared.verifyBinding(state) {
                log(
                    "[HookEventHandler] resolveWindowIdentity: binding verified",
                    level: .debug,
                    fields: [
                        "traceID": traceID,
                        "windowID": String(state.windowID),
                        "source": "binding"
                    ]
                )
                return WindowIdentity(from: state)
            }
            log(
                "[HookEventHandler] resolveWindowIdentity: binding verification failed",
                level: .warn,
                fields: [
                    "traceID": traceID,
                    "sessionID": payload.sessionID,
                    "boundWindowID": String(state.windowID)
                ]
            )
            return nil
        }

        // 无绑定 — 尝试通过 machineLabel 自愈远程 binding
        if let label = payload.terminalCtx?.machineLabel, !label.isEmpty {
            log(
                "[HookEventHandler] resolveWindowIdentity: no binding, attempting remote self-heal",
                level: .info,
                fields: [
                    "traceID": traceID,
                    "sessionID": payload.sessionID,
                    "machineLabel": label
                ]
            )
            if let identity = resolveRemoteBinding(label: label, sessionID: payload.sessionID) {
                log(
                    "[HookEventHandler] resolveWindowIdentity: remote self-heal succeeded, registering binding",
                    level: .info,
                    fields: [
                        "traceID": traceID,
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
                return identity
            }
        }

        log(
            "[HookEventHandler] resolveWindowIdentity: no binding, cannot identify window",
            level: .warn,
            fields: [
                "traceID": traceID,
                "sessionID": payload.sessionID
            ]
        )
        return nil
    }

    /// Restore eligibility decision — extracted for testability.
    /// ⚠️ 注意：此 enum 及 decideRestoreEligibility 仅被测试引用，生产代码不再使用。
    /// UserPromptSubmit 现在直接使用 moveWindowToMainScreen（单向移动到主屏）。
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
        // 不再要求窗口必须在主屏 — 窗口在副屏但有 ToggleRecord 时也应该可以 restore
        guard let record else { return .noRecord }
        guard let mainScreenFrame, record.isValid(mainScreenFrame: mainScreenFrame) else {
            return .recordInvalid(windowID: record.windowID)
        }
        return .eligible(record: record, mainScreenFrame: mainScreenFrame)
    }

    // MARK: - Stop

    func handleStop(
        payload: ClaudeHookPayload
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        // triggerOnStop=true: 处理所有 session（本地+远程）
        // triggerOnStop=false: 仅处理远程 session（跳过本地绑定）
        let remoteOnly = !ClaudeHookPreferences.triggerOnStop
        return handleWindowMoveTrigger(payload: payload, triggerName: "Stop", remoteOnly: remoteOnly)
    }

    func clearAutoRestoreCooldown(windowID: UInt32) {
        lastAutoRestoreByWindowID.removeValue(forKey: windowID)
    }

    /// Stop 移动窗口后设置冷却期，阻止 UserPromptSubmit 立即 restore 同一窗口
    func setMoveCooldown(windowID: UInt32) {
        lastAutoRestoreByWindowID[windowID] = Date()
    }

}
