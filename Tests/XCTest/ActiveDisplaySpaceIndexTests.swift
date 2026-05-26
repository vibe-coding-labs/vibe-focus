import Testing
import Foundation
@testable import VibeFocusKit

@Suite("Active Display Space Index")
struct ActiveDisplaySpaceIndexTests {

    @Test("activeDisplaySpaceIndex: prefers isVisible over hasFocus")
    func prefersVisibleOverFocus() {
        let spaces = [
            SpaceSnapshot(index: 1, isVisible: false, hasFocus: true),
            SpaceSnapshot(index: 2, isVisible: true, hasFocus: false),
        ]
        #expect(SpaceIndexResolver.activeDisplaySpaceIndex(in: spaces) == 2)
    }

    @Test("activeDisplaySpaceIndex: returns visible space index")
    func visibleSpace() {
        let spaces = [
            SpaceSnapshot(index: 5, isVisible: true, hasFocus: false),
        ]
        #expect(SpaceIndexResolver.activeDisplaySpaceIndex(in: spaces) == 5)
    }

    @Test("activeDisplaySpaceIndex: falls back to hasFocus when none visible")
    func fallbackToFocus() {
        let spaces = [
            SpaceSnapshot(index: 3, isVisible: false, hasFocus: true),
        ]
        #expect(SpaceIndexResolver.activeDisplaySpaceIndex(in: spaces) == 3)
    }

    @Test("activeDisplaySpaceIndex: returns nil when empty")
    func emptySpaces() {
        #expect(SpaceIndexResolver.activeDisplaySpaceIndex(in: []) == nil)
    }

    @Test("activeDisplaySpaceIndex: returns nil when all false")
    func allFalse() {
        let spaces = [
            SpaceSnapshot(index: 1, isVisible: false, hasFocus: false),
            SpaceSnapshot(index: 2, isVisible: false, hasFocus: false),
        ]
        #expect(SpaceIndexResolver.activeDisplaySpaceIndex(in: spaces) == nil)
    }

    @Test("activeDisplaySpaceIndex: first visible wins with multiple visible")
    func firstVisibleWins() {
        let spaces = [
            SpaceSnapshot(index: 1, isVisible: true, hasFocus: false),
            SpaceSnapshot(index: 2, isVisible: true, hasFocus: true),
        ]
        #expect(SpaceIndexResolver.activeDisplaySpaceIndex(in: spaces) == 1)
    }
}
