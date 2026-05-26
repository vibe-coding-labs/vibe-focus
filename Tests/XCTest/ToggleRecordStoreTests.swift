import Testing
import Foundation
@testable import VibeFocusKit

@Suite("ToggleRecord Store (In-Memory SQLite)")
@MainActor
struct ToggleRecordStoreTests {

    private func makeStore() -> WindowStateStore {
        WindowStateStore(dbPath: ":memory:")
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRecord(
        windowID: UInt32 = 42,
        pid: Int32 = 1234,
        origFrame: CGRect = CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        sourceSpace: Int = 2,
        sourceDisplay: Int = 2,
        sourceYabaiDisp: Int = 2,
        sourceDispSpace: Int = 1,
        targetFrame: CGRect = CGRect(x: 0, y: 0, width: 1920, height: 1080),
        targetDisplay: Int = 1,
        sessionID: String? = nil
    ) -> ToggleRecord {
        ToggleRecord(
            windowID: windowID,
            pid: pid,
            bundleIdentifier: "com.test",
            appName: "TestApp",
            origFrame: origFrame,
            sourceSpace: sourceSpace,
            sourceDisplay: sourceDisplay,
            sourceYabaiDisp: sourceYabaiDisp,
            sourceDispSpace: sourceDispSpace,
            targetFrame: targetFrame,
            targetDisplay: targetDisplay,
            toggledAt: fixedDate,
            sessionID: sessionID
        )
    }

    // MARK: - save + load roundtrip

    @Test("saveToggleRecord then loadToggleRecord returns matching record")
    func saveAndLoadByWindowID() {
        let store = makeStore()
        let record = makeRecord()
        store.saveToggleRecord(record)

        let loaded = store.loadToggleRecord(windowID: 42)
        #expect(loaded != nil)
        #expect(loaded!.windowID == 42)
        #expect(loaded!.pid == 1234)
        #expect(loaded!.sourceSpace == 2)
        #expect(loaded!.sourceDisplay == 2)
        #expect(loaded!.sourceYabaiDisp == 2)
        #expect(loaded!.sourceDispSpace == 1)
        #expect(loaded!.targetDisplay == 1)
        #expect(loaded!.bundleIdentifier == "com.test")
        #expect(loaded!.appName == "TestApp")
    }

    @Test("saveToggleRecord preserves frame coordinates")
    func frameCoordinates() {
        let store = makeStore()
        let record = makeRecord(
            origFrame: CGRect(x: -3840, y: 100, width: 800, height: 600),
            targetFrame: CGRect(x: 500, y: 200, width: 900, height: 700)
        )
        store.saveToggleRecord(record)

        let loaded = store.loadToggleRecord(windowID: 42)
        #expect(loaded != nil)
        #expect(loaded!.origFrame.origin.x == -3840)
        #expect(loaded!.origFrame.origin.y == 100)
        #expect(loaded!.origFrame.width == 800)
        #expect(loaded!.origFrame.height == 600)
        #expect(loaded!.targetFrame.origin.x == 500)
        #expect(loaded!.targetFrame.origin.y == 200)
        #expect(loaded!.targetFrame.width == 900)
        #expect(loaded!.targetFrame.height == 700)
    }

    @Test("saveToggleRecord preserves sessionID on INSERT path")
    func sessionIDPreservedOnInsert() {
        let store = makeStore()
        let record = makeRecord(sessionID: "sess-abc-123")
        store.saveToggleRecord(record)

        let loaded = store.loadToggleRecord(windowID: 42)
        #expect(loaded?.sessionID == "sess-abc-123")
    }

    @Test("saveToggleRecord preserves sessionID on UPDATE path")
    func sessionIDPreservedOnUpdate() {
        let store = makeStore()
        let record1 = makeRecord(sessionID: nil)
        store.saveToggleRecord(record1)

        let record2 = makeRecord(sessionID: "sess-abc-123")
        store.saveToggleRecord(record2)

        let loaded = store.loadToggleRecord(windowID: 42)
        #expect(loaded?.sessionID == "sess-abc-123")
    }

    @Test("saveToggleRecord with nil sessionID")
    func nilSessionID() {
        let store = makeStore()
        let record = makeRecord(sessionID: nil)
        store.saveToggleRecord(record)

        let loaded = store.loadToggleRecord(windowID: 42)
        #expect(loaded?.sessionID == nil)
    }

    // MARK: - load by PID fallback

    @Test("loadToggleRecordByPID finds record when windowID lookup fails")
    func loadByPID() {
        let store = makeStore()
        let record = makeRecord(windowID: 99, pid: 5678)
        store.saveToggleRecord(record)

        let loaded = store.loadToggleRecordByPID(pid: 5678)
        #expect(loaded != nil)
        #expect(loaded!.windowID == 99)
        #expect(loaded!.pid == 5678)
    }

    @Test("loadToggleRecordByPID returns most recent when multiple records exist")
    func loadByPIDMostRecent() {
        let store = makeStore()
        let record1 = makeRecord(windowID: 10, pid: 100)
        store.saveToggleRecord(record1)

        // Second record with same PID but later timestamp
        let record2 = ToggleRecord(
            windowID: 20, pid: 100,
            bundleIdentifier: nil, appName: nil,
            origFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            sourceSpace: 1, sourceDisplay: 1, sourceYabaiDisp: 1, sourceDispSpace: 1,
            targetFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            targetDisplay: 1,
            toggledAt: fixedDate.addingTimeInterval(60),
            sessionID: nil
        )
        store.saveToggleRecord(record2)

        let loaded = store.loadToggleRecordByPID(pid: 100)
        #expect(loaded?.windowID == 20)
    }

    // MARK: - load non-existent

    @Test("loadToggleRecord returns nil for non-existent windowID")
    func loadNonExistent() {
        let store = makeStore()
        #expect(store.loadToggleRecord(windowID: 9999) == nil)
    }

    @Test("loadToggleRecordByPID returns nil for non-existent PID")
    func loadByPIDNonExistent() {
        let store = makeStore()
        #expect(store.loadToggleRecordByPID(pid: 9999) == nil)
    }

    // MARK: - clear

    @Test("clearToggleRecord removes toggle state")
    func clearRemovesRecord() {
        let store = makeStore()
        let record = makeRecord()
        store.saveToggleRecord(record)
        #expect(store.loadToggleRecord(windowID: 42) != nil)

        store.clearToggleRecord(windowID: 42)
        #expect(store.loadToggleRecord(windowID: 42) == nil)
    }

    @Test("clearToggleRecord on non-existent windowID does not crash")
    func clearNonExistent() {
        let store = makeStore()
        store.clearToggleRecord(windowID: 9999)
    }

    // MARK: - update existing

    @Test("saveToggleRecord updates existing record")
    func updateExisting() {
        let store = makeStore()
        let record1 = makeRecord(sourceSpace: 2)
        store.saveToggleRecord(record1)

        let record2 = makeRecord(sourceSpace: 5)
        store.saveToggleRecord(record2)

        let loaded = store.loadToggleRecord(windowID: 42)
        #expect(loaded?.sourceSpace == 5)
    }

    // MARK: - multiple records

    @Test("multiple records can coexist")
    func multipleRecords() {
        let store = makeStore()
        store.saveToggleRecord(makeRecord(windowID: 1, pid: 100))
        store.saveToggleRecord(makeRecord(windowID: 2, pid: 200))
        store.saveToggleRecord(makeRecord(windowID: 3, pid: 300))

        #expect(store.loadToggleRecord(windowID: 1)?.pid == 100)
        #expect(store.loadToggleRecord(windowID: 2)?.pid == 200)
        #expect(store.loadToggleRecord(windowID: 3)?.pid == 300)
        #expect(store.loadToggleRecord(windowID: 4) == nil)
    }

    // MARK: - clear preserves identity fields

    @Test("clearToggleRecord preserves pid and window_id")
    func clearPreservesIdentity() {
        let store = makeStore()
        let record = makeRecord(windowID: 42, pid: 1234)
        store.saveToggleRecord(record)

        store.clearToggleRecord(windowID: 42)

        // Toggle record should be nil (requires orig_x IS NOT NULL)
        #expect(store.loadToggleRecord(windowID: 42) == nil)

        // But window state row should still exist (findWindowState returns it)
        let state = store.findWindowState(windowID: 42)
        #expect(state != nil)
        #expect(state?.pid == 1234)
    }

    @Test("clearToggleRecord preserves sessionID from toggle record")
    func clearPreservesSessionID() {
        let store = makeStore()
        // Save window state with sessionID first
        let state = WindowState(
            windowID: 42, pid: 1234, tty: nil,
            axWindowNumber: nil, appName: "App", bundleIdentifier: "com.app",
            title: nil, termSessionID: nil, itermSessionID: nil,
            kittyWindowID: nil, weztermPane: nil, envWindowID: nil,
            sessionID: "sess-keep", cwd: nil, model: nil,
            origX: nil, origY: nil, origW: nil, origH: nil,
            targetX: nil, targetY: nil, targetW: nil, targetH: nil,
            sourceSpace: nil, sourceDisplay: nil,
            sourceYabaiDisp: nil, sourceDispSpace: nil,
            targetDisplay: nil, toggleReason: nil, toggledAt: nil,
            isCompleted: false, completedAt: nil,
            createdAt: fixedDate, updatedAt: fixedDate
        )
        store.saveWindowState(state)

        // Now save toggle record — UPDATE overwrites session_id to "sess-toggle"
        let record = makeRecord(windowID: 42, pid: 1234, sessionID: "sess-toggle")
        store.saveToggleRecord(record)
        #expect(store.loadToggleRecord(windowID: 42)?.sessionID == "sess-toggle")

        // Clear toggle — clears frame/space fields but NOT session_id
        store.clearToggleRecord(windowID: 42)
        #expect(store.loadToggleRecord(windowID: 42) == nil)

        // session_id survives the clear
        let restored = store.findWindowState(windowID: 42)
        #expect(restored?.sessionID == "sess-toggle")
    }

    // MARK: - nil bundleIdentifier and appName

    @Test("saveToggleRecord INSERT with nil bundleIdentifier and appName stores empty strings")
    func nilBundleAndAppName() {
        let store = makeStore()
        let record = ToggleRecord(
            windowID: 99, pid: 5678,
            bundleIdentifier: nil, appName: nil,
            origFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            sourceSpace: 1, sourceDisplay: 1, sourceYabaiDisp: 1, sourceDispSpace: 1,
            targetFrame: CGRect(x: 100, y: 100, width: 200, height: 200),
            targetDisplay: 1,
            toggledAt: fixedDate, sessionID: nil
        )
        store.saveToggleRecord(record)

        let loaded = store.loadToggleRecord(windowID: 99)
        #expect(loaded != nil)
        // INSERT binds nil optionals as "" — parseToggleRecord reads them back as ""
        #expect(loaded?.bundleIdentifier == "")
        #expect(loaded?.appName == "")
        #expect(loaded?.pid == 5678)
    }

    // MARK: - same PID different windowIDs for PID lookup

    @Test("loadByPID with multiple records returns most recent by toggledAt")
    func loadByPIMostRecentTimestamp() {
        let store = makeStore()

        let older = ToggleRecord(
            windowID: 10, pid: 500,
            bundleIdentifier: "com.a", appName: "A",
            origFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            sourceSpace: 1, sourceDisplay: 1, sourceYabaiDisp: 1, sourceDispSpace: 1,
            targetFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            targetDisplay: 1,
            toggledAt: fixedDate.addingTimeInterval(-3600),
            sessionID: nil
        )
        store.saveToggleRecord(older)

        let newer = ToggleRecord(
            windowID: 20, pid: 500,
            bundleIdentifier: "com.b", appName: "B",
            origFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            sourceSpace: 2, sourceDisplay: 2, sourceYabaiDisp: 2, sourceDispSpace: 2,
            targetFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            targetDisplay: 2,
            toggledAt: fixedDate.addingTimeInterval(3600),
            sessionID: nil
        )
        store.saveToggleRecord(newer)

        let loaded = store.loadToggleRecordByPID(pid: 500)
        #expect(loaded?.windowID == 20)
        #expect(loaded?.bundleIdentifier == "com.b")
    }

    // MARK: - zero values

    @Test("saveToggleRecord with zero frame coordinates")
    func zeroFrameCoordinates() {
        let store = makeStore()
        let record = ToggleRecord(
            windowID: 1, pid: 1,
            bundleIdentifier: nil, appName: nil,
            origFrame: CGRect(x: 0, y: 0, width: 0, height: 0),
            sourceSpace: 0, sourceDisplay: 0, sourceYabaiDisp: 0, sourceDispSpace: 0,
            targetFrame: CGRect(x: 0, y: 0, width: 0, height: 0),
            targetDisplay: 0,
            toggledAt: fixedDate, sessionID: nil
        )
        store.saveToggleRecord(record)

        // Note: loadToggleRecord requires orig_x IS NOT NULL, and 0 is NOT NULL
        let loaded = store.loadToggleRecord(windowID: 1)
        #expect(loaded != nil)
        #expect(loaded?.origFrame == CGRect.zero)
    }

    // MARK: - negative frame coordinates

    @Test("saveToggleRecord with negative frame coordinates")
    func negativeFrameCoordinates() {
        let store = makeStore()
        let record = makeRecord(
            origFrame: CGRect(x: -3840, y: -2160, width: 1920, height: 1080),
            targetFrame: CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
        )
        store.saveToggleRecord(record)

        let loaded = store.loadToggleRecord(windowID: 42)
        #expect(loaded?.origFrame.origin.x == -3840)
        #expect(loaded?.origFrame.origin.y == -2160)
        #expect(loaded?.targetFrame.origin.x == -1920)
        #expect(loaded?.targetFrame.origin.y == -1080)
    }
}
