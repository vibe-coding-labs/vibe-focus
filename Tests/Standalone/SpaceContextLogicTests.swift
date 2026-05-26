// Tests/Standalone/SpaceContextLogicTests.swift
// Verification: SpaceController context computation — displayLocalSpaceIndex,
//               preferredSourceSpace, headerValue case-insensitive lookup
// Mirrors: Sources/Space/SpaceController+Context.swift:56-128, Sources/Hook/ClaudeHookServer.swift:210-217
// Run: swift Tests/Standalone/SpaceContextLogicTests.swift

import Foundation

// MARK: - Mirrored types and functions

struct YabaiSpaceInfo: Equatable {
    let id: Int?
    let index: Int?
    let display: Int?
}

/// Mirrors SpaceController.displayLocalSpaceIndex (SpaceController+Context.swift:56-94)
/// Computes the 1-based local space index for a given global yabai space index on a display.
func displayLocalSpaceIndex(forGlobalSpaceIndex spaceIndex: Int?, displayIndex: Int?, spaces: [YabaiSpaceInfo]?) -> Int? {
    guard let spaceIndex, let displayIndex else { return nil }
    guard let spaces else { return nil }

    let spacesOnDisplay = spaces
        .filter { $0.display == displayIndex }
        .sorted { ($0.index ?? Int.max) < ($1.index ?? Int.max) }

    for (offset, info) in spacesOnDisplay.enumerated() {
        if info.index == spaceIndex {
            return offset + 1
        }
    }
    return nil
}

/// Mirrors SpaceController.preferredSourceSpace (SpaceController+Context.swift:122-128)
func preferredSourceSpace(windowSpace: Int?, visibleSpace: Int?, fallbackSpace: Int?) -> Int? {
    if let windowSpace, let visibleSpace, windowSpace != visibleSpace {
        return windowSpace
    }
    return windowSpace ?? visibleSpace ?? fallbackSpace
}

