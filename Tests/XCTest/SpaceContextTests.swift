import Testing
import Foundation
@testable import VibeFocusKit

@Suite("SpaceContext Logic")
@MainActor
struct SpaceContextTests {

    // MARK: - preferredSourceSpace tests (real SpaceController.shared implementation)

    @Test("preferredSourceSpace: returns windowSpace when both present and different")
    func preferredSourceMismatch() {
        let sc = SpaceController.shared
        #expect(sc.preferredSourceSpace(windowSpace: 3, visibleSpace: 1, fallbackSpace: nil) == 3)
    }

    @Test("preferredSourceSpace: returns windowSpace when both present and same")
    func preferredSourceSame() {
        let sc = SpaceController.shared
        #expect(sc.preferredSourceSpace(windowSpace: 2, visibleSpace: 2, fallbackSpace: nil) == 2)
    }

    @Test("preferredSourceSpace: returns windowSpace when only windowSpace present")
    func preferredSourceOnlyWindow() {
        let sc = SpaceController.shared
        #expect(sc.preferredSourceSpace(windowSpace: 5, visibleSpace: nil, fallbackSpace: nil) == 5)
    }

    @Test("preferredSourceSpace: returns visibleSpace when only visibleSpace present")
    func preferredSourceOnlyVisible() {
        let sc = SpaceController.shared
        #expect(sc.preferredSourceSpace(windowSpace: nil, visibleSpace: 7, fallbackSpace: nil) == 7)
    }

    @Test("preferredSourceSpace: returns fallbackSpace when both nil")
    func preferredSourceFallback() {
        let sc = SpaceController.shared
        #expect(sc.preferredSourceSpace(windowSpace: nil, visibleSpace: nil, fallbackSpace: 9) == 9)
    }

    @Test("preferredSourceSpace: returns nil when all nil")
    func preferredSourceAllNil() {
        let sc = SpaceController.shared
        #expect(sc.preferredSourceSpace(windowSpace: nil, visibleSpace: nil, fallbackSpace: nil) == nil)
    }

    @Test("preferredSourceSpace: ignores fallback when windowSpace present")
    func preferredSourceIgnoresFallback() {
        let sc = SpaceController.shared
        #expect(sc.preferredSourceSpace(windowSpace: 1, visibleSpace: nil, fallbackSpace: 99) == 1)
    }

    @Test("preferredSourceSpace: uses fallback chain windowSpace > visibleSpace > fallback")
    func preferredSourcePriorityChain() {
        let sc = SpaceController.shared
        #expect(sc.preferredSourceSpace(windowSpace: 1, visibleSpace: 2, fallbackSpace: 3) == 1)
        #expect(sc.preferredSourceSpace(windowSpace: nil, visibleSpace: 2, fallbackSpace: 3) == 2)
        #expect(sc.preferredSourceSpace(windowSpace: nil, visibleSpace: nil, fallbackSpace: 3) == 3)
    }

    // MARK: - displayLocalSpaceIndex tests (real SpaceController.shared implementation)

    @Test("displayLocalSpaceIndex: returns nil when spaceIndex is nil")
    func localIndexNilSpace() {
        let sc = SpaceController.shared
        let spaces = [YabaiSpaceInfo(id: 1, index: 1, display: 1, isVisible: true)]
        #expect(sc.displayLocalSpaceIndex(forGlobalSpaceIndex: nil, displayIndex: 1, spaces: spaces) == nil)
    }

    @Test("displayLocalSpaceIndex: returns nil when displayIndex is nil")
    func localIndexNilDisplay() {
        let sc = SpaceController.shared
        let spaces = [YabaiSpaceInfo(id: 1, index: 1, display: 1, isVisible: true)]
        #expect(sc.displayLocalSpaceIndex(forGlobalSpaceIndex: 1, displayIndex: nil, spaces: spaces) == nil)
    }

    @Test("displayLocalSpaceIndex: returns nil when both nil")
    func localIndexBothNil() {
        let sc = SpaceController.shared
        #expect(sc.displayLocalSpaceIndex(forGlobalSpaceIndex: nil, displayIndex: nil, spaces: []) == nil)
    }

    @Test("displayLocalSpaceIndex: single display, first space returns 1")
    func localIndexSingleDisplayFirstSpace() {
        let sc = SpaceController.shared
        let spaces = [
            YabaiSpaceInfo(id: 1, index: 1, display: 1, isVisible: true),
            YabaiSpaceInfo(id: 2, index: 2, display: 1, isVisible: false),
            YabaiSpaceInfo(id: 3, index: 3, display: 1, isVisible: false)
        ]
        #expect(sc.displayLocalSpaceIndex(forGlobalSpaceIndex: 1, displayIndex: 1, spaces: spaces) == 1)
    }

