import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerSpaceIndexTests.swift — B65：Space 域零覆盖纯判定直测。
// resolveVisibleSpaceIndex 自几何精确收口起在源码注释声明 "extracted for testability"，
// 但从未有测试消费——本文件补上该欠账；visibleSpaceIndex 编排壳的查询 IO 归真机 E2E。

extension RunnerHarness {
    func runSpaceIndexTests() {
        // ===== resolveVisibleSpaceIndex：display → 可见 space（分支穷尽） =====
        func space(_ index: Int?, _ display: Int?, _ visible: Bool?) -> YabaiSpaceInfo {
            YabaiSpaceInfo(id: nil, index: index, display: display, isVisible: visible)
        }

        do {
            // 分支：displayIndex 缺失 → nil（有可见 space 也不救）
            check("spaceIdx: displayIndex nil → nil",
                  SpaceController.resolveVisibleSpaceIndex(displayIndex: nil, spaces: [space(1, 1, true)]) == nil)
            // 分支：spaces 查询失败（nil）→ nil
            check("spaceIdx: spaces nil → nil",
                  SpaceController.resolveVisibleSpaceIndex(displayIndex: 1, spaces: nil) == nil)
            // 分支：空数组 → nil
            check("spaceIdx: 空数组 → nil",
                  SpaceController.resolveVisibleSpaceIndex(displayIndex: 1, spaces: []) == nil)
            // 命中：目标 display 上的可见 space → .yabai(index)
            check("spaceIdx: 目标屏可见 space → .yabai(index)",
                  SpaceController.resolveVisibleSpaceIndex(
                    displayIndex: 2,
                    spaces: [space(1, 1, true), space(5, 2, true)]
                  ) == SpaceIdentifier.yabai(5))
            // 过滤：目标屏存在但不可见
            check("spaceIdx: 目标屏不可见 → nil",
                  SpaceController.resolveVisibleSpaceIndex(
                    displayIndex: 1, spaces: [space(1, 1, false)]) == nil)
            // 过滤：可见但在别的屏
            check("spaceIdx: 可见但在其它屏 → nil",
                  SpaceController.resolveVisibleSpaceIndex(
                    displayIndex: 2, spaces: [space(1, 1, true)]) == nil)
            // 过滤：space 自身 display 缺失（nil）不与任何 displayIndex 相等
            check("spaceIdx: space display 缺失 → 不命中",
                  SpaceController.resolveVisibleSpaceIndex(
                    displayIndex: 1, spaces: [space(3, nil, true)]) == nil)
            // 过滤：is-visible 缺失（nil）≠ true
            check("spaceIdx: is-visible 缺失 → 视为不可见",
                  SpaceController.resolveVisibleSpaceIndex(
                    displayIndex: 1, spaces: [space(3, 1, nil)]) == nil)
            // 首命中语义：数组序在前者胜
            check("spaceIdx: 多个可见取首命中",
                  SpaceController.resolveVisibleSpaceIndex(
                    displayIndex: 1,
                    spaces: [space(7, 1, true), space(9, 1, true)]
                  ) == SpaceIdentifier.yabai(7))
            // 首命中 index 缺失 → nil（不回退找下一个可见项——锁 first(where:)+map 的既有语义）
            check("spaceIdx: 首命中 index 缺失 → nil（不回退）",
                  SpaceController.resolveVisibleSpaceIndex(
                    displayIndex: 1,
                    spaces: [space(nil, 1, true), space(9, 1, true)]
                  ) == nil)
        }
    }
}
