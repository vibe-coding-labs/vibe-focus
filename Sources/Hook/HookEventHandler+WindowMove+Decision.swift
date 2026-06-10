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
