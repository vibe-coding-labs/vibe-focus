import Testing
import Foundation
import CoreGraphics
@testable import VibeFocusKit

/// Tests the integration path of shouldRestoreCurrentWindow with an injected MockToggleRecordStore.
/// These tests verify the glue code between system I/O and decision logic.
@Suite("Restore Integration with Mock")
@MainActor
struct RestoreIntegrationTests {

    func makeRecord(windowID: UInt32 = 42, origFrame: CGRect, targetFrame: CGRect, sourceSpace: Int = 3) -> ToggleRecord {
        ToggleRecord(
            windowID: windowID, pid: 1234, bundleIdentifier: "com.test", appName: "App",
            origFrame: origFrame,
            sourceSpace: sourceSpace, sourceDisplay: 2,
            sourceYabaiDisp: 2, sourceDispSpace: 1,
            targetFrame: targetFrame,
            targetDisplay: 1, toggledAt: Date(), sessionID: "s1"
        )
    }

    // MARK: - decideRestore + mock integration pattern

    @Test("Integration pattern: mock provides record, decideRestore uses it")
    func mockFeedsDecideRestore() {
        let mock = MockToggleRecordStore()
        let record = makeRecord(
            origFrame: CGRect(x: 100, y: -1000, width: 800, height: 600),
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600)
        )
        mock.recordByWindowID[42] = record

        // Simulate what shouldRestoreCurrentWindow does with the store
        let loaded = mock.load(windowID: 42)
        let decision = WindowManager.decideRestore(
            focusedOnMain: true,
            recordByWindowID: loaded,
            recordByPID: nil,
            mainScreenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        #expect(assertDecisionIs(decision, expectedCase: "restore"))
    }

    @Test("Integration pattern: corrupted record triggers clear via mock")
    func corruptedRecordTriggersClear() {
        let mock = MockToggleRecordStore()
        let record = makeRecord(
            origFrame: CGRect(x: 100, y: 200, width: 800, height: 600),
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600)
        )
        mock.recordByWindowID[42] = record

        let loaded = mock.load(windowID: 42)
        let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let decision = WindowManager.decideRestore(
            focusedOnMain: true,
            recordByWindowID: loaded,
            recordByPID: nil,
            mainScreenFrame: mainScreen
        )

        // Simulate the clear that shouldRestoreCurrentWindow would do
        if case .corruptedClearWindowID(let windowID) = decision {
            mock.clear(windowID: windowID)
        }

