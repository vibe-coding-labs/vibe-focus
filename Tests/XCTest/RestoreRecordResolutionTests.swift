import Testing
import Foundation
import CoreGraphics
@testable import VibeFocusKit

@Suite("Restore Record Resolution")
@MainActor
struct RestoreRecordResolutionTests {

    private func makeRecord(windowID: UInt32 = 42) -> ToggleRecord {
        ToggleRecord(
            windowID: windowID, pid: 1234,
            bundleIdentifier: "com.test", appName: "App",
            origFrame: CGRect(x: 100, y: -1000, width: 800, height: 600),
            sourceSpace: 3, sourceDisplay: 2,
            sourceYabaiDisp: 2, sourceDispSpace: 1,
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600),
            targetDisplay: 1, toggledAt: Date(), sessionID: "s1"
        )
    }

    @Test("resolveRestoreRecord: found by windowID")
    func foundByWindowID() {
        let record = makeRecord(windowID: 42)
        let result = ToggleEngine.resolveRestoreRecord(
            windowID: 42,
            loadByWindowID: { _ in record }
        )
        #expect(result?.windowID == 42)
    }

    @Test("resolveRestoreRecord: windowID miss → nil")
    func windowIDMiss() {
        let result = ToggleEngine.resolveRestoreRecord(
            windowID: 42,
            loadByWindowID: { _ in nil }
        )
        #expect(result == nil)
    }

}
