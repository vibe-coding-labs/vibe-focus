import Testing
import Foundation
@testable import VibeFocusKit

/// overlay 每屏 space 决策纯函数锁定（与 Standalone 镜像同矩阵）：
/// 1. 快速路径（AllSpaceSnapshot 按 display 分组）与 fallback 路径（SpaceSnapshot 逐屏）
///    共用 `SpaceIndexResolvable.resolveScreenSpaceIndex`，两类型各过一遍全矩阵；
/// 2. `applyRefreshResults` 的缓存变更判定 `ScreenOverlayManager.screenCacheChange`。
@Suite("Screen Space Index Resolution")
@MainActor
struct ScreenSpaceIndexResolutionTests {

    private func perDisplay(_ index: Int, _ visible: Bool) -> SpaceSnapshot {
        SpaceSnapshot(index: index, isVisible: visible, hasFocus: false)
    }

    private func all(_ index: Int, display: Int, _ visible: Bool) -> AllSpaceSnapshot {
        AllSpaceSnapshot(index: index, display: display, isVisible: visible, hasFocus: false)
    }

    // MARK: - SpaceSnapshot（fallback 路径数据面）

    @Test("focused 命中：乱序输入按 index 升序取位次（中间位次）")
    func focusedMidPositionSorted() {
        let result = SpaceSnapshot.resolveScreenSpaceIndex(
            from: [perDisplay(3, false), perDisplay(1, false), perDisplay(2, false)],
            focusedSpaceIndex: 2)
        #expect(result == 2)
    }

    @Test("focused 命中：优先于更早位次的可见 space")
    func focusedPrecedesVisible() {
        let result = SpaceSnapshot.resolveScreenSpaceIndex(
            from: [perDisplay(1, true), perDisplay(2, false), perDisplay(3, false)],
            focusedSpaceIndex: 3)
        #expect(result == 3)
    }

    @Test("focused 为 nil：落到第一个可见 space 的位次")
    func nilFocusedFallsToVisible() {
        let result = SpaceSnapshot.resolveScreenSpaceIndex(
            from: [perDisplay(1, false), perDisplay(2, true), perDisplay(3, false)],
            focusedSpaceIndex: nil)
        #expect(result == 2)
    }

    @Test("focused 不属于本 display：落到第一个可见 space 的位次")
    func foreignFocusedFallsToVisible() {
        let result = SpaceSnapshot.resolveScreenSpaceIndex(
            from: [perDisplay(1, false), perDisplay(2, false), perDisplay(3, true)],
            focusedSpaceIndex: 9)
        #expect(result == 3)
    }

    @Test("全不可见且 focused 无匹配 → nil（调用方收敛默认 1）")
    func noMatchReturnsNil() {
        let result = SpaceSnapshot.resolveScreenSpaceIndex(
            from: [perDisplay(1, false)],
            focusedSpaceIndex: 5)
        #expect(result == nil)
    }

    @Test("空列表 → nil")
    func emptyReturnsNil() {
        #expect(SpaceSnapshot.resolveScreenSpaceIndex(from: [], focusedSpaceIndex: nil) == nil)
        #expect(SpaceSnapshot.resolveScreenSpaceIndex(from: [], focusedSpaceIndex: 3) == nil)
    }

    // MARK: - AllSpaceSnapshot（快速路径数据面，协议泛型的第二类型验证）

    @Test("AllSpaceSnapshot：focused 命中且乱序输入按 index 升序")
    func allSpacesFocusedSorted() {
        let result = AllSpaceSnapshot.resolveScreenSpaceIndex(
            from: [all(3, display: 1, false), all(1, display: 1, false), all(2, display: 1, false)],
            focusedSpaceIndex: 2)
        #expect(result == 2)
    }

    @Test("AllSpaceSnapshot：focused 优先于可见")
    func allSpacesFocusedPrecedesVisible() {
        let result = AllSpaceSnapshot.resolveScreenSpaceIndex(
            from: [all(1, display: 1, true), all(2, display: 1, false)],
            focusedSpaceIndex: 2)
        #expect(result == 2)
    }

    @Test("AllSpaceSnapshot：多个可见取位次最小者")
    func allSpacesFirstVisibleWins() {
        let result = AllSpaceSnapshot.resolveScreenSpaceIndex(
            from: [all(3, display: 1, true), all(1, display: 1, true), all(2, display: 1, false)],
            focusedSpaceIndex: nil)
        #expect(result == 1)
    }

    @Test("AllSpaceSnapshot：全不可见 → nil")
    func allSpacesNoMatchReturnsNil() {
        let result = AllSpaceSnapshot.resolveScreenSpaceIndex(
            from: [all(1, display: 1, false), all(2, display: 1, false)],
            focusedSpaceIndex: nil)
        #expect(result == nil)
    }

    // MARK: - screenCacheChange（applyRefreshResults 缓存变更判定）

    @Test("缓存缺失（新屏/首轮）：需应用，无旧值")
    func cacheMissApplies() {
        let change = ScreenOverlayManager.screenCacheChange(cached: nil, currentScreenIndex: 1, currentSpaceIndex: 3)
        #expect(change == ScreenOverlayManager.ScreenCacheChange(needsApply: true, oldSpaceIndex: nil))
    }

    @Test("与缓存完全一致：不应用（WindowServer 零干扰）")
    func unchangedSkips() {
        let change = ScreenOverlayManager.screenCacheChange(
            cached: (screenIndex: 1, spaceIndex: 3), currentScreenIndex: 1, currentSpaceIndex: 3)
        #expect(change == ScreenOverlayManager.ScreenCacheChange(needsApply: false, oldSpaceIndex: nil))
    }

    @Test("仅 spaceIndex 变化：需应用并携带旧值")
    func spaceChangeAppliesWithOldValue() {
        let change = ScreenOverlayManager.screenCacheChange(
            cached: (screenIndex: 1, spaceIndex: 2), currentScreenIndex: 1, currentSpaceIndex: 5)
        #expect(change == ScreenOverlayManager.ScreenCacheChange(needsApply: true, oldSpaceIndex: 2))
    }

    @Test("仅 screenIndex 变化（重排显示器）：需应用")
    func screenChangeApplies() {
        let change = ScreenOverlayManager.screenCacheChange(
            cached: (screenIndex: 0, spaceIndex: 3), currentScreenIndex: 1, currentSpaceIndex: 3)
        #expect(change.needsApply)
    }

    @Test("screenIndex 与 spaceIndex 同时变化：需应用")
    func bothChangeApplies() {
        let change = ScreenOverlayManager.screenCacheChange(
            cached: (screenIndex: 0, spaceIndex: 2), currentScreenIndex: 2, currentSpaceIndex: 4)
        #expect(change == ScreenOverlayManager.ScreenCacheChange(needsApply: true, oldSpaceIndex: 2))
    }
}
