// Tests/Standalone/FocusStepsCalculationTests.swift
// Verification: calculateFocusSteps — computes Ctrl+Left/Right step count to reach target space
// Mirrors: Sources/Space/SpaceController+Switch.swift:202-242
// Run: swift Tests/Standalone/FocusStepsCalculationTests.swift

import Foundation

// MARK: - Mirrored types

struct SpaceInfo: Equatable {
    let id: Int?
    let index: Int?
    let display: Int?
    let isVisible: Bool?
}

/// Mirrors SpaceController.calculateFocusSteps (SpaceController+Switch.swift:202-242)
/// Returns the number of Ctrl+Right (positive) or Ctrl+Left (negative) key presses needed.
func calculateFocusSteps(targetSpaceIndex: Int, spaces: [SpaceInfo]) -> Int {
    guard let targetSpace = spaces.first(where: { $0.index == targetSpaceIndex }) else {
        return 0
    }
    guard let displayIndex = targetSpace.display else {
        return 0
    }
    let displaySpaces = spaces
        .filter { $0.display == displayIndex }
        .sorted { ($0.index ?? 0) < ($1.index ?? 0) }

    guard let currentSpace = displaySpaces.first(where: { $0.isVisible == true }) else {
        return 0
    }
    guard let currentIdx = displaySpaces.firstIndex(where: { $0.index == currentSpace.index }) else { return 0 }
    guard let targetIdx = displaySpaces.firstIndex(where: { $0.index == targetSpaceIndex }) else { return 0 }

    return targetIdx - currentIdx
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

func checkEqual(_ name: String, _ a: Int, _ b: Int) {
    if a == b { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name) — expected \(b), got \(a)") }
}

// MARK: - Basic cases

print("1. calculateFocusSteps — target is current space → 0 steps")
do {
    let spaces = [
        SpaceInfo(id: 1, index: 1, display: 1, isVisible: true),
        SpaceInfo(id: 2, index: 2, display: 1, isVisible: false),
        SpaceInfo(id: 3, index: 3, display: 1, isVisible: false),
    ]
    checkEqual("target=1 (current) → 0", calculateFocusSteps(targetSpaceIndex: 1, spaces: spaces), 0)
}

print("\n2. calculateFocusSteps — target to the right → positive steps")
do {
    let spaces = [
        SpaceInfo(id: 1, index: 1, display: 1, isVisible: true),
        SpaceInfo(id: 2, index: 2, display: 1, isVisible: false),
        SpaceInfo(id: 3, index: 3, display: 1, isVisible: false),
    ]
    checkEqual("target=2 → +1", calculateFocusSteps(targetSpaceIndex: 2, spaces: spaces), 1)
    checkEqual("target=3 → +2", calculateFocusSteps(targetSpaceIndex: 3, spaces: spaces), 2)
}

print("\n3. calculateFocusSteps — target to the left → negative steps")
do {
    let spaces = [
        SpaceInfo(id: 1, index: 1, display: 1, isVisible: false),
        SpaceInfo(id: 2, index: 2, display: 1, isVisible: false),
        SpaceInfo(id: 3, index: 3, display: 1, isVisible: true),
    ]
    checkEqual("target=2 → -1", calculateFocusSteps(targetSpaceIndex: 2, spaces: spaces), -1)
    checkEqual("target=1 → -2", calculateFocusSteps(targetSpaceIndex: 1, spaces: spaces), -2)
}

print("\n4. calculateFocusSteps — middle space, current at start")
do {
    let spaces = [
        SpaceInfo(id: 1, index: 1, display: 1, isVisible: true),
        SpaceInfo(id: 2, index: 2, display: 1, isVisible: false),
        SpaceInfo(id: 3, index: 3, display: 1, isVisible: false),
        SpaceInfo(id: 4, index: 4, display: 1, isVisible: false),
    ]
    checkEqual("target=3 → +2", calculateFocusSteps(targetSpaceIndex: 3, spaces: spaces), 2)
    checkEqual("target=4 → +3", calculateFocusSteps(targetSpaceIndex: 4, spaces: spaces), 3)
}

print("\n5. calculateFocusSteps — multi-display filters to same display only")
do {
    let spaces = [
        SpaceInfo(id: 1, index: 1, display: 1, isVisible: true),
        SpaceInfo(id: 2, index: 2, display: 1, isVisible: false),
        SpaceInfo(id: 3, index: 3, display: 2, isVisible: true),
        SpaceInfo(id: 4, index: 4, display: 2, isVisible: false),
    ]
    // Target space 2 on display 1, current visible on display 1 is space 1
    checkEqual("display 1: target=2 → +1", calculateFocusSteps(targetSpaceIndex: 2, spaces: spaces), 1)
    // Target space 4 on display 2, current visible on display 2 is space 3
    checkEqual("display 2: target=4 → +1", calculateFocusSteps(targetSpaceIndex: 4, spaces: spaces), 1)
}

print("\n6. calculateFocusSteps — target space not in list → 0")
do {
    let spaces = [
        SpaceInfo(id: 1, index: 1, display: 1, isVisible: true),
    ]
    checkEqual("target=99 not found → 0", calculateFocusSteps(targetSpaceIndex: 99, spaces: spaces), 0)
}

print("\n7. calculateFocusSteps — empty spaces → 0")
do {
    checkEqual("empty spaces → 0", calculateFocusSteps(targetSpaceIndex: 1, spaces: []), 0)
}

print("\n8. calculateFocusSteps — target has no display → 0")
do {
    let spaces = [
        SpaceInfo(id: 1, index: 1, display: nil, isVisible: true),
    ]
    checkEqual("nil display → 0", calculateFocusSteps(targetSpaceIndex: 1, spaces: spaces), 0)
}

print("\n9. calculateFocusSteps — no visible space on display → 0")
do {
    let spaces = [
        SpaceInfo(id: 1, index: 1, display: 1, isVisible: false),
        SpaceInfo(id: 2, index: 2, display: 1, isVisible: false),
    ]
    checkEqual("no visible space → 0", calculateFocusSteps(targetSpaceIndex: 2, spaces: spaces), 0)
}

print("\n10. calculateFocusSteps — unsorted spaces sorted by index")
do {
    let spaces = [
        SpaceInfo(id: 3, index: 3, display: 1, isVisible: false),
        SpaceInfo(id: 1, index: 1, display: 1, isVisible: true),
        SpaceInfo(id: 2, index: 2, display: 1, isVisible: false),
    ]
    // Sorted: [1(vis), 2, 3]. Current=1, target=3 → +2
    checkEqual("unsorted: target=3 from 1 → +2", calculateFocusSteps(targetSpaceIndex: 3, spaces: spaces), 2)
}

print("\n11. calculateFocusSteps — spaces with nil index sorted to front (index=0)")
do {
    let spaces = [
        SpaceInfo(id: 1, index: nil, display: 1, isVisible: false),
        SpaceInfo(id: 2, index: 2, display: 1, isVisible: true),
        SpaceInfo(id: 3, index: 3, display: 1, isVisible: false),
    ]
    // Sorted by (index ?? 0): [nil(0), 2, 3]. Current visible is space 2 at idx 1, target=3 → +1
    checkEqual("nil index space: target=3 from 2 → +1", calculateFocusSteps(targetSpaceIndex: 3, spaces: spaces), 1)
}

print("\n12. calculateFocusSteps — single space display → 0")
do {
    let spaces = [
        SpaceInfo(id: 1, index: 1, display: 1, isVisible: true),
    ]
    checkEqual("only space, already visible → 0", calculateFocusSteps(targetSpaceIndex: 1, spaces: spaces), 0)
}

print("\n13. calculateFocusSteps — large step count")
do {
    var spaces: [SpaceInfo] = []
    for i in 1...10 {
        spaces.append(SpaceInfo(id: i, index: i, display: 1, isVisible: i == 1))
    }
    checkEqual("target=10 from 1 → +9", calculateFocusSteps(targetSpaceIndex: 10, spaces: spaces), 9)
    checkEqual("target=1 from 1 → 0", calculateFocusSteps(targetSpaceIndex: 1, spaces: spaces), 0)
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
