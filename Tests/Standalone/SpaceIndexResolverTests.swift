// Tests/Standalone/SpaceIndexResolverTests.swift
// Verification: SpaceIndexResolver.chooseIndex — space index selection logic
// Mirrors: Sources/Overlay/ScreenOverlayManager+SpaceIndex.swift:5-43
// Run: swift Tests/Standalone/SpaceIndexResolverTests.swift

import Foundation

// MARK: - Mirrored types (ScreenOverlayManager+SpaceIndex.swift:5-43)

struct SpaceSnapshot: Equatable {
    let index: Int
    let isVisible: Bool
    let hasFocus: Bool
}

enum SpaceIndexResolver {
    static func chooseIndex(displaySpaces: [SpaceSnapshot], focusedSpaceIndex: Int?, screenCount: Int) -> Int? {
        let displayActive = activeDisplaySpaceIndex(in: displaySpaces)
        let displayIndices = Set(displaySpaces.map(\.index))

        if screenCount <= 1 {
            if let focusedSpaceIndex {
                if displayIndices.isEmpty || displayIndices.contains(focusedSpaceIndex) {
                    return focusedSpaceIndex
                }
            }
            return displayActive
        }

        if let displayActive {
            return displayActive
        }
        if let focusedSpaceIndex, displayIndices.contains(focusedSpaceIndex) {
            return focusedSpaceIndex
        }
        return nil
    }

