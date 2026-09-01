// HookEventHandler+WindowMove+Decision.swift
// VibeFocus — Window move trigger 决策逻辑（纯函数）
// 从 HookEventHandler+WindowMove.swift 中提取

import Foundation

@MainActor
extension HookEventHandler {

    // MARK: - Window Move Decision Logic (extracted for testability)

    /// Window move trigger decision — all possible outcomes.
    /// 顺序即生产 handleWindowMoveTrigger 的守护顺序（决策树唯一事实源），
    /// 生产不得内联重写本顺序（2.16 第一刀同构约束）。
    enum WindowMoveDecision: Equatable {
        case autoFocusDisabled
        case localBindingSkip
        case noBindingSkip
        case bindingVerificationFailed
        case alreadyOnMainScreen
        case restoreCooldownActive
        case staleBindingPIDMismatch
        case nonTerminalWindow
        case proceedToMove(source: String)
    }
}

// MARK: - Decision Logging Extension

extension HookEventHandler.WindowMoveDecision {
    /// 结构化日志描述，用于统一决策路径日志格式
    var logDescription: String {
        switch self {
        case .autoFocusDisabled:
            return "auto_focus_disabled"
        case .localBindingSkip:
            return "local_binding_skip"
        case .noBindingSkip:
            return "no_binding_skip"
        case .bindingVerificationFailed:
            return "binding_verification_failed"
        case .alreadyOnMainScreen:
            return "already_on_main_screen"
        case .restoreCooldownActive:
            return "restore_cooldown_active"
        case .staleBindingPIDMismatch:
            return "stale_binding_pid_mismatch"
        case .nonTerminalWindow:
            return "non_terminal_window"
        case .proceedToMove(let source):
            return "proceed_to_move(source=\(source))"
        }
    }
}

@MainActor
extension HookEventHandler {

    // MARK: - Window Move Decision Logic (extracted for testability)

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
        remoteOnly: Bool = false
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

        // hasBinding 已在上方 guard 保证为 true，source 恒为 "binding"
        return .proceedToMove(source: "binding")
    }

    /// 决策 → hook HTTP 响应映射（纯函数，决策与响应码的唯一对照表）。
    /// `.proceedToMove` 返回 nil——成功/失败响应由执行器按移动结果产生。
    /// 生产 handleWindowMoveTrigger 的所有提前返回都必须经由本函数，
    /// 禁止内联手写响应码（历史上 "already_completed" 曾在这里漂移出两个平行版本）。
    static func httpResponse(
        for decision: WindowMoveDecision,
        triggerName: String,
        sessionID: String
    ) -> (statusCode: Int, response: ClaudeHookResponse)? {
        func respond(ok: Bool, code: String, message: String, handled: Bool) -> (Int, ClaudeHookResponse) {
            (200, ClaudeHookResponse(ok: ok, code: code, message: message, sessionID: sessionID, handled: handled))
        }
        switch decision {
        case .autoFocusDisabled:
            return respond(
                ok: true, code: "auto_focus_disabled",
                message: "\(triggerName) received, auto focus disabled", handled: false
            )
        case .localBindingSkip:
            return respond(
                ok: true, code: "trigger_disabled_skip",
                message: "\(triggerName) skipped (triggerOnStop=false, no window movement)", handled: false
            )
        case .noBindingSkip:
            return respond(
                ok: true, code: "no_binding_skip",
                message: "No session binding, skipping window move", handled: false
            )
        case .bindingVerificationFailed:
            return respond(
                ok: true, code: "binding_verification_failed",
                message: "Binding verification failed, skipping window move", handled: false
            )
        case .alreadyOnMainScreen:
            return respond(
                ok: true, code: "already_on_main_screen",
                message: "Window already on main screen, no action needed", handled: false
            )
        case .restoreCooldownActive:
            return respond(
                ok: true, code: "restore_cooldown_active",
                message: "Window recently restored, skipping move (cooldown active)", handled: false
            )
        case .staleBindingPIDMismatch:
            return respond(
                ok: true, code: "stale_binding_pid_mismatch",
                message: "Stale binding: window PID no longer matches", handled: false
            )
        case .nonTerminalWindow:
            return respond(
                ok: true, code: "non_terminal_window",
                message: "Resolved window is not a terminal/IDE app, skipping", handled: false
            )
        case .proceedToMove:
            return nil
        }
    }

    // MARK: - Terminal/IDE App Detection

    static func isTerminalOrIDEApp(appName: String?, bundleIdentifier: String?) -> Bool {
        TerminalRegistry.isTerminalOrIDEApp(appName: appName, bundleIdentifier: bundleIdentifier)
    }
}
