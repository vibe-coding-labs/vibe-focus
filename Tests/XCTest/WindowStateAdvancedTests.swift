import Testing
import Foundation
import CoreGraphics
@testable import VibeFocusKit

@Suite("WindowState Codable and Mutation")
struct WindowStateAdvancedTests {

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeMinimal() -> WindowState {
        WindowState(
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
            createdAt: fixedDate, updatedAt: fixedDate
        )
    }

    // MARK: - Codable roundtrip

    @Test("WindowState Codable roundtrip with minimal fields")
    func codableMinimal() throws {
        let state = makeMinimal()
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WindowState.self, from: data)
        #expect(decoded.windowID == 1)
        #expect(decoded.pid == 100)
        #expect(decoded.tty == nil)
        #expect(decoded.sessionID == nil)
        #expect(decoded.isCompleted == false)
    }

    @Test("WindowState Codable roundtrip with all fields populated")
    func codableAllFields() throws {
        let state = WindowState(
            windowID: 99, pid: 5678, tty: "/dev/ttys002",
            axWindowNumber: 200, appName: "iTerm2",
            bundleIdentifier: "com.googlecode.iterm2",
            title: "vim main.swift",
            termSessionID: "term-1", itermSessionID: "iterm-1",
            kittyWindowID: "kitty-1", weztermPane: "wez-1", envWindowID: "env-1",
            sessionID: "sess-full", cwd: "/Users/dev", model: "claude-4",
            origX: -1920, origY: 100, origW: 800, origH: 600,
            targetX: 500, targetY: 300, targetW: 900, targetH: 700,
            sourceSpace: 3, sourceDisplay: 2,
            sourceYabaiDisp: 2, sourceDispSpace: 1,
            targetDisplay: 1, toggleReason: "manual_hotkey",
            toggledAt: fixedDate,
            isCompleted: true, completedAt: fixedDate.addingTimeInterval(60),
            createdAt: fixedDate, updatedAt: fixedDate
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WindowState.self, from: data)

        #expect(decoded.windowID == 99)
        #expect(decoded.pid == 5678)
        #expect(decoded.tty == "/dev/ttys002")
        #expect(decoded.axWindowNumber == 200)
        #expect(decoded.appName == "iTerm2")
        #expect(decoded.bundleIdentifier == "com.googlecode.iterm2")
        #expect(decoded.title == "vim main.swift")
        #expect(decoded.termSessionID == "term-1")
        #expect(decoded.itermSessionID == "iterm-1")
        #expect(decoded.kittyWindowID == "kitty-1")
        #expect(decoded.weztermPane == "wez-1")
        #expect(decoded.envWindowID == "env-1")
        #expect(decoded.sessionID == "sess-full")
        #expect(decoded.cwd == "/Users/dev")
        #expect(decoded.model == "claude-4")
        #expect(decoded.origX == -1920)
        #expect(decoded.origY == 100)
        #expect(decoded.origW == 800)
        #expect(decoded.origH == 600)
        #expect(decoded.targetX == 500)
        #expect(decoded.targetY == 300)
        #expect(decoded.targetW == 900)
        #expect(decoded.targetH == 700)
        #expect(decoded.sourceSpace == 3)
        #expect(decoded.sourceDisplay == 2)
        #expect(decoded.sourceYabaiDisp == 2)
        #expect(decoded.sourceDispSpace == 1)
        #expect(decoded.targetDisplay == 1)
        #expect(decoded.toggleReason == "manual_hotkey")
        #expect(decoded.isCompleted == true)
    }

    // MARK: - Mutation

    @Test("WindowState mutation: changing windowID")
    func mutateWindowID() {
        var state = makeMinimal()
        state.windowID = 55
        #expect(state.windowID == 55)
    }

    @Test("WindowState mutation: setting toggle fields")
    func mutateToggleFields() {
        var state = makeMinimal()
        #expect(!state.hasToggleState)

        state.origX = -1920
        state.origY = 0
        state.origW = 1920
        state.origH = 1080
        state.targetX = 0
        state.targetY = 0
        state.targetW = 1920
        state.targetH = 1080

        #expect(state.hasToggleState)
        #expect(state.originalFrame != nil)
        #expect(state.targetFrame != nil)
    }

    @Test("WindowState mutation: clearing toggle fields")
    func clearToggleFields() {
        var state = makeMinimal()
        state.origX = 100
        state.targetX = 500
        #expect(state.hasToggleState)

        state.origX = nil
        state.targetX = nil
        #expect(!state.hasToggleState)
    }

    @Test("WindowState mutation: marking completed")
    func markCompleted() {
        var state = makeMinimal()
        #expect(!state.isCompleted)

        state.isCompleted = true
        state.completedAt = fixedDate.addingTimeInterval(60)
        #expect(state.isCompleted)
        #expect(state.completedAt != nil)
    }

    @Test("WindowState mutation: updating session")
    func updateSession() {
        var state = makeMinimal()
        #expect(state.sessionID == nil)

        state.sessionID = "sess-new"
        state.cwd = "/new/path"
        state.model = "opus"
        #expect(state.sessionID == "sess-new")
        #expect(state.cwd == "/new/path")
        #expect(state.model == "opus")
    }

    // MARK: - originalFrame edge cases

    @Test("WindowState.originalFrame: negative coordinates")
    func originalFrameNegative() {
        var state = makeMinimal()
        state.origX = -3840
        state.origY = -2160
        state.origW = 1920
        state.origH = 1080
        let frame = state.originalFrame
        #expect(frame?.origin.x == -3840)
        #expect(frame?.origin.y == -2160)
    }

    @Test("WindowState.targetFrame: zero size")
    func targetFrameZeroSize() {
        var state = makeMinimal()
        state.targetX = 100
        state.targetY = 200
        state.targetW = 0
        state.targetH = 0
        let frame = state.targetFrame
        #expect(frame != nil)
        #expect(frame?.width == 0)
        #expect(frame?.height == 0)
    }

    @Test("WindowState.isCorrupted: target center on boundary")
    func corruptionBoundaryCheck() {
        var state = makeMinimal()
        // origFrame center at (400, 300) — inside 0,0 800x600
        state.origX = 0; state.origY = 0; state.origW = 800; state.origH = 600
        // targetFrame center at (800, 300) — on maxX boundary
        state.targetX = 400; state.targetY = 0; state.targetW = 800; state.targetH = 600

        let mainScreen = CGRect(x: 0, y: 0, width: 800, height: 600)
        // CGRect.contains does NOT include maxX boundary
        // origCenter = (400, 300) → inside
        // targetCenter = (800, 300) → NOT inside (on boundary)
        #expect(!state.isCorrupted(mainScreenFrame: mainScreen))
    }

    // MARK: - Equatable comprehensive

    @Test("WindowState Equatable: different pid → not equal")
    func equatableDifferentPID() {
        var a = makeMinimal()
        var b = makeMinimal()
        b.pid = 200
        #expect(a != b)
    }

    @Test("WindowState Equatable: different toggle fields → not equal")
    func equatableDifferentToggle() {
        var a = makeMinimal()
        var b = makeMinimal()
        b.origX = 100
        #expect(a != b)
    }

    @Test("WindowState Equatable: identical states → equal")
    func equatableIdentical() {
        let a = makeMinimal()
        let b = makeMinimal()
        #expect(a == b)
    }
}
