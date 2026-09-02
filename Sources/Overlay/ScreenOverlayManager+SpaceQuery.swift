import AppKit
import SwiftUI
import Foundation

// MARK: - Space Index I/O 查询层（async，后台执行）
// 本文件只做 yabai fork 与 JSON 解析，不做 UI/状态变更。刷新编排见
// ScreenOverlayManager+Refresh.swift。所有函数均为 async，必须在 Task 中调用，
// 禁止在主线程同步等待（WindowServer 繁忙时单次 query 可达 2s）。

extension ScreenOverlayManager {

    /// 解析 yabai 可执行文件路径：优先用户自定义路径，其次系统 PATH 探测。
    ///
    /// ## 场景
    /// - `getPerScreenSpaceIndexAsync` 与信号注册（`registerYabaiSignals`）入口处调用；
    /// - 自定义路径每次都 stat 检查存在性——用户可能在设置里改路径后不重启 app。
    func getYabaiPath() -> String? {
        if let customPath = preferences.yabaiPath,
           !customPath.isEmpty,
           FileManager.default.fileExists(atPath: customPath) {
            return customPath
        }
        return YabaiClient.yabaiPath()
    }

    /// 后台：查询单 screen 的 space index。不访问 @MainActor 状态，所有 fork 在后台队列。
    /// 返回 (displayIndex, spaceIndex)——displayIndex 可能是新解析出的，调用方在主线程回写 cache。
    ///
    /// ## 场景
    /// - refreshSpaceIndices 的 fallback 路径（displayIndex 未全缓存或全量查询失败）逐屏调用；
    /// - spaceIndex 计算：focused space 在该 display 的位次 > 第一个可见 space > 默认 1。
    func getPerScreenSpaceIndexAsync(
        displayID: UInt32,
        cachedDisplayIndex: Int?,
        focusedSpaceIndex: Int?
    ) async -> (displayIndex: Int?, spaceIndex: Int?) {
        guard getYabaiPath() != nil else { return (nil, nil) }

        let displayIndex: Int?
        if let cached = cachedDisplayIndex {
            displayIndex = cached
        } else {
            displayIndex = await queryDisplayIndexAsync(displayID: displayID)
        }
        guard let displayIndex else { return (nil, nil) }

        guard let displaySpaces = await queryYabaiSpacesAsync(forDisplayIndex: displayIndex),
              !displaySpaces.isEmpty else {
            return (displayIndex, nil)
        }

        // 位次裁决统一走 resolveScreenSpaceIndex（focused 位次 > 第一个可见 > 默认 1）。
        return (displayIndex, SpaceSnapshot.resolveScreenSpaceIndex(
            from: displaySpaces,
            focusedSpaceIndex: focusedSpaceIndex
        ) ?? 1)
    }

    /// 后台：查询单 display 的 space 列表。
    ///
    /// ## 样例
    /// `yabai -m query --spaces --display 1` → 见 `Tests/Fixtures/yabai-spaces-two-displays.json`
    /// 中 `display == 1` 的条目；解析规则见 `SpaceSnapshot.parse(from:)`。
    func queryYabaiSpacesAsync(forDisplayIndex displayIndex: Int) async -> [SpaceSnapshot]? {
        guard let result = await YabaiClient.runAsync(arguments: ["-m", "query", "--spaces", "--display", "\(displayIndex)"]),
              result.exitCode == 0 else {
            log("queryYabaiSpacesAsync: yabai query failed")
            return nil
        }
        guard let data = result.stdout.data(using: .utf8),
              let jsonArray = AllSpaceSnapshot.parseJSONArray(data) else {
            log("queryYabaiSpacesAsync: failed to parse yabai spaces JSON")
            return nil
        }
        return SpaceSnapshot.parse(from: jsonArray)
    }

    /// 后台：查询当前有焦点的 space 的 yabai 全局 index。
    ///
    /// ## 场景
    /// - fallback 路径调用一次，作为 `getPerScreenSpaceIndexAsync` 的定位锚点；
    /// - 注意返回的是 yabai 全局 space index（跨 display 连续编号），不是屏上位次。
    func queryFocusedSpaceIndexAsync() async -> Int? {
        guard let result = await YabaiClient.runAsync(arguments: ["-m", "query", "--spaces", "--space"]),
              result.exitCode == 0 else {
            log("queryFocusedSpaceIndexAsync: yabai query failed")
            return nil
        }
        guard let data = result.stdout.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let index = json["index"] as? Int else {
            return nil
        }
        return index
    }

    /// 后台：一次全量查询所有 space（含 display index），替代 focused + 每屏分查的多次 fork。
    ///
    /// ## 场景
    /// - 快速路径唯一数据源：所有屏 displayIndex 已缓存时，1 次 fork 拿全量，
    ///   由编排层本地按 display 分组算 spaceIndex（见 Refresh 文件的时序说明）。
    func queryAllSpacesSnapshotAsync() async -> [AllSpaceSnapshot]? {
        guard let result = await YabaiClient.runAsync(arguments: ["-m", "query", "--spaces"]),
              result.exitCode == 0 else {
            log("queryAllSpacesSnapshotAsync: yabai query failed")
            return nil
        }
        guard let data = result.stdout.data(using: .utf8),
              let jsonArray = AllSpaceSnapshot.parseJSONArray(data) else {
            log("queryAllSpacesSnapshotAsync: failed to parse yabai spaces JSON")
            return nil
        }
        return AllSpaceSnapshot.parse(from: jsonArray)
    }

    /// 后台：把 CGDirectDisplayID（NSScreen 的 NSScreenNumber）映射为 yabai displayIndex。
    ///
    /// ## 场景
    /// - 仅 cache miss 时调用（首次启动/屏幕增减后首轮刷新）；
    /// - yabai 的 display index 在插拔后会重排（如拔掉 display 1 后原 display 2 变为 1），
    ///   因此缓存失效语义由编排层负责清 `cachedDisplayIndices`。
    func queryDisplayIndexAsync(displayID: UInt32) async -> Int? {
        guard let result = await YabaiClient.runAsync(arguments: ["-m", "query", "--displays"]),
              result.exitCode == 0 else {
            return nil
        }
        guard let data = result.stdout.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return nil
        }
        return json.first(where: {
            let id = $0["id"] as? UInt32 ?? UInt32($0["id"] as? Int ?? 0)
            return id == displayID
        })?["index"] as? Int
    }
}
