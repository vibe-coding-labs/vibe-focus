import Testing
import Foundation
import CoreGraphics
@testable import VibeFocusKit

@Suite("Binding Verification Decision")
@MainActor
struct BindingVerificationTests {

    private func makeEntry(windowID: UInt32 = 42, ownerPID: pid_t = 1234) -> CGWindowEntry? {
        let dict: [String: Any] = [
            kCGWindowNumber as String: UInt32(windowID),
            kCGWindowOwnerPID as String: ownerPID
        ]
        return CGWindowEntry(from: dict)
    }

    @Test("valid: PID exists + window found + PID matches")
    func validBinding() throws {
        let entry = try #require(makeEntry(windowID: 42, ownerPID: 1234))
        let result = SessionWindowRegistry.decideBindingVerification(
            pidExists: true, windowEntry: entry, expectedPID: 1234
        )
        assertResult(result, expected: "valid")
    }

    @Test("pidNoLongerExists: PID gone")
    func pidGone() {
        let result = SessionWindowRegistry.decideBindingVerification(
            pidExists: false, windowEntry: nil, expectedPID: 1234
        )
        assertResult(result, expected: "pidNoLongerExists")
    }

    @Test("pidNoLongerExists takes priority even if window exists")
    func pidGonePriority() throws {
        let entry = try #require(makeEntry(windowID: 42, ownerPID: 1234))
        let result = SessionWindowRegistry.decideBindingVerification(
            pidExists: false, windowEntry: entry, expectedPID: 1234
        )
        assertResult(result, expected: "pidNoLongerExists")
    }

    @Test("windowNotFound: PID exists but window not in CG list")
    func windowNotFound() {
        let result = SessionWindowRegistry.decideBindingVerification(
            pidExists: true, windowEntry: nil, expectedPID: 1234
        )
        assertResult(result, expected: "windowNotFound")
    }

    @Test("windowPIDMismatch: window found but owner PID differs")
    func pidMismatch() throws {
        let entry = try #require(makeEntry(windowID: 42, ownerPID: 9999))
        let result = SessionWindowRegistry.decideBindingVerification(
            pidExists: true, windowEntry: entry, expectedPID: 1234
        )
        if case .windowPIDMismatch(let expected, let actual) = result {
            #expect(expected == 1234)
            #expect(actual == 9999)
        } else {
            Issue.record("Expected .windowPIDMismatch, got \(result)")
        }
    }

    private func assertResult(
        _ result: SessionWindowRegistry.BindingVerificationResult,
        expected: String
    ) {
        let actual: String
        switch result {
        case .valid: actual = "valid"
        case .pidNoLongerExists: actual = "pidNoLongerExists"
        case .windowNotFound: actual = "windowNotFound"
        case .windowPIDMismatch: actual = "windowPIDMismatch"
        }
        #expect(actual == expected, "Expected \(expected), got \(actual)")
    }
}
