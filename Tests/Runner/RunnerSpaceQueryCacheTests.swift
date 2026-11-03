import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerSpaceQueryCacheTests.swift — 覆盖率批次（2026-11-03）：
// SpaceController 查询缓存的命中/过期判定（querySpaces / queryWindow）。
//
// 背景：CI 无 yabai，所有真实查询都失败，缓存命中分支（正常机器上才走）从无覆盖。
// 这里直接注入缓存条目（internal 缝）驱动命中分支，零 fork、零窗口读写。
//
// 安全边界：仅内存缓存注入 + 只读查询；结束后原样还原两个缓存槽。

extension RunnerHarness {

    func runSpaceQueryCacheTests() {
        print("\n=== SpaceQueryCache ===")
        let controller = SpaceController.shared
        let savedSpaces = controller.spacesQueryCache
        let savedWindows = controller.windowQueryCache
        defer {
            controller.spacesQueryCache = savedSpaces
            controller.windowQueryCache = savedWindows
        }

        // MARK: A. querySpaces：新鲜缓存命中（不 fork）
        do {
            controller.spacesQueryCache = (result: [], cachedAt: Date())
            let hit = controller.querySpaces(caller: "unit-cache-hit")
            check("spaceCache: 新鲜 spaces 缓存命中直接返回", hit?.isEmpty == true)
        }

        // MARK: B. querySpaces：过期缓存→直查（结果随环境：CI 失败 / 真机成功）
        do {
            let staleAt = Date().addingTimeInterval(-30)
            controller.spacesQueryCache = (result: [], cachedAt: staleAt)
            check("spaceCache: 30s 前条目判定为过期", controller.isCacheExpired(staleAt))
            let refreshed = controller.querySpaces(caller: "unit-cache-expired")
            if refreshed == nil {
                // 失败分支不覆盖缓存（负缓存 bug 回归锁）：槽里仍是旧条目
                check("spaceCache: 查询失败不回写负缓存",
                      controller.spacesQueryCache?.cachedAt == staleAt)
            } else {
                check("spaceCache: 查询成功回写新鲜缓存",
                      controller.spacesQueryCache.map { !controller.isCacheExpired($0.cachedAt) } == true)
            }
        }

        // MARK: C. queryWindow：新鲜窗口缓存命中（含 nil 结果的负缓存）
        do {
            controller.windowQueryCache[4_200_042] = (result: nil, cachedAt: Date())
            check("spaceCache: 新鲜 window 缓存（nil）命中",
                  controller.queryWindow(windowID: 4_200_042) == nil)
            controller.windowQueryCache[4_200_043] = (result: nil, cachedAt: Date())
            controller.clearWindowQueryCache()
            check("spaceCache: 清窗口缓存后条目清空",
                  !controller.windowQueryCache.keys.contains(4_200_043))
            controller.spacesQueryCache = (result: [], cachedAt: Date())
            controller.clearQueryCache()
            check("spaceCache: 全量清缓存清空两槽",
                  controller.spacesQueryCache == nil && controller.windowQueryCache.isEmpty)
        }
    }
}
