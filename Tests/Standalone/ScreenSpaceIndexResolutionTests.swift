// Tests/Standalone/ScreenSpaceIndexResolutionTests.swift
// Verification: overlay 每屏 space 决策纯函数（可见 space 解析 + 缓存变更判定）
// Mirrors: Sources/Overlay/SpaceSnapshot.swift SpaceIndexResolvable.resolveScreenSpaceIndex
//          Sources/Overlay/ScreenOverlayManager+Refresh.swift screenCacheChange
// Run: swift Tests/Standalone/ScreenSpaceIndexResolutionTests.swift

import Foundation

// MARK: - Mirror (与源码同步维护；Swift Testing 版在 Tests/XCTest/ScreenSpaceIndexResolutionTests.swift)

struct SpaceIndexResolvableMirror {
    let index: Int
    let isVisible: Bool
}

enum SpaceIndexResolutionMirror {

    static func resolveScreenSpaceIndex(from spaces: [SpaceIndexResolvableMirror], focusedSpaceIndex: Int?) -> Int? {
        let sorted = spaces.sorted { $0.index < $1.index }
        if let focused = focusedSpaceIndex,
           let position = sorted.firstIndex(where: { $0.index == focused }) {
            return position + 1
        }
        if let position = sorted.firstIndex(where: { $0.isVisible }) {
            return position + 1
        }
        return nil
    }
}

struct ScreenCacheChangeMirror: Equatable {
    let needsApply: Bool
    let oldSpaceIndex: Int?
}

func screenCacheChange(
    cached: (screenIndex: Int, spaceIndex: Int)?,
    currentScreenIndex: Int,
    currentSpaceIndex: Int
) -> ScreenCacheChangeMirror {
    guard let cached else {
        return .init(needsApply: true, oldSpaceIndex: nil)
    }
    if cached.screenIndex == currentScreenIndex, cached.spaceIndex == currentSpaceIndex {
        return .init(needsApply: false, oldSpaceIndex: nil)
    }
    return .init(needsApply: true, oldSpaceIndex: cached.spaceIndex)
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

func space(_ index: Int, _ visible: Bool) -> SpaceIndexResolvableMirror {
    SpaceIndexResolvableMirror(index: index, isVisible: visible)
}

// MARK: - focused 命中分支

check("focused 命中：乱序输入按 index 升序取位次（中间位次）",
      SpaceIndexResolutionMirror.resolveScreenSpaceIndex(
        from: [space(3, false), space(1, false), space(2, false)],
        focusedSpaceIndex: 2) == 2)

check("focused 命中：优先于更早位次的可见 space",
      SpaceIndexResolutionMirror.resolveScreenSpaceIndex(
        from: [space(1, true), space(2, false), space(3, false)],
        focusedSpaceIndex: 3) == 3)

check("focused 命中：第 1 位边界",
      SpaceIndexResolutionMirror.resolveScreenSpaceIndex(
        from: [space(1, false), space(2, false)],
        focusedSpaceIndex: 1) == 1)

// MARK: - focused 未命中/缺失分支

check("focused 为 nil：落到第一个可见 space 的位次",
      SpaceIndexResolutionMirror.resolveScreenSpaceIndex(
        from: [space(1, false), space(2, true), space(3, false)],
        focusedSpaceIndex: nil) == 2)

check("focused 不属于本 display：落到第一个可见 space 的位次",
      SpaceIndexResolutionMirror.resolveScreenSpaceIndex(
        from: [space(1, false), space(2, false), space(3, true)],
        focusedSpaceIndex: 9) == 3)

check("多个可见：取升序位次最小者",
      SpaceIndexResolutionMirror.resolveScreenSpaceIndex(
        from: [space(3, true), space(1, true), space(2, false)],
        focusedSpaceIndex: nil) == 1)

check("focused 为 nil 且可见在第 1 位",
      SpaceIndexResolutionMirror.resolveScreenSpaceIndex(
        from: [space(1, true), space(2, false)],
        focusedSpaceIndex: nil) == 1)

// MARK: - 无解分支（nil，调用方按契约收敛为 1）

check("全不可见且 focused 为 nil → nil",
      SpaceIndexResolutionMirror.resolveScreenSpaceIndex(
        from: [space(1, false), space(2, false)],
        focusedSpaceIndex: nil) == nil)

check("全不可见且 focused 无匹配 → nil",
      SpaceIndexResolutionMirror.resolveScreenSpaceIndex(
        from: [space(1, false)],
        focusedSpaceIndex: 5) == nil)

check("空列表且 focused 为 nil → nil",
      SpaceIndexResolutionMirror.resolveScreenSpaceIndex(
        from: [],
        focusedSpaceIndex: nil) == nil)

check("空列表且 focused 非nil → nil",
      SpaceIndexResolutionMirror.resolveScreenSpaceIndex(
        from: [],
        focusedSpaceIndex: 3) == nil)

// MARK: - screenCacheChange（applyRefreshResults 缓存变更判定）

check("缓存缺失（新屏/首轮）：需应用，无旧值",
      screenCacheChange(cached: nil, currentScreenIndex: 1, currentSpaceIndex: 3)
        == ScreenCacheChangeMirror(needsApply: true, oldSpaceIndex: nil))

check("与缓存完全一致：不应用（WindowServer 零干扰）",
      screenCacheChange(cached: (screenIndex: 1, spaceIndex: 3), currentScreenIndex: 1, currentSpaceIndex: 3)
        == ScreenCacheChangeMirror(needsApply: false, oldSpaceIndex: nil))

check("仅 spaceIndex 变化：需应用并携带旧值",
      screenCacheChange(cached: (screenIndex: 1, spaceIndex: 2), currentScreenIndex: 1, currentSpaceIndex: 5)
        == ScreenCacheChangeMirror(needsApply: true, oldSpaceIndex: 2))

check("仅 screenIndex 变化（重排显示器）：需应用",
      screenCacheChange(cached: (screenIndex: 0, spaceIndex: 3), currentScreenIndex: 1, currentSpaceIndex: 3)
        .needsApply)

check("screenIndex 与 spaceIndex 同时变化：需应用",
      screenCacheChange(cached: (screenIndex: 0, spaceIndex: 2), currentScreenIndex: 2, currentSpaceIndex: 4)
        == ScreenCacheChangeMirror(needsApply: true, oldSpaceIndex: 2))

// MARK: - Summary

print("\nScreenSpaceIndexResolutionTests: \(passed + failed) checks, \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
