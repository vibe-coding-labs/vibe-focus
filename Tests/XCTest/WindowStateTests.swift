import Testing
import Foundation
import CoreGraphics
@testable import VibeFocusKit

@Suite("WindowState Properties")
struct WindowStateTests {

    private let fixedDate = Date(timeIntervalSince1970: 1700000000)

    private func makeState(
        origX: CGFloat? = nil, origY: CGFloat? = nil,
        origW: CGFloat? = nil, origH: CGFloat? = nil,
        targetX: CGFloat? = nil, targetY: CGFloat? = nil,
        targetW: CGFloat? = nil, targetH: CGFloat? = nil,
        isCompleted: Bool = false
    ) -> WindowState {
        WindowState(
            windowID: 42, pid: 1234, tty: nil,
            axWindowNumber: nil, appName: "App", bundleIdentifier: "com.test",
            title: "Test",
            termSessionID: nil, itermSessionID: nil,
            kittyWindowID: nil, weztermPane: nil, envWindowID: nil,
            sessionID: "s1", cwd: nil, model: nil,
            origX: origX, origY: origY, origW: origW, origH: origH,
            targetX: targetX, targetY: targetY, targetW: targetW, targetH: targetH,
            sourceSpace: nil, sourceDisplay: nil,
            sourceYabaiDisp: nil, sourceDispSpace: nil,
            targetDisplay: nil, toggleReason: nil, toggledAt: nil,
            isCompleted: isCompleted, completedAt: nil,
            createdAt: fixedDate, updatedAt: fixedDate
        )
    }

    // MARK: - hasToggleState

    @Test("hasToggleState: both origX and targetX present → true")
    func hasToggleStateBothPresent() {
        let state = makeState(origX: 100, targetX: 500)
        #expect(state.hasToggleState)
    }

    @Test("hasToggleState: only origX → false")
    func hasToggleStateOnlyOrigX() {
        let state = makeState(origX: 100)
        #expect(!state.hasToggleState)
    }

    @Test("hasToggleState: only targetX → false")
    func hasToggleStateOnlyTargetX() {
        let state = makeState(targetX: 500)
        #expect(!state.hasToggleState)
    }

    @Test("hasToggleState: neither → false")
    func hasToggleStateNeither() {
        let state = makeState()
        #expect(!state.hasToggleState)
    }

    // MARK: - originalFrame

    @Test("originalFrame: all fields present → valid CGRect")
    func originalFrameAllPresent() {
        let state = makeState(origX: 100, origY: -1000, origW: 800, origH: 600)
        let frame = state.originalFrame
        #expect(frame != nil)
        #expect(frame!.origin.x == 100)
        #expect(frame!.origin.y == -1000)
        #expect(frame!.width == 800)
        #expect(frame!.height == 600)
    }

    @Test("originalFrame: missing origY → nil")
    func originalFrameMissingY() {
        let state = makeState(origX: 100, origW: 800, origH: 600)
        #expect(state.originalFrame == nil)
    }

    @Test("originalFrame: all nil → nil")
    func originalFrameAllNil() {
        let state = makeState()
        #expect(state.originalFrame == nil)
    }

    // MARK: - targetFrame

    @Test("targetFrame: all fields present → valid CGRect")
    func targetFrameAllPresent() {
        let state = makeState(targetX: 500, targetY: 300, targetW: 800, targetH: 600)
        let frame = state.targetFrame
        #expect(frame != nil)
        #expect(frame!.origin.x == 500)
        #expect(frame!.origin.y == 300)
    }

    @Test("targetFrame: partial fields → nil")
    func targetFramePartial() {
        let state = makeState(targetX: 500, targetY: 300)
        #expect(state.targetFrame == nil)
    }

    // MARK: - isCorrupted

    @Test("isCorrupted: both frames on main screen → true")
    func corruptedBothOnMain() {
        let state = makeState(
            origX: 100, origY: 200, origW: 800, origH: 600,
            targetX: 500, targetY: 300, targetW: 800, targetH: 600
        )
        let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(state.isCorrupted(mainScreenFrame: mainScreen))
    }

    @Test("isCorrupted: origFrame off-screen → false")
    func corruptedOrigOffScreen() {
        let state = makeState(
            origX: 100, origY: -1000, origW: 800, origH: 600,
            targetX: 500, targetY: 300, targetW: 800, targetH: 600
        )
        let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(!state.isCorrupted(mainScreenFrame: mainScreen))
    }

    @Test("isCorrupted: missing frames → false")
    func corruptedMissingFrames() {
        let state = makeState(origX: 100, targetX: 500)
        let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(!state.isCorrupted(mainScreenFrame: mainScreen))
    }

    // MARK: - Equatable

    @Test("WindowState Equatable: same values are equal")
    func equatableSame() {
        let state1 = makeState()
        let state2 = makeState()
        #expect(state1 == state2)
    }

    @Test("WindowState Equatable: different windowID → not equal")
    func equatableDifferent() {
        var state2 = makeState()
        state2.windowID = 99
        #expect(makeState() != state2)
    }

    // MARK: - WindowIdentity from WindowState

    @Test("WindowIdentity init from WindowState copies fields")
    func identityFromState() {
        let state = makeState()
        let identity = WindowIdentity(from: state)
        #expect(identity.windowID == 42)
        #expect(identity.pid == 1234)
        #expect(identity.bundleIdentifier == "com.test")
        #expect(identity.appName == "App")
        #expect(identity.title == "Test")
    }
}
