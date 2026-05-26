import Testing
import Foundation
@testable import VibeFocusKit

@Suite("WindowState Store (In-Memory SQLite)")
@MainActor
struct WindowStateStoreTests {

    private func makeStore() -> WindowStateStore {
        WindowStateStore(dbPath: ":memory:")
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeState(
        windowID: UInt32 = 42,
        pid: Int32 = 1234,
        sessionID: String? = "sess-1",
        isCompleted: Bool = false,
        origX: CGFloat? = nil,
        targetX: CGFloat? = nil,
        title: String? = "bash"
    ) -> WindowState {
        WindowState(
            windowID: windowID, pid: pid, tty: "/dev/ttys001",
            axWindowNumber: 100, appName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            title: title,
            termSessionID: nil, itermSessionID: nil,
            kittyWindowID: nil, weztermPane: nil, envWindowID: nil,
            sessionID: sessionID, cwd: "/project", model: "opus",
            origX: origX, origY: origX != nil ? 0 : nil, origW: origX != nil ? 800 : nil, origH: origX != nil ? 600 : nil,
            targetX: targetX, targetY: targetX != nil ? 0 : nil, targetW: targetX != nil ? 800 : nil, targetH: targetX != nil ? 600 : nil,
            sourceSpace: nil, sourceDisplay: nil,
            sourceYabaiDisp: nil, sourceDispSpace: nil,
            targetDisplay: nil, toggleReason: nil, toggledAt: nil,
            isCompleted: isCompleted, completedAt: nil,
            createdAt: fixedDate, updatedAt: fixedDate
        )
    }

    // MARK: - save + find by windowID

    @Test("saveWindowState then findWindowState returns matching state")
    func saveAndFindByWindowID() {
        let store = makeStore()
        let state = makeState()
        store.saveWindowState(state)

        let found = store.findWindowState(windowID: 42)
        #expect(found != nil)
        #expect(found!.windowID == 42)
        #expect(found!.pid == 1234)
        #expect(found!.sessionID == "sess-1")
        #expect(found!.cwd == "/project")
        #expect(found!.model == "opus")
        #expect(found!.appName == "Terminal")
        #expect(found!.bundleIdentifier == "com.apple.Terminal")
    }

    @Test("findWindowState returns nil for non-existent windowID")
    func findNonExistent() {
        let store = makeStore()
        #expect(store.findWindowState(windowID: 9999) == nil)
    }

    // MARK: - find by sessionID

    @Test("findWindowStateBySession returns matching state")
    func findBySession() {
        let store = makeStore()
        store.saveWindowState(makeState(windowID: 10, sessionID: "sess-abc"))
        store.saveWindowState(makeState(windowID: 20, sessionID: "sess-xyz"))

        let found = store.findWindowStateBySession(sessionID: "sess-abc")
        #expect(found?.windowID == 10)
    }

    @Test("findWindowStateBySession returns nil for non-existent session")
    func findSessionNonExistent() {
        let store = makeStore()
        #expect(store.findWindowStateBySession(sessionID: "nope") == nil)
    }

    // MARK: - upsert behavior

    @Test("saveWindowState upserts on conflict")
    func upsertOnConflict() {
        let store = makeStore()
        store.saveWindowState(makeState(windowID: 42, title: "original"))
        store.saveWindowState(makeState(windowID: 42, title: "updated"))

        let found = store.findWindowState(windowID: 42)
        #expect(found?.title == "updated")
    }

    // MARK: - delete

    @Test("deleteWindowState removes record")
    func deleteState() {
        let store = makeStore()
        store.saveWindowState(makeState(windowID: 42))
        #expect(store.findWindowState(windowID: 42) != nil)

        store.deleteWindowState(windowID: 42)
        #expect(store.findWindowState(windowID: 42) == nil)
    }

    @Test("deleteWindowState on non-existent does not crash")
    func deleteNonExistent() {
        let store = makeStore()
        store.deleteWindowState(windowID: 9999)
    }

    // MARK: - count

    @Test("windowStatesCount returns correct count")
    func count() {
        let store = makeStore()
        #expect(store.windowStatesCount == 0)

        store.saveWindowState(makeState(windowID: 1))
        #expect(store.windowStatesCount == 1)

        store.saveWindowState(makeState(windowID: 2))
        store.saveWindowState(makeState(windowID: 3))
        #expect(store.windowStatesCount == 3)
    }

    @Test("windowStatesCount after delete is correct")
    func countAfterDelete() {
        let store = makeStore()
        store.saveWindowState(makeState(windowID: 1))
        store.saveWindowState(makeState(windowID: 2))
        store.deleteWindowState(windowID: 1)
        #expect(store.windowStatesCount == 1)
    }

    // MARK: - loadAll

    @Test("loadAllWindowStates returns all records")
    func loadAll() {
        let store = makeStore()
        store.saveWindowState(makeState(windowID: 1))
        store.saveWindowState(makeState(windowID: 2))

        let all = store.loadAllWindowStates()
        #expect(all.count == 2)
        let ids = Set(all.map(\.windowID))
        #expect(ids == [1, 2])
    }

    @Test("loadAllWindowStates returns empty for empty store")
    func loadAllEmpty() {
        let store = makeStore()
        #expect(store.loadAllWindowStates().isEmpty)
    }

    // MARK: - deleteAllWindowsStates

    @Test("deleteAllWindowsStates clears all records")
    func deleteAll() {
        let store = makeStore()
        store.saveWindowState(makeState(windowID: 1))
        store.saveWindowState(makeState(windowID: 2))
        #expect(store.windowStatesCount == 2)

        store.deleteAllWindowsStates()
        #expect(store.windowStatesCount == 0)
    }

    // MARK: - prune expired

    @Test("pruneExpiredWindowStates removes old active records")
    func pruneOldActive() {
        let store = makeStore()
        // Create a record with old updatedAt
        let oldState = WindowState(
            windowID: 1, pid: 100, tty: nil,
            axWindowNumber: nil, appName: nil, bundleIdentifier: nil,
            title: nil, termSessionID: nil, itermSessionID: nil,
            kittyWindowID: nil, weztermPane: nil, envWindowID: nil,
            sessionID: nil, cwd: nil, model: nil,
            origX: nil, origY: nil, origW: nil, origH: nil,
            targetX: nil, targetY: nil, targetW: nil, targetH: nil,
            sourceSpace: nil, sourceDisplay: nil,
            sourceYabaiDisp: nil, sourceDispSpace: nil,
            targetDisplay: nil, toggleReason: nil, toggledAt: nil,
            isCompleted: false, completedAt: nil,
            createdAt: Date().addingTimeInterval(-7200), // 2 hours ago
            updatedAt: Date().addingTimeInterval(-7200)  // 2 hours ago
        )
        store.saveWindowState(oldState)

        // Create a recent record
        let recentState = WindowState(
            windowID: 2, pid: 200, tty: nil,
            axWindowNumber: nil, appName: nil, bundleIdentifier: nil,
            title: nil, termSessionID: nil, itermSessionID: nil,
            kittyWindowID: nil, weztermPane: nil, envWindowID: nil,
            sessionID: nil, cwd: nil, model: nil,
            origX: nil, origY: nil, origW: nil, origH: nil,
            targetX: nil, targetY: nil, targetW: nil, targetH: nil,
            sourceSpace: nil, sourceDisplay: nil,
            sourceYabaiDisp: nil, sourceDispSpace: nil,
            targetDisplay: nil, toggleReason: nil, toggledAt: nil,
            isCompleted: false, completedAt: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        store.saveWindowState(recentState)

        #expect(store.windowStatesCount == 2)

        // Prune records older than 1 hour
        let pruned = store.pruneExpiredWindowStates(activeRetention: 3600, completedRetention: 3600)
        #expect(pruned == 1)
        #expect(store.windowStatesCount == 1)
        #expect(store.findWindowState(windowID: 2) != nil) // recent survives
    }

    // MARK: - toggle state in window state

    @Test("saveWindowState preserves toggle frame data")
    func toggleFrameData() {
        let store = makeStore()
        let state = makeState(
            windowID: 42,
            origX: -1920,
            targetX: 500
        )
        store.saveWindowState(state)

        let found = store.findWindowState(windowID: 42)
        #expect(found?.origX == -1920)
        #expect(found?.origY == 0)
        #expect(found?.origW == 800)
        #expect(found?.origH == 600)
        #expect(found?.targetX == 500)
        #expect(found?.targetY == 0)
    }

    @Test("hasToggleState is true after save with toggle data")
    func hasToggleStateAfterSave() {
        let store = makeStore()
        let state = makeState(windowID: 42, origX: 100, targetX: 500)
        store.saveWindowState(state)

        let found = store.findWindowState(windowID: 42)
        #expect(found?.hasToggleState == true)
    }

    // MARK: - full field roundtrip

    @Test("saveWindowState full roundtrip preserves all fields")
    func fullFieldRoundtrip() {
        let store = makeStore()
        let state = WindowState(
            windowID: 99, pid: 5678, tty: "/dev/ttys002",
            axWindowNumber: 200, appName: "iTerm2",
            bundleIdentifier: "com.googlecode.iterm2",
            title: "vim main.swift",
            termSessionID: "term-sess-1", itermSessionID: "iterm-sess-1",
            kittyWindowID: nil, weztermPane: nil, envWindowID: nil,
            sessionID: "sess-full", cwd: "/Users/dev/project", model: "claude-4",
            origX: -1920, origY: 100, origW: 800, origH: 600,
            targetX: 500, targetY: 300, targetW: 900, targetH: 700,
            sourceSpace: 3, sourceDisplay: 2,
            sourceYabaiDisp: 2, sourceDispSpace: 2,
            targetDisplay: 1, toggleReason: "manual_hotkey",
            toggledAt: fixedDate,
            isCompleted: true, completedAt: fixedDate.addingTimeInterval(60),
            createdAt: fixedDate, updatedAt: fixedDate
        )
        store.saveWindowState(state)

        let found = store.findWindowState(windowID: 99)
        #expect(found != nil)
        #expect(found!.windowID == 99)
        #expect(found!.pid == 5678)
        #expect(found!.tty == "/dev/ttys002")
        #expect(found!.axWindowNumber == 200)
        #expect(found!.appName == "iTerm2")
        #expect(found!.bundleIdentifier == "com.googlecode.iterm2")
        #expect(found!.title == "vim main.swift")
        #expect(found!.termSessionID == "term-sess-1")
        #expect(found!.itermSessionID == "iterm-sess-1")
        #expect(found!.sessionID == "sess-full")
        #expect(found!.cwd == "/Users/dev/project")
        #expect(found!.model == "claude-4")
        #expect(found!.origX == -1920)
        #expect(found!.origY == 100)
        #expect(found!.origW == 800)
        #expect(found!.origH == 600)
        #expect(found!.targetX == 500)
        #expect(found!.targetY == 300)
        #expect(found!.targetW == 900)
        #expect(found!.targetH == 700)
        #expect(found!.sourceSpace == 3)
        #expect(found!.sourceDisplay == 2)
        #expect(found!.sourceYabaiDisp == 2)
        #expect(found!.sourceDispSpace == 2)
        #expect(found!.targetDisplay == 1)
        #expect(found!.toggleReason == "manual_hotkey")
        #expect(found!.isCompleted == true)
    }

    // MARK: - isCorrupted detection via stored state

    @Test("isCorrupted detects both frames on main screen after roundtrip")
    func isCorruptedAfterRoundtrip() {
        let store = makeStore()
        let state = WindowState(
            windowID: 50, pid: 100, tty: nil,
            axWindowNumber: nil, appName: "App", bundleIdentifier: "com.app",
            title: "Test",
            termSessionID: nil, itermSessionID: nil,
            kittyWindowID: nil, weztermPane: nil, envWindowID: nil,
            sessionID: "s1", cwd: nil, model: nil,
            origX: 100, origY: 200, origW: 800, origH: 600,
            targetX: 500, targetY: 300, targetW: 800, targetH: 600,
            sourceSpace: nil, sourceDisplay: nil,
            sourceYabaiDisp: nil, sourceDispSpace: nil,
            targetDisplay: nil, toggleReason: nil, toggledAt: nil,
            isCompleted: false, completedAt: nil,
            createdAt: fixedDate, updatedAt: fixedDate
        )
        store.saveWindowState(state)

        let found = store.findWindowState(windowID: 50)
        #expect(found != nil)
        let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(found!.isCorrupted(mainScreenFrame: mainScreen))
    }

    // MARK: - toggle record + window state interaction

    @Test("toggle record and window state coexist for same windowID")
    func toggleRecordPlusWindowState() {
        let store = makeStore()

        // Save window state first
        let state = WindowState(
            windowID: 42, pid: 1234, tty: nil,
            axWindowNumber: nil, appName: "App", bundleIdentifier: "com.app",
            title: "Test",
            termSessionID: nil, itermSessionID: nil,
            kittyWindowID: nil, weztermPane: nil, envWindowID: nil,
            sessionID: "s1", cwd: nil, model: nil,
            origX: nil, origY: nil, origW: nil, origH: nil,
            targetX: nil, targetY: nil, targetW: nil, targetH: nil,
            sourceSpace: nil, sourceDisplay: nil,
            sourceYabaiDisp: nil, sourceDispSpace: nil,
            targetDisplay: nil, toggleReason: nil, toggledAt: nil,
            isCompleted: false, completedAt: nil,
            createdAt: fixedDate, updatedAt: fixedDate
        )
        store.saveWindowState(state)

        // Save toggle record for same windowID — should UPDATE existing row
        let record = ToggleRecord(
            windowID: 42, pid: 1234,
            bundleIdentifier: "com.app", appName: "App",
            origFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            sourceSpace: 2, sourceDisplay: 2,
            sourceYabaiDisp: 2, sourceDispSpace: 1,
            targetFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            targetDisplay: 1,
            toggledAt: fixedDate, sessionID: nil
        )
        store.saveToggleRecord(record)

        let loadedRecord = store.loadToggleRecord(windowID: 42)
        #expect(loadedRecord != nil)
        #expect(loadedRecord!.sourceSpace == 2)

        let loadedState = store.findWindowState(windowID: 42)
        #expect(loadedState != nil)
        // Toggle record UPDATE overwrites session_id with its own (nil here)
        #expect(loadedState!.sessionID == nil)
    }

    // MARK: - prune completed vs active

    @Test("pruneExpiredWindowStates uses different retention for completed")
    func pruneCompletedSeparately() {
        let store = makeStore()

        // Active record, old
        let activeOld = WindowState(
            windowID: 1, pid: 100, tty: nil,
            axWindowNumber: nil, appName: nil, bundleIdentifier: nil,
            title: nil, termSessionID: nil, itermSessionID: nil,
            kittyWindowID: nil, weztermPane: nil, envWindowID: nil,
            sessionID: nil, cwd: nil, model: nil,
            origX: nil, origY: nil, origW: nil, origH: nil,
            targetX: nil, targetY: nil, targetW: nil, targetH: nil,
            sourceSpace: nil, sourceDisplay: nil,
            sourceYabaiDisp: nil, sourceDispSpace: nil,
            targetDisplay: nil, toggleReason: nil, toggledAt: nil,
            isCompleted: false, completedAt: nil,
            createdAt: Date().addingTimeInterval(-7200),
            updatedAt: Date().addingTimeInterval(-7200)
        )
        store.saveWindowState(activeOld)

        // Completed record, old but within completed retention
        let completedOld = WindowState(
            windowID: 2, pid: 200, tty: nil,
            axWindowNumber: nil, appName: nil, bundleIdentifier: nil,
            title: nil, termSessionID: nil, itermSessionID: nil,
            kittyWindowID: nil, weztermPane: nil, envWindowID: nil,
            sessionID: nil, cwd: nil, model: nil,
            origX: nil, origY: nil, origW: nil, origH: nil,
            targetX: nil, targetY: nil, targetW: nil, targetH: nil,
            sourceSpace: nil, sourceDisplay: nil,
            sourceYabaiDisp: nil, sourceDispSpace: nil,
            targetDisplay: nil, toggleReason: nil, toggledAt: nil,
            isCompleted: true, completedAt: nil,
            createdAt: Date().addingTimeInterval(-7200),
            updatedAt: Date().addingTimeInterval(-7200)
        )
        store.saveWindowState(completedOld)

        // Prune with active=1h, completed=24h
        let pruned = store.pruneExpiredWindowStates(activeRetention: 3600, completedRetention: 86400)
        #expect(pruned == 1)
        #expect(store.windowStatesCount == 1)
        #expect(store.findWindowState(windowID: 2) != nil) // completed survives
    }

    // MARK: - nil optional text fields

    @Test("saveWindowState preserves nil optional text fields")
    func nilOptionalTextFields() {
        let store = makeStore()
        let state = WindowState(
            windowID: 55, pid: 100, tty: nil,
            axWindowNumber: nil, appName: nil, bundleIdentifier: nil,
            title: nil, termSessionID: nil, itermSessionID: nil,
            kittyWindowID: nil, weztermPane: nil, envWindowID: nil,
            sessionID: nil, cwd: nil, model: nil,
            origX: nil, origY: nil, origW: nil, origH: nil,
            targetX: nil, targetY: nil, targetW: nil, targetH: nil,
            sourceSpace: nil, sourceDisplay: nil,
            sourceYabaiDisp: nil, sourceDispSpace: nil,
            targetDisplay: nil, toggleReason: nil, toggledAt: nil,
            isCompleted: false, completedAt: nil,
            createdAt: fixedDate, updatedAt: fixedDate
        )
        store.saveWindowState(state)

        let found = store.findWindowState(windowID: 55)
        #expect(found != nil)
        #expect(found?.tty == nil)
        #expect(found?.appName == nil)
        #expect(found?.bundleIdentifier == nil)
        #expect(found?.title == nil)
        #expect(found?.sessionID == nil)
        #expect(found?.cwd == nil)
        #expect(found?.model == nil)
        #expect(found?.toggleReason == nil)
    }

    // MARK: - completedAt field

    @Test("saveWindowState preserves completedAt timestamp")
    func completedAtTimestamp() {
        let store = makeStore()
        let completedAt = fixedDate.addingTimeInterval(120)
        let state = WindowState(
            windowID: 66, pid: 200, tty: nil,
            axWindowNumber: nil, appName: nil, bundleIdentifier: nil,
            title: nil, termSessionID: nil, itermSessionID: nil,
            kittyWindowID: nil, weztermPane: nil, envWindowID: nil,
            sessionID: nil, cwd: nil, model: nil,
            origX: nil, origY: nil, origW: nil, origH: nil,
            targetX: nil, targetY: nil, targetW: nil, targetH: nil,
            sourceSpace: nil, sourceDisplay: nil,
            sourceYabaiDisp: nil, sourceDispSpace: nil,
            targetDisplay: nil, toggleReason: nil, toggledAt: nil,
            isCompleted: true, completedAt: completedAt,
            createdAt: fixedDate, updatedAt: fixedDate
        )
        store.saveWindowState(state)

        let found = store.findWindowState(windowID: 66)
        #expect(found?.isCompleted == true)
        #expect(found?.completedAt != nil)
    }

    // MARK: - findWindowStateByWindowID

    @Test("findWindowStateByWindowID returns correct state")
    func findByWindowIDMethod() {
        let store = makeStore()
        store.saveWindowState(makeState(windowID: 77))

        let found = store.findWindowStateByWindowID(77)
        #expect(found?.windowID == 77)
    }

    @Test("findWindowStateByWindowID returns nil for non-existent")
    func findByWindowIDNonExistent() {
        let store = makeStore()
        #expect(store.findWindowStateByWindowID(9999) == nil)
    }

    // MARK: - prune with no records

    @Test("pruneExpiredWindowStates on empty store returns 0")
    func pruneEmpty() {
        let store = makeStore()
        let pruned = store.pruneExpiredWindowStates(activeRetention: 3600, completedRetention: 3600)
        #expect(pruned == 0)
    }

    // MARK: - prune with recent records only

    @Test("pruneExpiredWindowStates with recent records returns 0")
    func pruneRecentOnly() {
        let store = makeStore()
        // Use current date so records are not expired
        let now = Date()
        let state1 = WindowState(
            windowID: 1, pid: 100, tty: nil,
            axWindowNumber: nil, appName: nil, bundleIdentifier: nil,
            title: nil, termSessionID: nil, itermSessionID: nil,
            kittyWindowID: nil, weztermPane: nil, envWindowID: nil,
            sessionID: nil, cwd: nil, model: nil,
            origX: nil, origY: nil, origW: nil, origH: nil,
            targetX: nil, targetY: nil, targetW: nil, targetH: nil,
            sourceSpace: nil, sourceDisplay: nil,
            sourceYabaiDisp: nil, sourceDispSpace: nil,
            targetDisplay: nil, toggleReason: nil, toggledAt: nil,
            isCompleted: false, completedAt: nil,
            createdAt: now, updatedAt: now
        )
        let state2 = WindowState(
            windowID: 2, pid: 200, tty: nil,
            axWindowNumber: nil, appName: nil, bundleIdentifier: nil,
            title: nil, termSessionID: nil, itermSessionID: nil,
            kittyWindowID: nil, weztermPane: nil, envWindowID: nil,
            sessionID: nil, cwd: nil, model: nil,
            origX: nil, origY: nil, origW: nil, origH: nil,
            targetX: nil, targetY: nil, targetW: nil, targetH: nil,
            sourceSpace: nil, sourceDisplay: nil,
            sourceYabaiDisp: nil, sourceDispSpace: nil,
            targetDisplay: nil, toggleReason: nil, toggledAt: nil,
            isCompleted: false, completedAt: nil,
            createdAt: now, updatedAt: now
        )
        store.saveWindowState(state1)
        store.saveWindowState(state2)

        let pruned = store.pruneExpiredWindowStates(activeRetention: 3600, completedRetention: 3600)
        #expect(pruned == 0)
        #expect(store.windowStatesCount == 2)
    }

    // MARK: - terminal session IDs

    @Test("saveWindowState preserves terminal-specific session IDs")
    func terminalSessionIDs() {
        let store = makeStore()
        let state = WindowState(
            windowID: 88, pid: 300, tty: "/dev/ttys003",
            axWindowNumber: 50, appName: "iTerm2", bundleIdentifier: "com.googlecode.iterm2",
            title: "zsh",
            termSessionID: "term-sess-abc", itermSessionID: "iterm-sess-xyz",
            kittyWindowID: "kitty-1", weztermPane: "wez-1", envWindowID: "env-1",
            sessionID: "sess-88", cwd: "/home", model: "sonnet",
            origX: nil, origY: nil, origW: nil, origH: nil,
            targetX: nil, targetY: nil, targetW: nil, targetH: nil,
            sourceSpace: nil, sourceDisplay: nil,
            sourceYabaiDisp: nil, sourceDispSpace: nil,
            targetDisplay: nil, toggleReason: nil, toggledAt: nil,
            isCompleted: false, completedAt: nil,
            createdAt: fixedDate, updatedAt: fixedDate
        )
        store.saveWindowState(state)

        let found = store.findWindowState(windowID: 88)
        #expect(found?.termSessionID == "term-sess-abc")
        #expect(found?.itermSessionID == "iterm-sess-xyz")
        #expect(found?.kittyWindowID == "kitty-1")
        #expect(found?.weztermPane == "wez-1")
        #expect(found?.envWindowID == "env-1")
    }
}
