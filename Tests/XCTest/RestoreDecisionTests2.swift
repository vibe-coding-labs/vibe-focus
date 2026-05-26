import Testing
import Foundation
@testable import VibeFocusKit

@Suite("Restore Decision Logic")
@MainActor
struct RestoreDecisionTests2 {

    private let mainScreenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    private func makeRecord(
        windowID: UInt32 = 42,
        origFrame: CGRect = CGRect(x: -3840, y: 0, width: 1920, height: 1080),
        targetFrame: CGRect = CGRect(x: 0, y: 0, width: 1920, height: 1080),
        sourceSpace: Int = 2
    ) -> ToggleRecord {
        ToggleRecord(
            windowID: windowID,
            pid: 1234,
            bundleIdentifier: nil,
            appName: nil,
            origFrame: origFrame,
            sourceSpace: sourceSpace,
            sourceDisplay: 2,
            sourceYabaiDisp: 2,
            sourceDispSpace: 1,
            targetFrame: targetFrame,
            targetDisplay: 1,
            toggledAt: Date(),
            sessionID: nil
        )
    }

    // MARK: - decideRestore

    @Test("decideRestore: focused not on main → moveToMain")
    func moveToMain() {
        let result = WindowManager.decideRestore(
            focusedOnMain: false,
            recordByWindowID: nil,
            mainScreenFrame: mainScreenFrame
        )
        if case .moveToMain = result {} else {
            #expect(Bool(false), "Expected .moveToMain, got \(result)")
        }
    }

    @Test("decideRestore: nil focused → noFocusedWindow")
    func noFocusedWindow() {
        let result = WindowManager.decideRestore(
            focusedOnMain: nil,
            recordByWindowID: nil,
            mainScreenFrame: mainScreenFrame
        )
        if case .noFocusedWindow = result {} else {
            #expect(Bool(false), "Expected .noFocusedWindow, got \(result)")
        }
    }

    @Test("decideRestore: on main, no records → noRecord")
    func noRecord() {
        let result = WindowManager.decideRestore(
            focusedOnMain: true,
            recordByWindowID: nil,
            mainScreenFrame: mainScreenFrame
        )
        if case .noRecord = result {} else {
            #expect(Bool(false), "Expected .noRecord, got \(result)")
        }
    }

    @Test("decideRestore: on main, valid record by windowID → restore with correct data")
    func restoreByWindowID() {
        let record = makeRecord(windowID: 77, sourceSpace: 5)
        let result = WindowManager.decideRestore(
            focusedOnMain: true,
            recordByWindowID: record,
            mainScreenFrame: mainScreenFrame
        )
        if case .restore = result {
            // .restore is a simple case with no associated data —
            // but we verified the decision path is correct
        } else {
            #expect(Bool(false), "Expected .restore, got \(result)")
        }
    }

    @Test("decideRestore: corruptedClearWindowID returns the correct windowID")
    func corruptedReturnsCorrectID() {
        let record = makeRecord(
            windowID: 99,
            origFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
            targetFrame: CGRect(x: 200, y: 200, width: 800, height: 600)
        )
        let result = WindowManager.decideRestore(
            focusedOnMain: true,
            recordByWindowID: record,
            mainScreenFrame: mainScreenFrame
        )
        if case .corruptedClearWindowID(let id) = result {
            #expect(id == 99)
        } else {
            #expect(Bool(false), "Expected .corruptedClearWindowID(99), got \(result)")
        }
    }

    @Test("decideRestore: nil mainScreenFrame → noMainScreen")
    func noMainScreen() {
        let record = makeRecord()
        let result = WindowManager.decideRestore(
            focusedOnMain: true,
            recordByWindowID: record,
            mainScreenFrame: nil
        )
        if case .noMainScreen = result {} else {
            #expect(Bool(false), "Expected .noMainScreen, got \(result)")
        }
    }

}