    @Test("displayLocalSpaceIndex: single display, second space returns 2")
    func localIndexSingleDisplaySecondSpace() {
        let sc = SpaceController.shared
        let spaces = [
            YabaiSpaceInfo(id: 1, index: 1, display: 1, isVisible: true),
            YabaiSpaceInfo(id: 2, index: 2, display: 1, isVisible: false),
            YabaiSpaceInfo(id: 3, index: 3, display: 1, isVisible: false)
        ]
        #expect(sc.displayLocalSpaceIndex(forGlobalSpaceIndex: 2, displayIndex: 1, spaces: spaces) == 2)
    }

    @Test("displayLocalSpaceIndex: single display, third space returns 3")
    func localIndexSingleDisplayThirdSpace() {
        let sc = SpaceController.shared
        let spaces = [
            YabaiSpaceInfo(id: 1, index: 1, display: 1, isVisible: true),
            YabaiSpaceInfo(id: 2, index: 2, display: 1, isVisible: false),
            YabaiSpaceInfo(id: 3, index: 3, display: 1, isVisible: false)
        ]
        #expect(sc.displayLocalSpaceIndex(forGlobalSpaceIndex: 3, displayIndex: 1, spaces: spaces) == 3)
    }

    @Test("displayLocalSpaceIndex: multi-display, filters by displayIndex")
    func localIndexMultiDisplay() {
        let sc = SpaceController.shared
        let spaces = [
            YabaiSpaceInfo(id: 1, index: 1, display: 1, isVisible: true),
            YabaiSpaceInfo(id: 2, index: 2, display: 1, isVisible: false),
            YabaiSpaceInfo(id: 3, index: 3, display: 2, isVisible: true),
            YabaiSpaceInfo(id: 4, index: 4, display: 2, isVisible: false),
        ]
        #expect(sc.displayLocalSpaceIndex(forGlobalSpaceIndex: 1, displayIndex: 1, spaces: spaces) == 1)
        #expect(sc.displayLocalSpaceIndex(forGlobalSpaceIndex: 2, displayIndex: 1, spaces: spaces) == 2)
        #expect(sc.displayLocalSpaceIndex(forGlobalSpaceIndex: 3, displayIndex: 2, spaces: spaces) == 1)
        #expect(sc.displayLocalSpaceIndex(forGlobalSpaceIndex: 4, displayIndex: 2, spaces: spaces) == 2)
    }

    @Test("displayLocalSpaceIndex: returns nil when spaceIndex not found on display")
    func localIndexNotFound() {
        let sc = SpaceController.shared
        let spaces = [
            YabaiSpaceInfo(id: 1, index: 1, display: 1, isVisible: true),
            YabaiSpaceInfo(id: 2, index: 2, display: 1, isVisible: false),
        ]
        #expect(sc.displayLocalSpaceIndex(forGlobalSpaceIndex: 99, displayIndex: 1, spaces: spaces) == nil)
    }

    @Test("displayLocalSpaceIndex: returns nil when no spaces on specified display")
    func localIndexNoSpacesOnDisplay() {
        let sc = SpaceController.shared
        let spaces = [
            YabaiSpaceInfo(id: 1, index: 1, display: 1, isVisible: true),
        ]
        #expect(sc.displayLocalSpaceIndex(forGlobalSpaceIndex: 1, displayIndex: 2, spaces: spaces) == nil)
    }

    @Test("displayLocalSpaceIndex: empty spaces array returns nil")
    func localIndexEmptySpaces() {
        let sc = SpaceController.shared
        #expect(sc.displayLocalSpaceIndex(forGlobalSpaceIndex: 1, displayIndex: 1, spaces: []) == nil)
    }

    @Test("displayLocalSpaceIndex: sorts by index ascending regardless of input order")
    func localIndexSortOrder() {
        let sc = SpaceController.shared
        let spaces = [
            YabaiSpaceInfo(id: 3, index: 3, display: 1, isVisible: false),
            YabaiSpaceInfo(id: 1, index: 1, display: 1, isVisible: true),
            YabaiSpaceInfo(id: 2, index: 2, display: 1, isVisible: false),
        ]
        #expect(sc.displayLocalSpaceIndex(forGlobalSpaceIndex: 3, displayIndex: 1, spaces: spaces) == 3)
        #expect(sc.displayLocalSpaceIndex(forGlobalSpaceIndex: 1, displayIndex: 1, spaces: spaces) == 1)
        #expect(sc.displayLocalSpaceIndex(forGlobalSpaceIndex: 2, displayIndex: 1, spaces: spaces) == 2)
    }

    @Test("displayLocalSpaceIndex: handles nil index in space info")
    func localIndexNilIndexInSpaces() {
        let sc = SpaceController.shared
        let spaces = [
            YabaiSpaceInfo(id: 10, index: nil, display: 1, isVisible: false),
            YabaiSpaceInfo(id: 1, index: 1, display: 1, isVisible: true),
        ]
        #expect(sc.displayLocalSpaceIndex(forGlobalSpaceIndex: 1, displayIndex: 1, spaces: spaces) == 1)
        #expect(sc.displayLocalSpaceIndex(forGlobalSpaceIndex: nil, displayIndex: 1, spaces: spaces) == nil)
    }
}
