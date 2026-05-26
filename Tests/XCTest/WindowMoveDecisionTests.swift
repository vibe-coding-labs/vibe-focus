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
            isCompleted: false,
            isWindowOnMainScreen: false, bindingAge: 0,
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
            isCompleted: false,
            isWindowOnMainScreen: false, bindingAge: 0,
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
            isCompleted: false,
            isWindowOnMainScreen: false, bindingAge: 0,
            pidMatches: nil, isTerminalOrIDE: true
        )
        assertDecision(result, expected: "bindingVerificationFailed")
    }

    // MARK: - Already completed

    @Test("binding verified but completed → alreadyCompleted")
    func alreadyCompleted() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: true,
            hasBinding: true, bindingVerified: true,
            isCompleted: true,
            isWindowOnMainScreen: false, bindingAge: 0,
            pidMatches: nil, isTerminalOrIDE: true
        )
        assertDecision(result, expected: "alreadyCompleted")
    }

    // MARK: - Already on main screen

    @Test("window already on main screen → alreadyOnMainScreen")
    func alreadyOnMainScreen() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: true,
            hasBinding: true, bindingVerified: true,
            isCompleted: false,
            isWindowOnMainScreen: true, bindingAge: 0,
            pidMatches: nil, isTerminalOrIDE: true
        )
        assertDecision(result, expected: "alreadyOnMainScreen")
    }

    // MARK: - Stale binding

    @Test("binding age > 30min + PID mismatch → staleBindingPIDMismatch")
    func staleBindingPIDMismatch() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: true,
            hasBinding: true, bindingVerified: true,
            isCompleted: false,
            isWindowOnMainScreen: false, bindingAge: 3600,
            pidMatches: false, isTerminalOrIDE: true
        )
        assertDecision(result, expected: "staleBindingPIDMismatch")
    }

    @Test("binding age > 30min + PID matches → proceedToMove")
    func staleBindingPIDMatches() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: true,
            hasBinding: true, bindingVerified: true,
            isCompleted: false,
            isWindowOnMainScreen: false, bindingAge: 3600,
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
            isCompleted: false,
            isWindowOnMainScreen: false, bindingAge: 3600,
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
            isCompleted: false,
            isWindowOnMainScreen: false, bindingAge: 100,
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
            isCompleted: false,
            isWindowOnMainScreen: false, bindingAge: 100,
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
            isCompleted: false,
            isWindowOnMainScreen: false, bindingAge: 100,
            pidMatches: true, isTerminalOrIDE: true
        )
        if case .proceedToMove(let source) = result {
            #expect(source == "binding")
        } else {
            #expect(Bool(false), "Expected .proceedToMove, got \(result)")
        }
    }

    // MARK: - Guard priority (decision order matters)

    @Test("autoFocus disabled takes priority over all other conditions")
    func autoFocusDisabledPriority() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: false,
            hasBinding: true, bindingVerified: true,
            isCompleted: false,
            isWindowOnMainScreen: false, bindingAge: 3600,
            pidMatches: false, isTerminalOrIDE: true
        )
        assertDecision(result, expected: "autoFocusDisabled")
    }

    @Test("binding verification failure takes priority over isCompleted")
    func bindingVerificationPriority() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: true,
            hasBinding: true, bindingVerified: false,
            isCompleted: true,
            isWindowOnMainScreen: false, bindingAge: 0,
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
        case .noBindingSkip: actual = "noBindingSkip"
        case .bindingVerificationFailed: actual = "bindingVerificationFailed"
        case .alreadyCompleted: actual = "alreadyCompleted"
        case .alreadyOnMainScreen: actual = "alreadyOnMainScreen"
        case .staleBindingPIDMismatch: actual = "staleBindingPIDMismatch"
        case .nonTerminalWindow: actual = "nonTerminalWindow"
        case .proceedToMove: actual = "proceedToMove"
        }
        #expect(actual == expected, "Expected \(expected), got \(actual)")
    }
}