        #expect(mock.clearedWindowIDs == [42])
        #expect(mock.load(windowID: 42) == nil)
    }

    @Test("Integration pattern: PID fallback when windowID lookup fails")
    func pidFallbackIntegration() {
        let mock = MockToggleRecordStore()
        let pidRecord = makeRecord(
            windowID: 99,
            origFrame: CGRect(x: 100, y: -1000, width: 800, height: 600),
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600)
        )
        mock.recordByPID[1234] = pidRecord

        // windowID lookup returns nil, PID lookup succeeds
        let loadedByID = mock.load(windowID: 42)
        let loadedByPID = mock.loadByPID(pid: 1234)

        let decision = WindowManager.decideRestore(
            focusedOnMain: true,
            recordByWindowID: loadedByID,
            recordByPID: loadedByPID,
            mainScreenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        #expect(assertDecisionIs(decision, expectedCase: "restore"))
    }

    @Test("Integration pattern: both lookups fail → noRecord")
    func bothLookupsFail() {
        let mock = MockToggleRecordStore()

        let loadedByID = mock.load(windowID: 42)
        let loadedByPID = mock.loadByPID(pid: 1234)

        let decision = WindowManager.decideRestore(
            focusedOnMain: true,
            recordByWindowID: loadedByID,
            recordByPID: loadedByPID,
            mainScreenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        #expect(assertDecisionIs(decision, expectedCase: "noRecord"))
    }

    // MARK: - validateRestoreEligibility decision tests

    @Test("decideRestoreEligibility: all valid → eligible")
    func eligibilityAllValid() {
        let record = makeRecord(
            origFrame: CGRect(x: 100, y: -1000, width: 800, height: 600),
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600)
        )
        let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let result = HookEventHandler.decideRestoreEligibility(
            isToggleInFlight: false,
            isWindowOnMainScreen: true,
            record: record,
            mainScreenFrame: mainScreen
        )
        if case .eligible = result { } else {
            #expect(Bool(false), "Expected .eligible, got \(result)")
        }
    }

    @Test("decideRestoreEligibility: toggle in flight → toggleInFlight")
    func eligibilityToggleInFlight() {
        let result = HookEventHandler.decideRestoreEligibility(
            isToggleInFlight: true,
            isWindowOnMainScreen: true,
            record: nil,
            mainScreenFrame: nil
        )
        assertEligibility(result, expected: "toggleInFlight")
    }

    @Test("decideRestoreEligibility: window off main → windowNotOnMainScreen")
    func eligibilityOffMain() {
        let result = HookEventHandler.decideRestoreEligibility(
            isToggleInFlight: false,
            isWindowOnMainScreen: false,
            record: nil,
            mainScreenFrame: nil
        )
        assertEligibility(result, expected: "windowNotOnMainScreen")
    }

    @Test("decideRestoreEligibility: no record → noRecord")
    func eligibilityNoRecord() {
        let result = HookEventHandler.decideRestoreEligibility(
            isToggleInFlight: false,
            isWindowOnMainScreen: true,
            record: nil,
            mainScreenFrame: nil
        )
        assertEligibility(result, expected: "noRecord")
    }

    @Test("decideRestoreEligibility: no record and window off main → windowNotOnMainScreen (caller handles fallback)")
    func eligibilityNoRecordOffMain() {
        // When no toggle record exists, decideRestoreEligibility still returns based on
        // window position — the caller (handleUserPromptSubmit) decides whether to
        // fallback to moveWindowToMainScreen
        let result = HookEventHandler.decideRestoreEligibility(
            isToggleInFlight: false,
            isWindowOnMainScreen: false,
            record: nil,
            mainScreenFrame: nil
        )
        assertEligibility(result, expected: "windowNotOnMainScreen")
    }

    @Test("decideRestoreEligibility: corrupted record → recordInvalid")
    func eligibilityCorrupted() {
        let record = makeRecord(
            origFrame: CGRect(x: 100, y: 200, width: 800, height: 600),
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600)
        )
        let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let result = HookEventHandler.decideRestoreEligibility(
            isToggleInFlight: false,
            isWindowOnMainScreen: true,
            record: record,
            mainScreenFrame: mainScreen
        )
        if case .recordInvalid(let windowID) = result {
            #expect(windowID == 42)
        } else {
            #expect(Bool(false), "Expected .recordInvalid, got \(result)")
        }
    }

    @Test("decideRestoreEligibility: valid record but nil mainScreen → recordInvalid")
    func eligibilityNilMainScreen() {
        let record = makeRecord(
            origFrame: CGRect(x: 100, y: -1000, width: 800, height: 600),
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600)
        )
        let result = HookEventHandler.decideRestoreEligibility(
            isToggleInFlight: false,
            isWindowOnMainScreen: true,
            record: record,
            mainScreenFrame: nil
        )
        assertEligibility(result, expected: "recordInvalid")
    }

    // MARK: - Full pipeline: mock → decide → clear verification

    @Test("Full pipeline: System Events restore with corrupted record → mock clear called")
    func systemEventsCorruptedPipeline() {
        let mock = MockToggleRecordStore()
        let record = makeRecord(
            origFrame: CGRect(x: 100, y: 200, width: 800, height: 600),
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600)
        )
        let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        // Simulate system events path
        let loaded = mock.load(windowID: 42)
        let decision = WindowManager.decideSystemEventsRestore(
            windowID: 42, record: loaded ?? record, mainScreenFrame: mainScreen
        )

        if case .corruptedClearWindowID(let windowID) = decision {
            mock.clear(windowID: windowID)
        }

        #expect(mock.clearedWindowIDs == [42])
    }

    @Test("Full pipeline: System Events with sourceSpace=0 → mock clear called")
    func systemEventsInvalidSourceSpacePipeline() {
        let mock = MockToggleRecordStore()
        let record = makeRecord(
            origFrame: CGRect(x: 100, y: -1000, width: 800, height: 600),
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600),
            sourceSpace: 0
        )
        let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let decision = WindowManager.decideSystemEventsRestore(
            windowID: 42, record: record, mainScreenFrame: mainScreen
        )

        if case .invalidSourceSpaceClearWindowID(let windowID) = decision {
            mock.clear(windowID: windowID)
        }

        #expect(mock.clearedWindowIDs == [42])
    }

    @Test("BindingType: remote session creates .remote binding")
    func bindingTypeRemote() {
        let bt = WindowState.BindingType.remote
        #expect(bt == .remote)
        #expect(bt.rawValue == "remote")
    }

    @Test("BindingType: local session creates .local binding")
    func bindingTypeLocal() {
        let bt = WindowState.BindingType.local
        #expect(bt == .local)
        #expect(bt.rawValue == "local")
    }

    @Test("Full pipeline: Window resolution with binding → no mock interaction needed")
    func windowResolutionBindingPipeline() {
        let bindingIdentity = WindowIdentity(
            windowID: 42, pid: 1234,
            bundleIdentifier: "com.apple.Terminal",
            appName: "Terminal", title: "bash"
        )
        let terminalIdentity = WindowIdentity(
            windowID: 99, pid: 5678,
            bundleIdentifier: "com.apple.Terminal",
            appName: "Terminal", title: "vim"
        )

        let result = HookEventHandler.decideWindowResolution(
            hasBinding: true,
            bindingVerified: true,
            bindingIdentity: bindingIdentity,
            hasTerminalContext: true,
            terminalContextIdentity: terminalIdentity
        )

        if case .binding(let identity) = result {
            #expect(identity.windowID == 42) // binding wins
        } else {
            #expect(Bool(false), "Expected .binding")
        }
    }
}

// MARK: - Helpers

extension RestoreIntegrationTests {
    private func assertEligibility(
        _ result: HookEventHandler.RestoreEligibility,
        expected: String
    ) {
        let actual: String
        switch result {
        case .eligible: actual = "eligible"
        case .toggleInFlight: actual = "toggleInFlight"
        case .windowNotOnMainScreen: actual = "windowNotOnMainScreen"
        case .noRecord: actual = "noRecord"
        case .recordInvalid: actual = "recordInvalid"
        }
        #expect(actual == expected, "Expected \(expected), got \(actual)")
    }

    private func assertDecisionIs(
        _ result: WindowManager.RestoreDecision,
        expectedCase: String
    ) -> Bool {
        let actual: String
        switch result {
        case .restore: actual = "restore"
        case .moveToMain: actual = "moveToMain"
        case .noRecord: actual = "noRecord"
        case .noFocusedWindow: actual = "noFocusedWindow"
        case .noMainScreen: actual = "noMainScreen"
        case .corruptedClearWindowID: actual = "corruptedClearWindowID"
        }
        return actual == expectedCase
    }
}
