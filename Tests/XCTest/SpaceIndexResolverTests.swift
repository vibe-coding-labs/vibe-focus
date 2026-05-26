import Testing
import Foundation
@testable import VibeFocusKit

@Suite("SpaceIndexResolver Logic")
struct SpaceIndexResolverTests {

    // MARK: - Single screen

    @Test("chooseIndex: single screen uses focusedSpaceIndex when in display")
    func singleScreenFocusedMatch() {
        let spaces = [SpaceSnapshot(index: 1, isVisible: true, hasFocus: true)]
        let result = SpaceIndexResolver.chooseIndex(displaySpaces: spaces, focusedSpaceIndex: 1, screenCount: 1)
        #expect(result == 1)
    }

    @Test("chooseIndex: single screen uses focusedSpaceIndex even when not in display if display empty")
    func singleScreenFocusedWithEmptyDisplay() {
        let result = SpaceIndexResolver.chooseIndex(displaySpaces: [], focusedSpaceIndex: 3, screenCount: 1)
        #expect(result == 3)
    }

    @Test("chooseIndex: single screen falls back to visible space when focused not in display")
    func singleScreenFallbackToVisible() {
        let spaces = [SpaceSnapshot(index: 2, isVisible: true, hasFocus: false)]
        let result = SpaceIndexResolver.chooseIndex(displaySpaces: spaces, focusedSpaceIndex: 99, screenCount: 1)
        #expect(result == 2)
    }

    @Test("chooseIndex: single screen nil focused falls back to visible")
    func singleScreenNilFocused() {
        let spaces = [SpaceSnapshot(index: 3, isVisible: true, hasFocus: false)]
        let result = SpaceIndexResolver.chooseIndex(displaySpaces: spaces, focusedSpaceIndex: nil, screenCount: 1)
        #expect(result == 3)
    }

    @Test("chooseIndex: single screen empty everything returns nil")
    func singleScreenEmptyAll() {
        let result = SpaceIndexResolver.chooseIndex(displaySpaces: [], focusedSpaceIndex: nil, screenCount: 1)
        #expect(result == nil)
    }

    // MARK: - Multi screen

    @Test("chooseIndex: multi screen uses visible space")
    func multiScreenVisibleSpace() {
        let spaces = [
            SpaceSnapshot(index: 1, isVisible: false, hasFocus: false),
            SpaceSnapshot(index: 2, isVisible: true, hasFocus: false),
        ]
        let result = SpaceIndexResolver.chooseIndex(displaySpaces: spaces, focusedSpaceIndex: nil, screenCount: 2)
        #expect(result == 2)
    }

    @Test("chooseIndex: multi screen falls back to focused when in display")
    func multiScreenFocusedFallback() {
        let spaces = [
            SpaceSnapshot(index: 1, isVisible: false, hasFocus: false),
            SpaceSnapshot(index: 2, isVisible: false, hasFocus: true),
        ]
        let result = SpaceIndexResolver.chooseIndex(displaySpaces: spaces, focusedSpaceIndex: 2, screenCount: 2)
        #expect(result == 2)
    }

    @Test("chooseIndex: multi screen focused not in display returns nil")
    func multiScreenFocusedNotInDisplay() {
        let spaces = [
            SpaceSnapshot(index: 1, isVisible: false, hasFocus: false),
        ]
        let result = SpaceIndexResolver.chooseIndex(displaySpaces: spaces, focusedSpaceIndex: 5, screenCount: 2)
        #expect(result == nil)
    }

    @Test("chooseIndex: multi screen no visible, focused matches hasFocus")
    func multiScreenHasFocusMatch() {
        let spaces = [
            SpaceSnapshot(index: 3, isVisible: false, hasFocus: true),
        ]
        let result = SpaceIndexResolver.chooseIndex(displaySpaces: spaces, focusedSpaceIndex: 3, screenCount: 2)
        #expect(result == 3)
    }

    @Test("chooseIndex: multi screen all empty returns nil")
    func multiScreenAllEmpty() {
        let result = SpaceIndexResolver.chooseIndex(displaySpaces: [], focusedSpaceIndex: nil, screenCount: 2)
        #expect(result == nil)
    }
}
