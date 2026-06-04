import Testing
import Foundation
@testable import VibeFocusKit

@Suite("Window Move Decision")
@MainActor
struct WindowMoveDecisionTests {

    // MARK: - autoFocusDisabled

    @Test("autoFocus disabled → autoFocusDisabled")
    func autoFocusDisabled() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: false,
            hasBinding: true, bindingVerified: true,
            isWindowOnMainScreen: false, isInCooldown: false,
            bindingAge: 0,
            pidMatches: nil, isTerminalOrIDE: true
        )
        assertDecision(result, expected: "autoFocusDisabled")
    }

    // MARK: - No binding

    @Test("no binding → noBindingSkip")
    func noBindingSkip() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: true,
            hasBinding: false, bindingVerified: false,
            isWindowOnMainScreen: false, isInCooldown: false,
            bindingAge: 0,
            pidMatches: nil, isTerminalOrIDE: true
        )
        assertDecision(result, expected: "noBindingSkip")
    }

    // MARK: - Binding verification

    @Test("binding exists but not verified → bindingVerificationFailed")
    func bindingNotVerified() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: true,
            hasBinding: true, bindingVerified: false,
            isWindowOnMainScreen: false, isInCooldown: false,
            bindingAge: 0,
            pidMatches: nil, isTerminalOrIDE: true
        )
        assertDecision(result, expected: "bindingVerificationFailed")
    }

    // MARK: - Already on main screen

    @Test("window already on main screen → alreadyOnMainScreen")
    func alreadyOnMainScreen() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: true,
            hasBinding: true, bindingVerified: true,
            isWindowOnMainScreen: true, isInCooldown: false,
            bindingAge: 0,
            pidMatches: nil, isTerminalOrIDE: true
        )
        assertDecision(result, expected: "alreadyOnMainScreen")
    }

    // MARK: - Restore cooldown

    @Test("window in restore cooldown → restoreCooldownActive")
    func restoreCooldownActive() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: true,
            hasBinding: true, bindingVerified: true,
            isWindowOnMainScreen: false, isInCooldown: true,
            bindingAge: 0,
            pidMatches: nil, isTerminalOrIDE: true
        )
        assertDecision(result, expected: "restoreCooldownActive")
    }

    @Test("cooldown takes priority over stale binding check")
    func cooldownPriorityOverStale() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: true,
            hasBinding: true, bindingVerified: true,
            isWindowOnMainScreen: false, isInCooldown: true,
            bindingAge: 3600,
            pidMatches: false, isTerminalOrIDE: true
        )
        assertDecision(result, expected: "restoreCooldownActive")
    }

    // MARK: - Stale binding

    @Test("binding age > 30min + PID mismatch → staleBindingPIDMismatch")
    func staleBindingPIDMismatch() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: true,
            hasBinding: true, bindingVerified: true,
            isWindowOnMainScreen: false, isInCooldown: false,
            bindingAge: 3600,
            pidMatches: false, isTerminalOrIDE: true
        )
        assertDecision(result, expected: "staleBindingPIDMismatch")
    }

    @Test("binding age > 30min + PID matches → proceedToMove")
    func staleBindingPIDMatches() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: true,
            hasBinding: true, bindingVerified: true,
            isWindowOnMainScreen: false, isInCooldown: false,
            bindingAge: 3600,
            pidMatches: true, isTerminalOrIDE: true
        )
        if case .proceedToMove = result { } else {
            #expect(Bool(false), "Expected .proceedToMove, got \(result)")
        }
    }

    @Test("binding age > 30min + window not found (nil) → proceedToMove")
    func staleBindingWindowNotFound() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: true,
            hasBinding: true, bindingVerified: true,
            isWindowOnMainScreen: false, isInCooldown: false,
            bindingAge: 3600,
            pidMatches: nil, isTerminalOrIDE: true
        )
        if case .proceedToMove = result { } else {
            #expect(Bool(false), "Expected .proceedToMove, got \(result)")
        }
    }

    @Test("binding age < 30min + PID mismatch → proceedToMove (age check first)")
    func youngBindingPIDMismatch() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: true,
            hasBinding: true, bindingVerified: true,
            isWindowOnMainScreen: false, isInCooldown: false,
            bindingAge: 100,
            pidMatches: false, isTerminalOrIDE: true
        )
        if case .proceedToMove = result { } else {
            #expect(Bool(false), "Expected .proceedToMove, got \(result)")
        }
    }

    // MARK: - Non-terminal window

    @Test("non-terminal/IDE window → nonTerminalWindow")
    func nonTerminalWindow() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: true,
            hasBinding: true, bindingVerified: true,
            isWindowOnMainScreen: false, isInCooldown: false,
            bindingAge: 100,
            pidMatches: true, isTerminalOrIDE: false
        )
        assertDecision(result, expected: "nonTerminalWindow")
    }

    // MARK: - Proceed to move

    @Test("all valid → proceedToMove with binding source")
    func proceedToMoveBinding() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: true,
            hasBinding: true, bindingVerified: true,
            isWindowOnMainScreen: false, isInCooldown: false,
            bindingAge: 100,
            pidMatches: true, isTerminalOrIDE: true
        )
        if case .proceedToMove(let source) = result {
            #expect(source == "binding")
        } else {
            #expect(Bool(false), "Expected .proceedToMove, got \(result)")
        }
    }

    // MARK: - remoteOnly (Stop for remote sessions only)

    @Test("remoteOnly + local binding → localBindingSkip")
    func remoteOnlyLocalBindingSkip() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: true,
            hasBinding: true, bindingVerified: true,
            isWindowOnMainScreen: false, isInCooldown: false,
            bindingAge: 100,
            pidMatches: true, isTerminalOrIDE: true,
            remoteOnly: true, isLocalBinding: true
        )
        assertDecision(result, expected: "localBindingSkip")
    }

    @Test("remoteOnly + remote binding → proceedToMove")
    func remoteOnlyRemoteBindingProceeds() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: true,
            hasBinding: true, bindingVerified: true,
            isWindowOnMainScreen: false, isInCooldown: false,
            bindingAge: 100,
            pidMatches: true, isTerminalOrIDE: true,
            remoteOnly: true, isLocalBinding: false
        )
        if case .proceedToMove = result { } else {
            #expect(Bool(false), "Expected .proceedToMove, got \(result)")
        }
    }

    @Test("remoteOnly + autoFocus disabled → autoFocusDisabled takes priority")
    func remoteOnlyAutoFocusPriority() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: false,
            hasBinding: true, bindingVerified: true,
            isWindowOnMainScreen: false, isInCooldown: false,
            bindingAge: 100,
            pidMatches: true, isTerminalOrIDE: true,
            remoteOnly: true, isLocalBinding: true
        )
        assertDecision(result, expected: "autoFocusDisabled")
    }

    @Test("remoteOnly=false + local binding → proceedToMove (no restriction)")
    func noRemoteOnlyLocalBindingProceeds() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: true,
            hasBinding: true, bindingVerified: true,
            isWindowOnMainScreen: false, isInCooldown: false,
            bindingAge: 100,
            pidMatches: true, isTerminalOrIDE: true,
            remoteOnly: false, isLocalBinding: true
        )
        if case .proceedToMove = result { } else {
            #expect(Bool(false), "Expected .proceedToMove, got \(result)")
        }
    }

    @Test("remoteOnly + local binding + hasMachineLabel → localBindingSkip (all local bindings skipped in remoteOnly mode)")
    func remoteOnlyLocalBindingWithMachineLabel() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: true,
            hasBinding: true, bindingVerified: true,
            isWindowOnMainScreen: false, isInCooldown: false,
            bindingAge: 100,
            pidMatches: true, isTerminalOrIDE: true,
            remoteOnly: true, isLocalBinding: true, hasMachineLabel: true
        )
        if case .localBindingSkip = result { } else {
            #expect(Bool(false), "Expected .localBindingSkip, got \(result)")
        }
    }

    // MARK: - Guard priority (decision order matters)

    @Test("autoFocus disabled takes priority over all other conditions")
    func autoFocusDisabledPriority() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: false,
            hasBinding: true, bindingVerified: true,
            isWindowOnMainScreen: false, isInCooldown: true,
            bindingAge: 3600,
            pidMatches: false, isTerminalOrIDE: true
        )
        assertDecision(result, expected: "autoFocusDisabled")
    }

    @Test("binding verification failure takes priority over screen position")
    func bindingVerificationPriority() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: true,
            hasBinding: true, bindingVerified: false,
            isWindowOnMainScreen: false, isInCooldown: false,
            bindingAge: 0,
            pidMatches: nil, isTerminalOrIDE: true
        )
        assertDecision(result, expected: "bindingVerificationFailed")
    }

    // MARK: - Helper

    private func assertDecision(
        _ result: HookEventHandler.WindowMoveDecision,
        expected: String
    ) {
        let actual: String
        switch result {
        case .autoFocusDisabled: actual = "autoFocusDisabled"
        case .localBindingSkip: actual = "localBindingSkip"
        case .noBindingSkip: actual = "noBindingSkip"
        case .bindingVerificationFailed: actual = "bindingVerificationFailed"
        case .alreadyCompleted: actual = "alreadyCompleted"
        case .alreadyOnMainScreen: actual = "alreadyOnMainScreen"
        case .restoreCooldownActive: actual = "restoreCooldownActive"
        case .staleBindingPIDMismatch: actual = "staleBindingPIDMismatch"
        case .nonTerminalWindow: actual = "nonTerminalWindow"
        case .proceedToMove: actual = "proceedToMove"
        }
        #expect(actual == expected, "Expected \(expected), got \(actual)")
    }
}
