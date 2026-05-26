import Testing
import Foundation
import CoreGraphics
@testable import VibeFocusKit

@Suite("Restore Decision Logic")
@MainActor
struct RestoreDecisionTests {

    let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    private func assertRestoreDecision(
        _ result: WindowManager.RestoreDecision,
        is expected: WindowManager.RestoreDecision
    ) {
        switch (result, expected) {
        case (.restore, .restore): return
        case (.moveToMain, .moveToMain): return
        case (.noRecord, .noRecord): return
        case (.noFocusedWindow, .noFocusedWindow): return
        case (.noMainScreen, .noMainScreen): return
        case (.corruptedClearWindowID(let a), .corruptedClearWindowID(let b)):
            #expect(a == b, "corruptedClearWindowID mismatch: \(a) != \(b)")
        default:
            #expect(Bool(false), "Expected \(expected), got \(result)")
        }
    }

    func makeRecord(origFrame: CGRect, targetFrame: CGRect) -> ToggleRecord {
        ToggleRecord(
            windowID: 42, pid: 1234, bundleIdentifier: "com.test", appName: "App",
            origFrame: origFrame,
            sourceSpace: 3, sourceDisplay: 2,
            sourceYabaiDisp: 2, sourceDispSpace: 1,
            targetFrame: targetFrame,
            targetDisplay: 1, toggledAt: Date(), sessionID: "s1"
        )
    }

    // MARK: - No focused window

    @Test("decideRestore: nil focusedOnMain → noFocusedWindow")
    func noFocusedWindow() {
        let result = WindowManager.decideRestore(
            focusedOnMain: nil,
            recordByWindowID: nil,
            mainScreenFrame: mainScreen
        )
        assertRestoreDecision(result, is: .noFocusedWindow)
    }

    // MARK: - Move to main

    @Test("decideRestore: focused on secondary → moveToMain")
    func moveToMain() {
        let result = WindowManager.decideRestore(
            focusedOnMain: false,
            recordByWindowID: nil,
            mainScreenFrame: mainScreen
        )
        assertRestoreDecision(result, is: .moveToMain)
    }

    @Test("decideRestore: focused on secondary even with valid record → moveToMain")
    func moveToMainIgnoresRecord() {
        let record = makeRecord(
            origFrame: CGRect(x: 100, y: -1000, width: 800, height: 600),
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600)
        )
        let result = WindowManager.decideRestore(
            focusedOnMain: false,
            recordByWindowID: record,
            mainScreenFrame: mainScreen
        )
        assertRestoreDecision(result, is: .moveToMain)
    }

    // MARK: - No record

    @Test("decideRestore: on main, no record → noRecord")
    func noRecord() {
        let result = WindowManager.decideRestore(
            focusedOnMain: true,
            recordByWindowID: nil,
            mainScreenFrame: mainScreen
        )
        assertRestoreDecision(result, is: .noRecord)
    }

    // MARK: - Record by windowID

    @Test("decideRestore: on main, valid record by windowID → restore")
    func restoreByWindowID() {
        let record = makeRecord(
            origFrame: CGRect(x: 100, y: -1000, width: 800, height: 600),
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600)
        )
        let result = WindowManager.decideRestore(
            focusedOnMain: true,
            recordByWindowID: record,
            mainScreenFrame: mainScreen
        )
        assertRestoreDecision(result, is: .restore)
    }

    // MARK: - Corrupted record

    @Test("decideRestore: corrupted record (both frames on main) → corruptedClearWindowID")
    func corruptedRecord() {
        let record = makeRecord(
            origFrame: CGRect(x: 100, y: 200, width: 800, height: 600),
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600)
        )
        let result = WindowManager.decideRestore(
            focusedOnMain: true,
            recordByWindowID: record,
            mainScreenFrame: mainScreen
        )
        assertRestoreDecision(result, is: .corruptedClearWindowID(42))
    }

    // MARK: - No main screen

    @Test("decideRestore: valid record but nil mainScreen → noMainScreen")
    func noMainScreen() {
        let record = makeRecord(
            origFrame: CGRect(x: 100, y: -1000, width: 800, height: 600),
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600)
        )
        let result = WindowManager.decideRestore(
            focusedOnMain: true,
            recordByWindowID: record,
            mainScreenFrame: nil
        )
        assertRestoreDecision(result, is: .noMainScreen)
    }

    // MARK: - Full decision tree priority

    @Test("decideRestore: decision priority — noFocusedWindow > moveToMain > noRecord > restore")
    func decisionPriority() {
        let r1 = WindowManager.decideRestore(focusedOnMain: nil, recordByWindowID: nil, mainScreenFrame: mainScreen)
        assertRestoreDecision(r1, is: .noFocusedWindow)

        let r2 = WindowManager.decideRestore(focusedOnMain: false, recordByWindowID: nil, mainScreenFrame: mainScreen)
        assertRestoreDecision(r2, is: .moveToMain)

        let r3 = WindowManager.decideRestore(focusedOnMain: true, recordByWindowID: nil, mainScreenFrame: mainScreen)
        assertRestoreDecision(r3, is: .noRecord)

        let validRecord = makeRecord(
            origFrame: CGRect(x: 100, y: -1000, width: 800, height: 600),
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600)
        )
        let r4 = WindowManager.decideRestore(focusedOnMain: true, recordByWindowID: validRecord, mainScreenFrame: mainScreen)
        assertRestoreDecision(r4, is: .restore)
    }
}
