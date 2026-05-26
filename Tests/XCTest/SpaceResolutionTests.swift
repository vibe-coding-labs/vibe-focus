import Testing
import Foundation
@testable import VibeFocusKit

@Suite("SpaceController Resolution Logic")
@MainActor
struct SpaceResolutionTests {

    private func makeSpaces(_ data: [(id: Int?, index: Int?, display: Int?, isVisible: Bool?)]) -> [YabaiSpaceInfo] {
        let json = data.map { item -> String in
            var parts: [String] = []
            if let id = item.id { parts.append("\"id\": \(id)") }
            if let index = item.index { parts.append("\"index\": \(index)") }
            if let display = item.display { parts.append("\"display\": \(display)") }
            if let vis = item.isVisible { parts.append("\"is-visible\": \(vis)") }
            return "{\(parts.joined(separator: ", "))}"
        }.joined(separator: ",")
        return try! JSONDecoder().decode([YabaiSpaceInfo].self, from: Data("[\(json)]".utf8))
    }

    // MARK: - resolveVisibleSpaceIndex

    @Test("resolveVisibleSpaceIndex: finds visible space on display")
    func visibleFound() {
        let spaces = makeSpaces([
            (id: 1, index: 1, display: 1, isVisible: true),
            (id: 2, index: 2, display: 1, isVisible: false),
            (id: 3, index: 3, display: 2, isVisible: true),
        ])
        let result = SpaceController.resolveVisibleSpaceIndex(displayIndex: 1, spaces: spaces)
        #expect(result?.yabaiIndex == 1)
    }

    @Test("resolveVisibleSpaceIndex: returns nil when no visible space on display")
    func visibleNoneOnDisplay() {
        let spaces = makeSpaces([
            (id: 1, index: 1, display: 1, isVisible: false),
            (id: 2, index: 2, display: 1, isVisible: false),
        ])
        let result = SpaceController.resolveVisibleSpaceIndex(displayIndex: 1, spaces: spaces)
        #expect(result == nil)
    }

    @Test("resolveVisibleSpaceIndex: nil displayIndex → nil")
    func visibleNilDisplay() {
        let spaces = makeSpaces([(id: 1, index: 1, display: 1, isVisible: true)])
        let result = SpaceController.resolveVisibleSpaceIndex(displayIndex: nil, spaces: spaces)
        #expect(result == nil)
    }

    @Test("resolveVisibleSpaceIndex: nil spaces → nil")
    func visibleNilSpaces() {
        let result = SpaceController.resolveVisibleSpaceIndex(displayIndex: 1, spaces: nil)
        #expect(result == nil)
    }

    @Test("resolveVisibleSpaceIndex: empty spaces → nil")
    func visibleEmptySpaces() {
        let result = SpaceController.resolveVisibleSpaceIndex(displayIndex: 1, spaces: [])
        #expect(result == nil)
    }

    @Test("resolveVisibleSpaceIndex: finds correct display in multi-display setup")
    func visibleMultiDisplay() {
        let spaces = makeSpaces([
            (id: 1, index: 1, display: 1, isVisible: false),
            (id: 2, index: 2, display: 2, isVisible: true),
            (id: 3, index: 3, display: 1, isVisible: true),
        ])
        let result = SpaceController.resolveVisibleSpaceIndex(displayIndex: 2, spaces: spaces)
        #expect(result?.yabaiIndex == 2)
    }

    // MARK: - resolveDisplayLocalSpaceIndex

    @Test("resolveDisplayLocalSpaceIndex: returns 1-based offset on display")
    func localSpaceFound() {
        let spaces = makeSpaces([
            (id: 1, index: 1, display: 1, isVisible: nil),
            (id: 2, index: 2, display: 1, isVisible: nil),
            (id: 3, index: 3, display: 2, isVisible: nil),
        ])
        // Display 1 has spaces [1, 2]. Space 2 is at offset 1 → returns 2
        let result = SpaceController.resolveDisplayLocalSpaceIndex(spaceIndex: 2, displayIndex: 1, spaces: spaces)
        #expect(result == 2)
    }

    @Test("resolveDisplayLocalSpaceIndex: first space on display returns 1")
    func localSpaceFirst() {
        let spaces = makeSpaces([
            (id: 1, index: 1, display: 1, isVisible: nil),
        ])
        let result = SpaceController.resolveDisplayLocalSpaceIndex(spaceIndex: 1, displayIndex: 1, spaces: spaces)
        #expect(result == 1)
    }

