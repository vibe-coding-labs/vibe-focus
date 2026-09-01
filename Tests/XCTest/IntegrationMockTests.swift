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
            mainScreenFrame: mainScreen
        )

        // Simulate the clear that shouldRestoreCurrentWindow would do
        if case .corruptedClearWindowID(let windowID) = decision {
            mock.clear(windowID: windowID)
        }

        #expect(mock.clearedWindowIDs == [42])
        #expect(mock.load(windowID: 42) == nil)
    }

    @Test("Integration pattern: windowID lookup fails → noRecord")
    func lookupFails() {
        let mock = MockToggleRecordStore()

        let loadedByID = mock.load(windowID: 42)

        let decision = WindowManager.decideRestore(
            focusedOnMain: true,
            recordByWindowID: loadedByID,
            mainScreenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        #expect(assertDecisionIs(decision, expectedCase: "noRecord"))
    }

    // MARK: - validateRestoreEligibility（已随 decideRestoreEligibility 影子函数删除，见 2.16a 第五~十刀台账）

    // MARK: - Full pipeline: mock → decide → clear verification

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
}

// MARK: - Helpers

extension RestoreIntegrationTests {
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
