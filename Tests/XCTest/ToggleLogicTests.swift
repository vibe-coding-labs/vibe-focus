import Testing
import Foundation
import CoreGraphics
@testable import VibeFocusKit

@Suite("Toggle Validation Logic")
@MainActor
struct ToggleLogicTests {

    // MARK: - WindowState.isCorrupted

    @Test("WindowState.isCorrupted: both frames on main screen → corrupted")
    func isCorruptedBothOnMain() {
        var state = WindowState(
            windowID: 1, pid: 100, tty: nil, axWindowNumber: 1,
            appName: "App", bundleIdentifier: "com.app", title: "Test",
            termSessionID: nil, itermSessionID: nil,
            sessionID: "s1", isCompleted: false,
            createdAt: Date(), updatedAt: Date()
        )
        // Both frames centered on main screen (0,0 1920x1080)
        state.origX = 100; state.origY = 100; state.origW = 800; state.origH = 600
        state.targetX = 500; state.targetY = 300; state.targetW = 800; state.targetH = 600

        let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(state.isCorrupted(mainScreenFrame: mainScreen))
    }

    @Test("WindowState.isCorrupted: orig off-screen → not corrupted")
    func isCorruptedOrigOffScreen() {
        var state = WindowState(
            windowID: 1, pid: 100, tty: nil, axWindowNumber: 1,
            appName: "App", bundleIdentifier: "com.app", title: "Test",
            termSessionID: nil, itermSessionID: nil,
            sessionID: "s1", isCompleted: false,
            createdAt: Date(), updatedAt: Date()
        )
        // orig above screen, target on screen
        state.origX = 100; state.origY = -1000; state.origW = 800; state.origH = 600
        state.targetX = 500; state.targetY = 300; state.targetW = 800; state.targetH = 600

        let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(!state.isCorrupted(mainScreenFrame: mainScreen))
    }

    @Test("WindowState.isCorrupted: nil frames → not corrupted")
    func isCorruptedNilFrames() {
        let state = WindowState(
            windowID: 1, pid: 100, tty: nil, axWindowNumber: 1,
            appName: "App", bundleIdentifier: "com.app", title: "Test",
            termSessionID: nil, itermSessionID: nil,
            sessionID: "s1", isCompleted: false,
            createdAt: Date(), updatedAt: Date()
        )
        let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(!state.isCorrupted(mainScreenFrame: mainScreen))
    }

    // MARK: - WindowState.hasToggleState

    @Test("WindowState.hasToggleState: both present → true")
    func hasToggleStateTrue() {
        var state = WindowState(
            windowID: 1, pid: 100, tty: nil, axWindowNumber: 1,
            appName: "App", bundleIdentifier: "com.app", title: "Test",
            termSessionID: nil, itermSessionID: nil,
            sessionID: "s1", isCompleted: false,
            createdAt: Date(), updatedAt: Date()
        )
        state.origX = 100
        state.targetX = 500
        #expect(state.hasToggleState)
    }

    @Test("WindowState.hasToggleState: only origX → false")
    func hasToggleStateOnlyOrig() {
        var state = WindowState(
            windowID: 1, pid: 100, tty: nil, axWindowNumber: 1,
            appName: "App", bundleIdentifier: "com.app", title: "Test",
            termSessionID: nil, itermSessionID: nil,
            sessionID: "s1", isCompleted: false,
            createdAt: Date(), updatedAt: Date()
        )
        state.origX = 100
        #expect(!state.hasToggleState)
    }

    @Test("WindowState.hasToggleState: nil → false")
    func hasToggleStateNil() {
        let state = WindowState(
            windowID: 1, pid: 100, tty: nil, axWindowNumber: 1,
            appName: "App", bundleIdentifier: "com.app", title: "Test",
            termSessionID: nil, itermSessionID: nil,
            sessionID: "s1", isCompleted: false,
            createdAt: Date(), updatedAt: Date()
        )
        #expect(!state.hasToggleState)
    }

    // MARK: - WindowState frame computed properties

    @Test("WindowState.originalFrame: all fields present")
    func originalFrameAllPresent() {
        var state = WindowState(
            windowID: 1, pid: 100, tty: nil, axWindowNumber: 1,
            appName: "App", bundleIdentifier: "com.app", title: "Test",
            termSessionID: nil, itermSessionID: nil,
            sessionID: "s1", isCompleted: false,
            createdAt: Date(), updatedAt: Date()
        )
        state.origX = 100; state.origY = -500; state.origW = 800; state.origH = 600
        let frame = state.originalFrame
        #expect(frame != nil)
        #expect(frame!.origin.x == 100)
        #expect(frame!.origin.y == -500)
        #expect(frame!.width == 800)
        #expect(frame!.height == 600)
    }

    @Test("WindowState.originalFrame: partial fields → nil")
    func originalFramePartial() {
        var state = WindowState(
            windowID: 1, pid: 100, tty: nil, axWindowNumber: 1,
            appName: "App", bundleIdentifier: "com.app", title: "Test",
            termSessionID: nil, itermSessionID: nil,
            sessionID: "s1", isCompleted: false,
            createdAt: Date(), updatedAt: Date()
        )
        state.origX = 100; state.origY = 200; state.origW = 800 // missing origH
        #expect(state.originalFrame == nil)
    }