    @Test("resolveDisplayLocalSpaceIndex: nil spaceIndex → nil")
    func localSpaceNilIndex() {
        let spaces = makeSpaces([(id: 1, index: 1, display: 1, isVisible: nil)])
        let result = SpaceController.resolveDisplayLocalSpaceIndex(spaceIndex: nil, displayIndex: 1, spaces: spaces)
        #expect(result == nil)
    }

    @Test("resolveDisplayLocalSpaceIndex: nil displayIndex → nil")
    func localSpaceNilDisplay() {
        let spaces = makeSpaces([(id: 1, index: 1, display: 1, isVisible: nil)])
        let result = SpaceController.resolveDisplayLocalSpaceIndex(spaceIndex: 1, displayIndex: nil, spaces: spaces)
        #expect(result == nil)
    }

    @Test("resolveDisplayLocalSpaceIndex: nil spaces → nil")
    func localSpaceNilSpaces() {
        let result = SpaceController.resolveDisplayLocalSpaceIndex(spaceIndex: 1, displayIndex: 1, spaces: nil)
        #expect(result == nil)
    }

    @Test("resolveDisplayLocalSpaceIndex: space not on display → nil")
    func localSpaceNotFound() {
        let spaces = makeSpaces([
            (id: 1, index: 1, display: 1, isVisible: nil),
        ])
        let result = SpaceController.resolveDisplayLocalSpaceIndex(spaceIndex: 5, displayIndex: 1, spaces: spaces)
        #expect(result == nil)
    }

    @Test("resolveDisplayLocalSpaceIndex: spaces sorted by index regardless of input order")
    func localSpaceSorted() {
        let spaces = makeSpaces([
            (id: 3, index: 5, display: 1, isVisible: nil),
            (id: 1, index: 2, display: 1, isVisible: nil),
            (id: 2, index: 8, display: 1, isVisible: nil),
        ])
        // Sorted: [2, 5, 8]. Space 8 is at offset 2 → returns 3
        let result = SpaceController.resolveDisplayLocalSpaceIndex(spaceIndex: 8, displayIndex: 1, spaces: spaces)
        #expect(result == 3)
    }

    @Test("resolveDisplayLocalSpaceIndex: ignores spaces on other displays")
    func localSpaceFiltersDisplay() {
        let spaces = makeSpaces([
            (id: 1, index: 1, display: 1, isVisible: nil),
            (id: 2, index: 2, display: 2, isVisible: nil),
            (id: 3, index: 3, display: 1, isVisible: nil),
        ])
        // Display 1 spaces: [1, 3]. Space 3 at offset 1 → returns 2
        let result = SpaceController.resolveDisplayLocalSpaceIndex(spaceIndex: 3, displayIndex: 1, spaces: spaces)
        #expect(result == 2)
    }

    // MARK: - resolveNativeSpaceID

    @Test("resolveNativeSpaceID: finds native ID for yabai index")
    func nativeIDFound() {
        let spaces = makeSpaces([
            (id: 123, index: 1, display: nil, isVisible: nil),
            (id: 456, index: 2, display: nil, isVisible: nil),
        ])
        let result = SpaceController.resolveNativeSpaceID(yabaiIndex: 2, spaces: spaces)
        #expect(result == 456)
    }

    @Test("resolveNativeSpaceID: nil spaces → nil")
    func nativeIDNilSpaces() {
        let result = SpaceController.resolveNativeSpaceID(yabaiIndex: 1, spaces: nil)
        #expect(result == nil)
    }

    @Test("resolveNativeSpaceID: index not found → nil")
    func nativeIDNotFound() {
        let spaces = makeSpaces([
            (id: 123, index: 1, display: nil, isVisible: nil),
        ])
        let result = SpaceController.resolveNativeSpaceID(yabaiIndex: 99, spaces: spaces)
        #expect(result == nil)
    }

    @Test("resolveNativeSpaceID: space with nil id → nil")
    func nativeIDNilID() {
        let spaces = makeSpaces([
            (id: nil, index: 1, display: nil, isVisible: nil),
        ])
        let result = SpaceController.resolveNativeSpaceID(yabaiIndex: 1, spaces: spaces)
        #expect(result == nil)
    }
}
