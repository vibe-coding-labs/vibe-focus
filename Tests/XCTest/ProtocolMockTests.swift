import Testing
import Foundation
import CoreGraphics
@testable import VibeFocusKit

// MARK: - Mock ToggleRecordStore

/// Mock implementation of ToggleRecordStore for testing.
/// Records all load/clear calls for verification.
final class MockToggleRecordStore: ToggleRecordStore, @unchecked Sendable {
    var recordByWindowID: [UInt32: ToggleRecord] = [:]
    var recordByPID: [Int32: ToggleRecord] = [:]
    var clearedWindowIDs: [UInt32] = []

    // Call tracking
    var loadCalls: [UInt32] = []
    var loadByPIDCalls: [Int32] = []
    var clearCalls: [UInt32] = []

    func load(windowID: UInt32) -> ToggleRecord? {
        loadCalls.append(windowID)
        return recordByWindowID[windowID]
    }

    func loadByPID(pid: Int32) -> ToggleRecord? {
        loadByPIDCalls.append(pid)
        return recordByPID[pid]
    }

    func clear(windowID: UInt32) {
        clearCalls.append(windowID)
        clearedWindowIDs.append(windowID)
        recordByWindowID.removeValue(forKey: windowID)
    }
}

@Suite("Mock ToggleRecordStore")
@MainActor
struct MockToggleRecordStoreTests {

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

    @Test("MockToggleRecordStore: load returns stored record")
    func mockLoadByWindowID() {
        let mock = MockToggleRecordStore()
        let record = makeRecord(
            origFrame: CGRect(x: 100, y: -1000, width: 800, height: 600),
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600)
        )
        mock.recordByWindowID[42] = record
        #expect(mock.load(windowID: 42)?.windowID == 42)
        #expect(mock.load(windowID: 99) == nil)
    }

    @Test("MockToggleRecordStore: loadByPID returns stored record")
    func mockLoadByPID() {
        let mock = MockToggleRecordStore()
        let record = makeRecord(
            origFrame: CGRect(x: 100, y: -1000, width: 800, height: 600),
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600)
        )
        mock.recordByPID[1234] = record
        #expect(mock.loadByPID(pid: 1234)?.pid == 1234)
        #expect(mock.loadByPID(pid: 9999) == nil)
    }

    @Test("MockToggleRecordStore: clear records windowID")
    func mockClear() {
        let mock = MockToggleRecordStore()
        mock.clear(windowID: 42)
        mock.clear(windowID: 99)
        #expect(mock.clearedWindowIDs == [42, 99])
    }

    @Test("MockToggleRecordStore: clear removes from recordByWindowID")
    func mockClearRemoves() {
        let mock = MockToggleRecordStore()
        let record = makeRecord(
            origFrame: CGRect(x: 100, y: -1000, width: 800, height: 600),
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600)
        )
        mock.recordByWindowID[42] = record
        mock.clear(windowID: 42)
        #expect(mock.load(windowID: 42) == nil)
    }

    @Test("ToggleEngine conforms to ToggleRecordStore")
    func toggleEngineConformance() {
        // Compile-time check: ToggleEngine.shared is a ToggleRecordStore
        let _: any ToggleRecordStore = ToggleEngine.shared
        #expect(Bool(true))
    }
}
