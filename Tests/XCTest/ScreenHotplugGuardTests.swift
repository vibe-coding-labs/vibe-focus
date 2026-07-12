// Tests/XCTest/ScreenHotplugGuardTests.swift
// Verification: ScreenHotplugGuard — 屏幕热插拔 race 守卫纯函数
// Sources: Sources/Overlay/ScreenHotplugGuard.swift
// Run: swift test --filter ScreenHotplugGuardTests
//
// 测真实的 VibeFocusKit.ScreenHotplugGuard 纯函数（非镜像），捕获未来对热插拔
// 一致性判定逻辑的回归。不实例化 ScreenOverlayManager.shared（避免经生产 singleton
// 污染生产 SQLite —— feedback_prefs_persistence_fix 坑4 task#26）。

import Testing
import Foundation
@testable import VibeFocusKit

@Suite("ScreenHotplugGuard")
struct ScreenHotplugGuardTests {

    // MARK: - identityMatches

    @Test("相同 UUID 集合 → 放行（稳态切屏常态）")
    func identityMatches_sameSet() {
        let uuids: Set<UUID> = [UUID(), UUID(), UUID()]
        #expect(ScreenHotplugGuard.identityMatches(preUUIDs: uuids, currentUUIDs: uuids))
    }

    @Test("顺序不同但元素相同 → 放行（屏幕重排，index 仍可安全复用）")
    func identityMatches_reordered() {
        let a = UUID(), b = UUID(), c = UUID()
        #expect(ScreenHotplugGuard.identityMatches(preUUIDs: [a, b, c], currentUUIDs: [c, a, b]))
    }

    @Test("屏幕拔出 → 丢弃（后台 Task 期间减少显示器）")
    func identityMatches_screenRemoved() {
        #expect(!ScreenHotplugGuard.identityMatches(preUUIDs: [UUID(), UUID()], currentUUIDs: [UUID()]))
    }

    @Test("屏幕插入 → 丢弃（后台 Task 期间增加显示器）")
    func identityMatches_screenAdded() {
        #expect(!ScreenHotplugGuard.identityMatches(preUUIDs: [UUID()], currentUUIDs: [UUID(), UUID()]))
    }

    @Test("数量相同但替换屏幕 → 丢弃（换屏）")
    func identityMatches_screenReplaced() {
        #expect(!ScreenHotplugGuard.identityMatches(preUUIDs: [UUID(), UUID()], currentUUIDs: [UUID(), UUID()]))
    }

    @Test("空集合 → 放行")
    func identityMatches_empty() {
        #expect(ScreenHotplugGuard.identityMatches(preUUIDs: [], currentUUIDs: []))
    }

    // MARK: - filterStale

    @Test("全部存活 → 不过滤")
    func filterStale_allLive() {
        let u1 = UUID(), u2 = UUID()
        let results: [(index: Int, uuid: UUID, displayIndex: Int?, spaceIndex: Int?)] = [
            (index: 0, uuid: u1, displayIndex: 1, spaceIndex: 1),
            (index: 1, uuid: u2, displayIndex: 2, spaceIndex: 2)
        ]
        let filtered = ScreenHotplugGuard.filterStale(results, liveUUIDs: [u1, u2])
        #expect(filtered.count == 2)
    }

    @Test("部分屏幕消失 → 剔除过期条目")
    func filterStale_partialStale() {
        let u1 = UUID(), u2 = UUID()
        let results: [(index: Int, uuid: UUID, displayIndex: Int?, spaceIndex: Int?)] = [
            (index: 0, uuid: u1, displayIndex: 1, spaceIndex: 1),
            (index: 1, uuid: u2, displayIndex: 2, spaceIndex: 2)
        ]
        let filtered = ScreenHotplugGuard.filterStale(results, liveUUIDs: [u1])
        #expect(filtered.count == 1)
        #expect(filtered[0].uuid == u1)
    }

    @Test("全部过期 → 返回空")
    func filterStale_allStale() {
        let results: [(index: Int, uuid: UUID, displayIndex: Int?, spaceIndex: Int?)] = [
            (index: 0, uuid: UUID(), displayIndex: 1, spaceIndex: 1),
            (index: 1, uuid: UUID(), displayIndex: 2, spaceIndex: 2)
        ]
        let filtered = ScreenHotplugGuard.filterStale(results, liveUUIDs: [UUID(), UUID(), UUID()])
        #expect(filtered.isEmpty)
    }
}