    private static func activeDisplaySpaceIndex(in spaces: [SpaceSnapshot]) -> Int? {
        if let visible = spaces.first(where: { $0.isVisible }) {
            return visible.index
        }
        if let focused = spaces.first(where: { $0.hasFocus }) {
            return focused.index
        }
        return nil
    }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

func checkEqual(_ name: String, _ a: Int?, _ b: Int?) {
    if a == b { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name) — expected \(String(describing: b)), got \(String(describing: a))") }
}

// MARK: - Single screen, single space

print("1. Single screen — one visible space")
do {
    let spaces = [SpaceSnapshot(index: 1, isVisible: true, hasFocus: true)]
    checkEqual("returns visible space index", SpaceIndexResolver.chooseIndex(displaySpaces: spaces, focusedSpaceIndex: nil, screenCount: 1), 1)
}

print("\n2. Single screen — focused space matches display")
do {
    let spaces = [SpaceSnapshot(index: 2, isVisible: true, hasFocus: true)]
    checkEqual("focused=2, display has 2 → returns 2", SpaceIndexResolver.chooseIndex(displaySpaces: spaces, focusedSpaceIndex: 2, screenCount: 1), 2)
}

print("\n3. Single screen — focused space NOT in display, uses display active")
do {
    let spaces = [SpaceSnapshot(index: 3, isVisible: true, hasFocus: true)]
    checkEqual("focused=5 not in display → returns display active (3)", SpaceIndexResolver.chooseIndex(displaySpaces: spaces, focusedSpaceIndex: 5, screenCount: 1), 3)
}

print("\n4. Single screen — empty display spaces, uses focused")
do {
    checkEqual("empty spaces, focused=2 → returns 2", SpaceIndexResolver.chooseIndex(displaySpaces: [], focusedSpaceIndex: 2, screenCount: 1), 2)
}

print("\n5. Single screen — empty display spaces, no focused → nil")
do {
    checkEqual("empty spaces, no focused → nil", SpaceIndexResolver.chooseIndex(displaySpaces: [], focusedSpaceIndex: nil, screenCount: 1), nil)
}

// MARK: - Multi-screen scenarios

print("\n6. Multi-screen — visible space takes priority")
do {
    let spaces = [SpaceSnapshot(index: 3, isVisible: true, hasFocus: false)]
    checkEqual("visible=3 takes priority over focused=5", SpaceIndexResolver.chooseIndex(displaySpaces: spaces, focusedSpaceIndex: 5, screenCount: 2), 3)
}

print("\n7. Multi-screen — no visible, focused matches display")
do {
    let spaces = [
        SpaceSnapshot(index: 1, isVisible: false, hasFocus: false),
        SpaceSnapshot(index: 2, isVisible: false, hasFocus: true),
    ]
    checkEqual("no visible, focused=2 in display → returns 2", SpaceIndexResolver.chooseIndex(displaySpaces: spaces, focusedSpaceIndex: 2, screenCount: 2), 2)
}

print("\n8. Multi-screen — no visible, focused NOT in display")
do {
    let spaces = [
        SpaceSnapshot(index: 1, isVisible: false, hasFocus: false),
        SpaceSnapshot(index: 2, isVisible: false, hasFocus: false),
    ]
    checkEqual("no visible, focused=99 not in display → nil", SpaceIndexResolver.chooseIndex(displaySpaces: spaces, focusedSpaceIndex: 99, screenCount: 2), nil)
}

print("\n9. Multi-screen — no visible, no focused")
do {
    let spaces = [
        SpaceSnapshot(index: 1, isVisible: false, hasFocus: false),
        SpaceSnapshot(index: 2, isVisible: false, hasFocus: false),
    ]
    checkEqual("no visible, no focused → nil", SpaceIndexResolver.chooseIndex(displaySpaces: spaces, focusedSpaceIndex: nil, screenCount: 2), nil)
}

print("\n10. Multi-screen — empty display spaces, focused present")
do {
    checkEqual("empty spaces, focused=1, multi-screen → nil", SpaceIndexResolver.chooseIndex(displaySpaces: [], focusedSpaceIndex: 1, screenCount: 2), nil)
}

// MARK: - activeDisplaySpaceIndex priority

print("\n11. activeDisplaySpaceIndex — visible takes priority over focused")
do {
    let spaces = [
        SpaceSnapshot(index: 1, isVisible: false, hasFocus: true),
        SpaceSnapshot(index: 2, isVisible: true, hasFocus: false),
    ]
    // visible space 2 should win over focused space 1
    checkEqual("visible(2) > focused(1) → returns 2", SpaceIndexResolver.chooseIndex(displaySpaces: spaces, focusedSpaceIndex: nil, screenCount: 2), 2)
}

print("\n12. activeDisplaySpaceIndex — only focused, no visible")
do {
    let spaces = [
        SpaceSnapshot(index: 1, isVisible: false, hasFocus: false),
        SpaceSnapshot(index: 2, isVisible: false, hasFocus: true),
        SpaceSnapshot(index: 3, isVisible: false, hasFocus: false),
    ]
    // single screen fallback uses displayActive which picks focused
    checkEqual("single screen, no visible, hasFocus=2 → returns 2", SpaceIndexResolver.chooseIndex(displaySpaces: spaces, focusedSpaceIndex: nil, screenCount: 1), 2)
}

// MARK: - Boundary cases

print("\n13. Boundary — screenCount=0 treated as single screen")
do {
    let spaces = [SpaceSnapshot(index: 1, isVisible: true, hasFocus: true)]
    checkEqual("screenCount=0, single screen logic", SpaceIndexResolver.chooseIndex(displaySpaces: spaces, focusedSpaceIndex: nil, screenCount: 0), 1)
}

print("\n14. Boundary — many spaces, first visible wins")
do {
    let spaces = (1...10).map { i in
        SpaceSnapshot(index: i, isVisible: i == 7, hasFocus: i == 3)
    }
    checkEqual("10 spaces, space 7 visible → returns 7", SpaceIndexResolver.chooseIndex(displaySpaces: spaces, focusedSpaceIndex: nil, screenCount: 2), 7)
}

print("\n15. Boundary — many spaces, no visible, first focused wins")
do {
    let spaces = (1...10).map { i in
        SpaceSnapshot(index: i, isVisible: false, hasFocus: i == 5)
    }
    checkEqual("10 spaces, space 5 hasFocus → returns 5", SpaceIndexResolver.chooseIndex(displaySpaces: spaces, focusedSpaceIndex: nil, screenCount: 1), 5)
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
