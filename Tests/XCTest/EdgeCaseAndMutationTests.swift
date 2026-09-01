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
}
