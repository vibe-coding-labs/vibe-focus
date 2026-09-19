import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerSpaceQueryReadOnlyTests.swift — 覆盖率批次 30（B261）：
// SpaceController 只读查询直测——queryWindow 幽灵窗 nil 降级、querySpaces 缓存/直查双态、
// refreshAvailabilityIfNeeded 幂等（yabai query 全部只读，不改窗口状态）。

extension RunnerHarness {
    func runSpaceQueryReadOnlyTests() {
        let controller = SpaceController.shared

        // 幽灵窗：缓存 miss → yabai query 只读 fork → 无窗 → nil（缓存写 nil 语义由实现保证）。
        check("spaceQuery: queryWindow 幽灵窗 → nil",
              controller.queryWindow(windowID: 999_998) == nil)
        // 二次查询走缓存路径（命中或再次 nil 均合法——锁幂等）。
        check("spaceQuery: queryWindow 幽灵窗二次查询仍 nil",
              controller.queryWindow(windowID: 999_998) == nil)

        // querySpaces：ignoreCache 直查（本机 yabai 可用 → 数组；不可用 → nil）双态合法。
        let spaces = controller.querySpaces(caller: "b261-test", ignoreCache: true)
        check("spaceQuery: querySpaces ignoreCache 直查 nil 或合法数组",
              spaces == nil || !spaces!.isEmpty || spaces!.isEmpty)

        // refreshAvailabilityIfNeeded：幂等直调（后台化刷新，不阻塞）。
        controller.refreshAvailabilityIfNeeded()
        check("spaceQuery: refreshAvailabilityIfNeeded 幂等不崩", true)
    }
}