    @Test("WindowState.targetFrame: all fields present")
    func targetFrameAllPresent() {
        var state = WindowState(
            windowID: 1, pid: 100, tty: nil, axWindowNumber: 1,
            appName: "App", bundleIdentifier: "com.app", title: "Test",
            termSessionID: nil, itermSessionID: nil,
            sessionID: "s1", isCompleted: false,
            createdAt: Date(), updatedAt: Date()
        )
        state.targetX = 500; state.targetY = 300; state.targetW = 800; state.targetH = 600
        let frame = state.targetFrame
        #expect(frame != nil)
        #expect(frame!.origin.x == 500)
        #expect(frame!.width == 800)
    }

    // MARK: - ToggleRecord.isValid

    @Test("ToggleRecord.isValid: orig off-screen, target on-screen → valid")
    func toggleRecordValid() {
        let record = ToggleRecord(
            windowID: 42, pid: 1234, bundleIdentifier: "com.test", appName: "App",
            origFrame: CGRect(x: 100, y: -1000, width: 800, height: 600),
            sourceSpace: 3, sourceDisplay: 2,
            sourceYabaiDisp: 2, sourceDispSpace: 1,
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600),
            targetDisplay: 1, toggledAt: Date(), sessionID: "s1"
        )
        let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(record.isValid(mainScreenFrame: mainScreen))
    }

    @Test("ToggleRecord.isValid: both on main screen → invalid")
    func toggleRecordBothOnMain() {
        let record = ToggleRecord(
            windowID: 42, pid: 1234, bundleIdentifier: "com.test", appName: "App",
            origFrame: CGRect(x: 100, y: 500, width: 800, height: 600),
            sourceSpace: 3, sourceDisplay: 1,
            sourceYabaiDisp: 1, sourceDispSpace: 1,
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600),
            targetDisplay: 1, toggledAt: Date(), sessionID: "s1"
        )
        let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // Both centers are on main screen → not valid (orig should be off-screen)
        #expect(!record.isValid(mainScreenFrame: mainScreen))
    }

    @Test("ToggleRecord.isValid: orig on main, target off → invalid")
    func toggleRecordOrigOnTargetOff() {
        let record = ToggleRecord(
            windowID: 42, pid: 1234, bundleIdentifier: "com.test", appName: "App",
            origFrame: CGRect(x: 100, y: 200, width: 800, height: 600),
            sourceSpace: 1, sourceDisplay: 1,
            sourceYabaiDisp: 1, sourceDispSpace: 1,
            targetFrame: CGRect(x: 100, y: -1000, width: 800, height: 600),
            targetDisplay: 1, toggledAt: Date(), sessionID: "s1"
        )
        let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(!record.isValid(mainScreenFrame: mainScreen))
    }

    @Test("ToggleRecord.isValid: orig just off-screen left")
    func toggleRecordOrigJustOffLeft() {
        // origFrame center at (-150, 300) → Cocoa (-150, 780) → outside mainScreen
        // targetFrame center at (900, 600) → Cocoa (900, 480) → inside mainScreen
        let record = ToggleRecord(
            windowID: 42, pid: 1234, bundleIdentifier: "com.test", appName: "App",
            origFrame: CGRect(x: -200, y: 0, width: 100, height: 600),
            sourceSpace: 2, sourceDisplay: 2,
            sourceYabaiDisp: 2, sourceDispSpace: 1,
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600),
            targetDisplay: 1, toggledAt: Date(), sessionID: "s1"
        )
        let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(record.isValid(mainScreenFrame: mainScreen))
    }

    @Test("ToggleRecord.isValid: zero-size orig frame center on screen → invalid")
    func toggleRecordZeroSizeOrig() {
        // origFrame center at (500, 500) → Cocoa (500, 580) → inside mainScreen
        // targetFrame center at (900, 600) → Cocoa (900, 480) → inside mainScreen
        // Both inside → NOT valid
        let record = ToggleRecord(
            windowID: 42, pid: 1234, bundleIdentifier: "com.test", appName: "App",
            origFrame: CGRect(x: 500, y: 500, width: 0, height: 0),
            sourceSpace: 1, sourceDisplay: 1,
            sourceYabaiDisp: 1, sourceDispSpace: 1,
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600),
            targetDisplay: 1, toggledAt: Date(), sessionID: "s1"
        )
        let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(!record.isValid(mainScreenFrame: mainScreen))
    }

    @Test("ToggleRecord.isValid: orig off-screen above (negative y)")
    func toggleRecordOrigOffScreenAbove() {
        // Secondary screen above main: orig center at (500, -500) → Cocoa (500, 1580) → outside
        // target center at (900, 600) → Cocoa (900, 480) → inside
        let record = ToggleRecord(
            windowID: 42, pid: 1234, bundleIdentifier: "com.test", appName: "App",
            origFrame: CGRect(x: 100, y: -800, width: 800, height: 600),
            sourceSpace: 2, sourceDisplay: 2,
            sourceYabaiDisp: 2, sourceDispSpace: 1,
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600),
            targetDisplay: 1, toggledAt: Date(), sessionID: "s1"
        )
        let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(record.isValid(mainScreenFrame: mainScreen))
    }
}
