import Testing
import Foundation
@testable import VibeFocusKit

@Suite("WindowState Store Edge Cases")
@MainActor
struct WindowStoreEdgeCaseTests {

    private func makeStore() -> WindowStateStore {
        WindowStateStore(dbPath: ":memory:")
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeState(
        windowID: UInt32,
        pid: Int32 = 100,
        sessionID: String? = nil,
        tty: String? = nil,
        isCompleted: Bool = false,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> WindowState {
        WindowState(
            windowID: windowID, pid: pid, tty: tty,
            axWindowNumber: nil, appName: nil, bundleIdentifier: nil,
            title: nil, termSessionID: nil, itermSessionID: nil,
            kittyWindowID: nil, weztermPane: nil, envWindowID: nil,
            sessionID: sessionID, cwd: nil, model: nil,
            origX: nil, origY: nil, origW: nil, origH: nil,
            targetX: nil, targetY: nil, targetW: nil, targetH: nil,
            sourceSpace: nil, sourceDisplay: nil,
            sourceYabaiDisp: nil, sourceDispSpace: nil,
            targetDisplay: nil, toggleReason: nil, toggledAt: nil,
            isCompleted: isCompleted, completedAt: nil,
            createdAt: createdAt, updatedAt: updatedAt
        )
    }

    // MARK: - findWindowStateBySession

    @Test("findWindowStateBySession returns most recently updated")
    func findBySessionMostRecent() {
        let store = makeStore()
        let later = fixedDate.addingTimeInterval(60)
        store.saveWindowState(makeState(windowID: 1, sessionID: "sess-1", updatedAt: fixedDate))
        store.saveWindowState(makeState(windowID: 2, sessionID: "sess-1", updatedAt: later))

        let found = store.findWindowStateBySession(sessionID: "sess-1")
        #expect(found?.windowID == 2)
    }

    @Test("findWindowStateBySession returns nil for non-existent session")
    func findBySessionNonExistent() {
        let store = makeStore()
        #expect(store.findWindowStateBySession(sessionID: "nope") == nil)
    }

    @Test("findWindowStateBySession with empty store")
    func findBySessionEmpty() {
        let store = makeStore()
        #expect(store.findWindowStateBySession(sessionID: "anything") == nil)
    }

    // MARK: - upsert preserves fields

    @Test("upsert does not duplicate rows")
    func upsertNoDuplicate() {
        let store = makeStore()
        store.saveWindowState(makeState(windowID: 42, sessionID: "s1"))
        store.saveWindowState(makeState(windowID: 42, sessionID: "s2"))

        #expect(store.windowStatesCount == 1)
        let found = store.findWindowState(windowID: 42)
        #expect(found?.sessionID == "s2")
    }

    @Test("upsert does NOT overwrite toggle fields (toggle fields managed by saveToggleRecord)")
    func upsertPreservesToggleFields() {
        let store = makeStore()
        var state1 = makeState(windowID: 42)
        state1.origX = -1920
        state1.targetX = 500
        store.saveWindowState(state1)

        // Second saveWindowState updates identity fields but NOT toggle fields
        var state2 = makeState(windowID: 42, sessionID: "sess-new")
        state2.origX = -3840
        state2.targetX = 100
        store.saveWindowState(state2)

        let found = store.findWindowState(windowID: 42)
        // saveWindowState UPSERT excludes orig_x/target_x from the UPDATE clause
        // But the INSERT includes them — this is a conflict: INSERT provides them,
        // then ON CONFLICT DO UPDATE only updates specific columns, NOT toggle fields
        // Actually the INSERT...ON CONFLICT will INSERT the first time (with toggle fields)
        // and UPDATE the second time (which does NOT update toggle fields per the SQL)
        // So the toggle fields from the first INSERT survive
        #expect(found?.origX == -1920)
        #expect(found?.targetX == 500)
        #expect(found?.sessionID == "sess-new")
    }

    // MARK: - delete non-existent

    @Test("deleteWindowState on non-existent does not affect count")
    func deleteNonExistentCount() {
        let store = makeStore()
        store.saveWindowState(makeState(windowID: 1))
        store.deleteWindowState(windowID: 999)
        #expect(store.windowStatesCount == 1)
    }

    // MARK: - prune edge cases

    @Test("prune with only completed old records removes them")
    func pruneCompletedOnlyOld() {
        let store = makeStore()
        let old = Date().addingTimeInterval(-7200)
        store.saveWindowState(makeState(windowID: 1, isCompleted: true, createdAt: old, updatedAt: old))

        let pruned = store.pruneExpiredWindowStates(activeRetention: 3600, completedRetention: 3600)
        #expect(pruned == 1)
        #expect(store.windowStatesCount == 0)
    }

    @Test("prune with both old and new completed records")
    func pruneCompletedMix() {
        let store = makeStore()
        let old = Date().addingTimeInterval(-7200)
        let now = Date()

        store.saveWindowState(makeState(windowID: 1, isCompleted: true, createdAt: old, updatedAt: old))
        store.saveWindowState(makeState(windowID: 2, isCompleted: true, createdAt: now, updatedAt: now))

        let pruned = store.pruneExpiredWindowStates(activeRetention: 3600, completedRetention: 3600)
        #expect(pruned == 1)
        #expect(store.windowStatesCount == 1)
        #expect(store.findWindowState(windowID: 2) != nil)
    }

    // MARK: - loadAll ordering

    @Test("loadAllWindowStates returns records ordered by updated_at ASC")
    func loadAllOrdering() {
        let store = makeStore()
        let t1 = fixedDate
        let t2 = fixedDate.addingTimeInterval(60)
        let t3 = fixedDate.addingTimeInterval(120)

        store.saveWindowState(makeState(windowID: 3, updatedAt: t3))
        store.saveWindowState(makeState(windowID: 1, updatedAt: t1))
        store.saveWindowState(makeState(windowID: 2, updatedAt: t2))

        let all = store.loadAllWindowStates()
        #expect(all.count == 3)
        #expect(all[0].windowID == 1)
        #expect(all[1].windowID == 2)
        #expect(all[2].windowID == 3)
    }

    // MARK: - deleteAllWindowsStates

    @Test("deleteAllWindowsStates on empty store does not crash")
    func deleteAllEmpty() {
        let store = makeStore()
        store.deleteAllWindowsStates()
        #expect(store.windowStatesCount == 0)
    }

    // MARK: - tty field

    @Test("saveWindowState preserves tty string")
    func ttyString() {
        let store = makeStore()
        store.saveWindowState(makeState(windowID: 42, tty: "/dev/ttys001"))

        let found = store.findWindowState(windowID: 42)
        #expect(found?.tty == "/dev/ttys001")
    }

    @Test("saveWindowState preserves nil tty")
    func ttyNil() {
        let store = makeStore()
        store.saveWindowState(makeState(windowID: 42, tty: nil))

        let found = store.findWindowState(windowID: 42)
        #expect(found?.tty == nil)
    }
}
