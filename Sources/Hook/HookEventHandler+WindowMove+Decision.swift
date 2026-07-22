// HookEventHandler+WindowMove+Decision.swift
// VibeFocus — Window move trigger 决策逻辑（纯函数）
// 从 HookEventHandler+WindowMove.swift 中提取

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
        case .alreadyCompleted:
            return "already_completed"
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

    // MARK: - Terminal/IDE App Detection

    static func isTerminalOrIDEApp(appName: String?, bundleIdentifier: String?) -> Bool {
        TerminalRegistry.isTerminalOrIDEApp(appName: appName, bundleIdentifier: bundleIdentifier)
    }
}