/// Mirrors ClaudeHookServer.headerValue (ClaudeHookServer.swift:210-217)
func headerValue(from headers: [String: String], forKey key: String) -> String? {
    if let value = headers[key] { return value }
    let lowerKey = key.lowercased()
    for (k, v) in headers where k.lowercased() == lowerKey {
        return v
    }
    return nil
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

func checkEqual<T: Equatable>(_ name: String, _ a: T, _ b: T) {
    if a == b { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name) — expected \(b), got \(a)") }
}

// MARK: - displayLocalSpaceIndex

print("1. displayLocalSpaceIndex — nil inputs return nil")
do {
    check("nil spaceIndex → nil", displayLocalSpaceIndex(forGlobalSpaceIndex: nil, displayIndex: 1, spaces: []) == nil)
    check("nil displayIndex → nil", displayLocalSpaceIndex(forGlobalSpaceIndex: 1, displayIndex: nil, spaces: []) == nil)
    check("nil spaces → nil", displayLocalSpaceIndex(forGlobalSpaceIndex: 1, displayIndex: 1, spaces: nil) == nil)
    check("all nil → nil", displayLocalSpaceIndex(forGlobalSpaceIndex: nil, displayIndex: nil, spaces: nil) == nil)
}

print("\n2. displayLocalSpaceIndex — single display, single space")
do {
    let spaces = [YabaiSpaceInfo(id: 1, index: 1, display: 1)]
    checkEqual("space 1 on display 1 → local 1", displayLocalSpaceIndex(forGlobalSpaceIndex: 1, displayIndex: 1, spaces: spaces), 1)
}

print("\n3. displayLocalSpaceIndex — single display, multiple spaces")
do {
    let spaces = [
        YabaiSpaceInfo(id: 1, index: 1, display: 1),
        YabaiSpaceInfo(id: 2, index: 2, display: 1),
        YabaiSpaceInfo(id: 3, index: 3, display: 1),
    ]
    checkEqual("space 1 → local 1", displayLocalSpaceIndex(forGlobalSpaceIndex: 1, displayIndex: 1, spaces: spaces), 1)
    checkEqual("space 2 → local 2", displayLocalSpaceIndex(forGlobalSpaceIndex: 2, displayIndex: 1, spaces: spaces), 2)
    checkEqual("space 3 → local 3", displayLocalSpaceIndex(forGlobalSpaceIndex: 3, displayIndex: 1, spaces: spaces), 3)
}

print("\n4. displayLocalSpaceIndex — multi-display, spaces filtered by display")
do {
    let spaces = [
        YabaiSpaceInfo(id: 1, index: 1, display: 1),
        YabaiSpaceInfo(id: 2, index: 2, display: 1),
        YabaiSpaceInfo(id: 3, index: 3, display: 2),
        YabaiSpaceInfo(id: 4, index: 4, display: 2),
    ]
    checkEqual("display 1, space 1 → local 1", displayLocalSpaceIndex(forGlobalSpaceIndex: 1, displayIndex: 1, spaces: spaces), 1)
    checkEqual("display 1, space 2 → local 2", displayLocalSpaceIndex(forGlobalSpaceIndex: 2, displayIndex: 1, spaces: spaces), 2)
    checkEqual("display 2, space 3 → local 1", displayLocalSpaceIndex(forGlobalSpaceIndex: 3, displayIndex: 2, spaces: spaces), 1)
    checkEqual("display 2, space 4 → local 2", displayLocalSpaceIndex(forGlobalSpaceIndex: 4, displayIndex: 2, spaces: spaces), 2)
}

print("\n5. displayLocalSpaceIndex — space not on specified display → nil")
do {
    let spaces = [
        YabaiSpaceInfo(id: 1, index: 1, display: 1),
        YabaiSpaceInfo(id: 3, index: 3, display: 2),
    ]
    check("space 3 not on display 1 → nil", displayLocalSpaceIndex(forGlobalSpaceIndex: 3, displayIndex: 1, spaces: spaces) == nil)
    check("space 1 not on display 2 → nil", displayLocalSpaceIndex(forGlobalSpaceIndex: 1, displayIndex: 2, spaces: spaces) == nil)
}

print("\n6. displayLocalSpaceIndex — space index not found → nil")
do {
    let spaces = [YabaiSpaceInfo(id: 1, index: 1, display: 1)]
    check("space 99 not found → nil", displayLocalSpaceIndex(forGlobalSpaceIndex: 99, displayIndex: 1, spaces: spaces) == nil)
}

print("\n7. displayLocalSpaceIndex — unsorted spaces are sorted by index")
do {
    let spaces = [
        YabaiSpaceInfo(id: 3, index: 3, display: 1),
        YabaiSpaceInfo(id: 1, index: 1, display: 1),
        YabaiSpaceInfo(id: 2, index: 2, display: 1),
    ]
    checkEqual("space 1 → local 1 (after sort)", displayLocalSpaceIndex(forGlobalSpaceIndex: 1, displayIndex: 1, spaces: spaces), 1)
    checkEqual("space 3 → local 3 (after sort)", displayLocalSpaceIndex(forGlobalSpaceIndex: 3, displayIndex: 1, spaces: spaces), 3)
}

print("\n8. displayLocalSpaceIndex — spaces with nil index handled")
do {
    let spaces = [
        YabaiSpaceInfo(id: 1, index: nil, display: 1),
        YabaiSpaceInfo(id: 2, index: 2, display: 1),
    ]
    // nil index spaces sort as Int.max, so they go to end
    checkEqual("space 2 → local 1 (nil index sorted to end)", displayLocalSpaceIndex(forGlobalSpaceIndex: 2, displayIndex: 1, spaces: spaces), 1)
}

print("\n9. displayLocalSpaceIndex — empty spaces array → nil")
do {
    check("empty array → nil", displayLocalSpaceIndex(forGlobalSpaceIndex: 1, displayIndex: 1, spaces: []) == nil)
}

// MARK: - preferredSourceSpace

print("\n10. preferredSourceSpace — both nil, uses fallback")
do {
    checkEqual("all nil → nil", preferredSourceSpace(windowSpace: nil, visibleSpace: nil, fallbackSpace: nil), nil)
    checkEqual("nil window+visible, fallback 5 → 5", preferredSourceSpace(windowSpace: nil, visibleSpace: nil, fallbackSpace: 5), 5)
}

print("\n11. preferredSourceSpace — windowSpace only")
do {
    checkEqual("windowSpace=3 → 3", preferredSourceSpace(windowSpace: 3, visibleSpace: nil, fallbackSpace: nil), 3)
}

print("\n12. preferredSourceSpace — visibleSpace only")
do {
    checkEqual("visibleSpace=2 → 2", preferredSourceSpace(windowSpace: nil, visibleSpace: 2, fallbackSpace: nil), 2)
}

print("\n13. preferredSourceSpace — window and visible match")
do {
    checkEqual("window=3, visible=3 → 3", preferredSourceSpace(windowSpace: 3, visibleSpace: 3, fallbackSpace: nil), 3)
    // When they match, falls through to `windowSpace ?? visibleSpace ?? fallbackSpace` → returns windowSpace
}

print("\n14. preferredSourceSpace — window and visible differ → prefers windowSpace")
do {
    checkEqual("window=5, visible=3 → 5 (mismatch uses window)", preferredSourceSpace(windowSpace: 5, visibleSpace: 3, fallbackSpace: nil), 5)
    checkEqual("window=1, visible=2 → 1 (mismatch uses window)", preferredSourceSpace(windowSpace: 1, visibleSpace: 2, fallbackSpace: 10), 1)
}

print("\n15. preferredSourceSpace — priority chain")
do {
    // windowSpace > visibleSpace > fallbackSpace
    checkEqual("window=3, visible=2, fallback=1 → 3", preferredSourceSpace(windowSpace: 3, visibleSpace: 2, fallbackSpace: 1), 3)
    checkEqual("nil, visible=2, fallback=1 → 2", preferredSourceSpace(windowSpace: nil, visibleSpace: 2, fallbackSpace: 1), 2)
    checkEqual("nil, nil, fallback=1 → 1", preferredSourceSpace(windowSpace: nil, visibleSpace: nil, fallbackSpace: 1), 1)
}

// MARK: - headerValue

print("\n16. headerValue — exact key match")
do {
    let headers = ["X-VibeFocus-Token": "abc123", "Content-Type": "application/json"]
    checkEqual("exact match", headerValue(from: headers, forKey: "X-VibeFocus-Token"), "abc123")
    checkEqual("exact match content-type", headerValue(from: headers, forKey: "Content-Type"), "application/json")
}

print("\n17. headerValue — case-insensitive fallback")
do {
    let headers = ["X-VibeFocus-Token": "abc123"]
    checkEqual("lowercase key", headerValue(from: headers, forKey: "x-vibefocus-token"), "abc123")
    checkEqual("mixed case", headerValue(from: headers, forKey: "x-VibeFocus-TOKEN"), "abc123")
}

print("\n18. headerValue — key not present")
do {
    let headers = ["Content-Type": "application/json"]
    check("missing key → nil", headerValue(from: headers, forKey: "X-VibeFocus-Token") == nil)
}

print("\n19. headerValue — empty headers")
do {
    check("empty dict → nil", headerValue(from: [:], forKey: "any") == nil)
}

print("\n20. headerValue — empty key")
do {
    let headers = ["": "empty-key-value"]
    checkEqual("empty key matches empty key", headerValue(from: headers, forKey: ""), "empty-key-value")
}

print("\n21. headerValue — exact match takes priority over case-insensitive")
do {
    // If exact key exists, return it without scanning
    let headers = ["Key": "exact", "key": "lower"]
    checkEqual("exact key wins", headerValue(from: headers, forKey: "Key"), "exact")
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
