import Testing
import Foundation
@testable import VibeFocusKit

@Suite("Stop Debounce and Cooldown Logic")
@MainActor
struct StopDebounceAndCooldownTests {

    // MARK: - shouldDebounceStop

    @Test("shouldDebounceStop: elapsed < threshold → true")
    func debounceActive() {
        #expect(HookEventHandler.shouldDebounceStop(elapsed: 5, threshold: 30))
    }

    @Test("shouldDebounceStop: elapsed == threshold → false")
    func debounceExactThreshold() {
        #expect(!HookEventHandler.shouldDebounceStop(elapsed: 30, threshold: 30))
    }

    @Test("shouldDebounceStop: elapsed > threshold → false")
    func debounceExpired() {
        #expect(!HookEventHandler.shouldDebounceStop(elapsed: 31, threshold: 30))
    }

    @Test("shouldDebounceStop: zero elapsed → true")
    func debounceZeroElapsed() {
        #expect(HookEventHandler.shouldDebounceStop(elapsed: 0, threshold: 30))
    }

    @Test("shouldDebounceStop: very small elapsed → true")
    func debounceSmallElapsed() {
        #expect(HookEventHandler.shouldDebounceStop(elapsed: 0.001, threshold: 30))
    }

    @Test("shouldDebounceStop: negative elapsed → true (clock skew)")
    func debounceNegativeElapsed() {
        #expect(HookEventHandler.shouldDebounceStop(elapsed: -1, threshold: 30))
    }

    @Test("shouldDebounceStop: custom threshold respected")
    func debounceCustomThreshold() {
        #expect(HookEventHandler.shouldDebounceStop(elapsed: 5, threshold: 10))
        #expect(!HookEventHandler.shouldDebounceStop(elapsed: 15, threshold: 10))
    }

    // MARK: - isInCooldown

    @Test("isInCooldown: nil lastRestore → false")
    func cooldownNilLastRestore() {
        #expect(!HookEventHandler.isInCooldown(lastRestore: nil))
    }

    @Test("isInCooldown: recent restore → true")
    func cooldownRecent() {
        let now = Date()
        let recent = now.addingTimeInterval(-5)
        #expect(HookEventHandler.isInCooldown(lastRestore: recent, now: now, cooldownSeconds: 30))
    }

    @Test("isInCooldown: exactly at boundary → false")
    func cooldownExactBoundary() {
        let now = Date()
        let boundary = now.addingTimeInterval(-30)
        #expect(!HookEventHandler.isInCooldown(lastRestore: boundary, now: now, cooldownSeconds: 30))
    }

    @Test("isInCooldown: past cooldown period → false")
    func cooldownExpired() {
        let now = Date()
        let past = now.addingTimeInterval(-60)
        #expect(!HookEventHandler.isInCooldown(lastRestore: past, now: now, cooldownSeconds: 30))
    }

    @Test("isInCooldown: future restore time → true")
    func cooldownFuture() {
        let now = Date()
        let future = now.addingTimeInterval(10)
        #expect(HookEventHandler.isInCooldown(lastRestore: future, now: now, cooldownSeconds: 30))
    }

    @Test("isInCooldown: custom cooldown seconds")
    func cooldownCustomSeconds() {
        let now = Date()
        let recent = now.addingTimeInterval(-15)
        #expect(HookEventHandler.isInCooldown(lastRestore: recent, now: now, cooldownSeconds: 20))
        #expect(!HookEventHandler.isInCooldown(lastRestore: recent, now: now, cooldownSeconds: 10))
    }

    @Test("isInCooldown: 1 second before expiry → true")
    func cooldownOneSecondBeforeExpiry() {
        let now = Date()
        let restore = now.addingTimeInterval(-29)
        #expect(HookEventHandler.isInCooldown(lastRestore: restore, now: now, cooldownSeconds: 30))
    }
}
