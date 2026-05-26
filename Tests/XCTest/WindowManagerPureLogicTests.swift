import Testing
import Foundation
import CoreGraphics
@testable import VibeFocusKit

@Suite("WindowManager Pure Logic")
@MainActor
struct WindowManagerPureLogicTests {

    // MARK: - WindowManager.framesMatch (instance method, single tolerance for all dimensions)

    @Test("WindowManager.framesMatch: identical frames match")
    func framesMatchIdentical() {
        let wm = WindowManager.shared
        let frame = CGRect(x: 100, y: 200, width: 800, height: 600)
        #expect(wm.framesMatch(frame, frame))
    }

    @Test("WindowManager.framesMatch: within tolerance")
    func framesMatchWithinTolerance() {
        let wm = WindowManager.shared
        let a = CGRect(x: 100, y: 200, width: 800, height: 600)
        let b = CGRect(x: 105, y: 195, width: 808, height: 592)
        #expect(wm.framesMatch(a, b))
    }

    @Test("WindowManager.framesMatch: position exceeds tolerance")
    func framesMatchPositionExceeds() {
        let wm = WindowManager.shared
        let a = CGRect(x: 100, y: 200, width: 800, height: 600)
        let b = CGRect(x: 115, y: 200, width: 800, height: 600)
        #expect(!wm.framesMatch(a, b))
    }

    @Test("WindowManager.framesMatch: size exceeds tolerance")
    func framesMatchSizeExceeds() {
        let wm = WindowManager.shared
        let a = CGRect(x: 0, y: 0, width: 800, height: 600)
        let b = CGRect(x: 0, y: 0, width: 815, height: 600)
        // tolerance is 10, delta is 15 → exceeds
        #expect(!wm.framesMatch(a, b))
    }

    // MARK: - ScriptWindowSnapshot.frame computed property

    @Test("ScriptWindowSnapshot.frame computes CGRect correctly")
    func snapshotFrame() {
        let snapshot = WindowManager.ScriptWindowSnapshot(
            windowID: 42,
            appName: "Terminal",
            title: "bash",
            x: 100,
            y: -500,
            width: 800,
            height: 600
        )
        #expect(snapshot.frame.origin.x == 100)
        #expect(snapshot.frame.origin.y == -500)
        #expect(snapshot.frame.width == 800)
        #expect(snapshot.frame.height == 600)
    }

    @Test("ScriptWindowSnapshot.frame with zero origin")
    func snapshotFrameZero() {
        let snapshot = WindowManager.ScriptWindowSnapshot(
            windowID: nil,
            appName: "Safari",
            title: nil,
            x: 0,
            y: 0,
            width: 1920,
            height: 1080
        )
        #expect(snapshot.frame == CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    @Test("ScriptWindowSnapshot Codable roundtrip")
    func snapshotCodable() throws {
        let snapshot = WindowManager.ScriptWindowSnapshot(
            windowID: 99,
            appName: "iTerm2",
            title: "vim",
            x: 50.5,
            y: 100.25,
            width: 640,
            height: 480
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WindowManager.ScriptWindowSnapshot.self, from: data)
        #expect(decoded.windowID == 99)
        #expect(decoded.appName == "iTerm2")
        #expect(decoded.title == "vim")
        #expect(decoded.x == 50.5)
        #expect(decoded.y == 100.25)
        #expect(decoded.width == 640)
        #expect(decoded.height == 480)
    }

    // MARK: - frameTolerance constant

    @Test("WindowManager.frameTolerance is 10")
    func frameToleranceValue() {
        let wm = WindowManager.shared
        #expect(wm.frameTolerance == 10)
    }
}
