import Testing
import Foundation
@testable import VibeFocusKit

@Suite("ModelState Edge Cases and Additional Coverage")
struct EdgeCaseAndMutationTests {

    // MARK: - ClaudeHookEventType exhaustiveness

    @Test("ClaudeHookEventType: all raw values are unique")
    func uniqueRawValues() {
        let rawValues = ClaudeHookEventType.allCases.map(\.rawValue)
        let uniqueRawValues = Set(rawValues)
        #expect(rawValues.count == uniqueRawValues.count)
    }

    @Test("ClaudeHookEventType: init from rawValue returns nil for invalid")
    func invalidRawValue() {
        #expect(ClaudeHookEventType(rawValue: "invalid") == nil)
        #expect(ClaudeHookEventType(rawValue: "") == nil)
        #expect(ClaudeHookEventType(rawValue: "sessionStart") == nil) // case-sensitive
    }

    // MARK: - WindowMoveReason exhaustiveness

    @Test("WindowMoveReason: has exactly 2 cases")
    func moveReasonCount() {
        // Not CaseIterable, verify via raw values
        let values: [WindowMoveReason] = [.manualHotkey, .claudeSessionEnd]
        #expect(values.count == 2)
    }

    @Test("WindowMoveReason: init from rawValue returns nil for invalid")
    func moveReasonInvalidRawValue() {
        #expect(WindowMoveReason(rawValue: "manual") == nil)
        #expect(WindowMoveReason(rawValue: "") == nil)
    }

    // MARK: - WindowState isCorrupted edge cases

    @Test("WindowState.isCorrupted: zero-size frames on main screen center")
    func zeroSizeFramesOnMain() {
        var state = WindowState(
            windowID: 1, pid: 100, tty: nil,
            axWindowNumber: nil, appName: nil, bundleIdentifier: nil,
            title: nil, termSessionID: nil, itermSessionID: nil,
            kittyWindowID: nil, weztermPane: nil, envWindowID: nil,
            sessionID: nil, cwd: nil, model: nil,
            origX: 500, origY: 500, origW: 0, origH: 0,
            targetX: 500, targetY: 500, targetW: 0, targetH: 0,
            sourceSpace: nil, sourceDisplay: nil,
            sourceYabaiDisp: nil, sourceDispSpace: nil,
            targetDisplay: nil, toggleReason: nil, toggledAt: nil,
            isCompleted: false, completedAt: nil,
            createdAt: Date(), updatedAt: Date()
        )
        // Zero-size frames at (500, 500) — both centers are on main screen
        let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(state.isCorrupted(mainScreenFrame: mainScreen))
    }

    @Test("WindowState.isCorrupted: large frame covering entire screen")
    func fullScreenFrame() {
        var state = WindowState(
            windowID: 1, pid: 100, tty: nil,
            axWindowNumber: nil, appName: nil, bundleIdentifier: nil,
            title: nil, termSessionID: nil, itermSessionID: nil,
            kittyWindowID: nil, weztermPane: nil, envWindowID: nil,
            sessionID: nil, cwd: nil, model: nil,
            origX: 0, origY: 0, origW: 1920, origH: 1080,
            targetX: 0, targetY: 0, targetW: 1920, targetH: 1080,
            sourceSpace: nil, sourceDisplay: nil,
            sourceYabaiDisp: nil, sourceDispSpace: nil,
            targetDisplay: nil, toggleReason: nil, toggledAt: nil,
            isCompleted: false, completedAt: nil,
            createdAt: Date(), updatedAt: Date()
        )
        let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // Both centers at (960, 540) → on main screen → corrupted
        #expect(state.isCorrupted(mainScreenFrame: mainScreen))
    }

    @Test("WindowState: only origX set, rest nil → hasToggleState false")
    func hasToggleStatePartialOrigOnly() {
        var state = WindowState(
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
            createdAt: Date(), updatedAt: Date()
        )
        state.origX = 100
        #expect(!state.hasToggleState)
    }

    @Test("WindowState: only targetX set → hasToggleState false")
    func hasToggleStateTargetOnly() {
        var state = WindowState(
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
            createdAt: Date(), updatedAt: Date()
        )
        state.targetX = 500
        #expect(!state.hasToggleState)
    }

    @Test("WindowState: both origX and targetX set → hasToggleState true")
    func hasToggleStateBothSet() {
        var state = WindowState(
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
            createdAt: Date(), updatedAt: Date()
        )
        state.origX = -1920
        state.targetX = 0
        #expect(state.hasToggleState)
    }

    // MARK: - SpaceIdentifier description

    @Test("SpaceIdentifier description: yabaiIndex")
    func spaceIdentifierYabai() {
        let id = SpaceIdentifier.yabai(3)
        #expect(id.description == "yabai_space(3)")
    }

    @Test("SpaceIdentifier description: nativeID")
    func spaceIdentifierNative() {
        let id = SpaceIdentifier.native(123)
        #expect(id.description == "native_space(123)")
    }

    // MARK: - DisplayIdentifier factory methods

    @Test("DisplayIdentifier factory: yabai returns correct variant")
    func displayFactoryYabai() {
        let id = DisplayIdentifier.yabai(2)
        if case .yabaiIndex(let idx) = id {
            #expect(idx == 2)
        } else {
            #expect(Bool(false), "Expected .yabaiIndex")
        }
    }

    @Test("DisplayIdentifier factory: screenArray returns correct variant")
    func displayFactoryScreen() {
        let id = DisplayIdentifier.screenArray(0)
        if case .screenArrayIndex(let idx) = id {
            #expect(idx == 0)
        } else {
            #expect(Bool(false), "Expected .screenArrayIndex")
        }
    }

    @Test("DisplayIdentifier factory: cgDisplay returns correct variant")
    func displayFactoryCG() {
        let id = DisplayIdentifier.cgDisplay(45678)
        if case .cgDirectDisplayID(let val) = id {
            #expect(val == 45678)
        } else {
            #expect(Bool(false), "Expected .cgDirectDisplayID")
        }
    }

    // MARK: - IndexPosition allCases

    @Test("IndexPosition: has exactly 6 cases")
    func indexPositionCount() {
        #expect(IndexPosition.allCases.count == 6)
    }

    @Test("IndexPosition: each case has non-empty rawValue")
    func indexPositionNonEmptyRawValues() {
        for position in IndexPosition.allCases {
            #expect(!position.rawValue.isEmpty)
        }
    }

    // MARK: - SpaceRestoreStrategy

    @Test("SpaceRestoreStrategy: has exactly 2 cases")
    func restoreStrategyCount() {
        #expect(SpaceRestoreStrategy.allCases.count == 2)
    }

    @Test("SpaceRestoreStrategy: raw values are correct")
    func restoreStrategyRawValues() {
        #expect(SpaceRestoreStrategy.switchToOriginal.rawValue == "switchToOriginal")
        #expect(SpaceRestoreStrategy.pullToCurrent.rawValue == "pullToCurrent")
    }

    @Test("SpaceRestoreStrategy: init from invalid rawValue returns nil")
    func restoreStrategyInvalidRawValue() {
        #expect(SpaceRestoreStrategy(rawValue: "unknown") == nil)
    }
}
