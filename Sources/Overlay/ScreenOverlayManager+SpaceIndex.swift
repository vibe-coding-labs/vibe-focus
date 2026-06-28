import AppKit
import SwiftUI
import Foundation

/// Captured state of Space-to-display mappings at a point in time.
struct SpaceSnapshot: Equatable {
    let index: Int
    let isVisible: Bool
    let hasFocus: Bool
}

/// 全量 space 快照（含所属 yabai display index），用于一次 query --spaces 拿所有屏的 space 映射。
struct AllSpaceSnapshot: Equatable {
    let index: Int
    let display: Int
    let isVisible: Bool
    let hasFocus: Bool
}

/// Resolves which display index a given Space is located on.
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

    static func activeDisplaySpaceIndex(in spaces: [SpaceSnapshot]) -> Int? {
        if let visible = spaces.first(where: { $0.isVisible }) {
            return visible.index
        }
        if let focused = spaces.first(where: { $0.hasFocus }) {
            return focused.index
        }
        return nil
    }
}

extension ScreenOverlayManager {

    func refreshSpaceIndices(force: Bool = false) {
        // P-INST-245: overlay space index 刷新编排耗时（NSScreen.screens 枚举 + uuidForScreen/deviceDescription preResolve + 后台 Task 派发 yabai fork query；space 切换/timer/toggle 后调用，主线程同步部分归因；后台 fork 异步不计入 defer；slow-op ≥30ms warn）。
        let rsiStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: rsiStart)
            if durMs >= 30 { log("[Overlay] refreshSpaceIndices slow", level: .warn, fields: ["force": String(force), "durationMs": String(durMs)]) }
        }
        guard !automaticRefreshSuspended || force else {
            return
        }
        guard preferences.isEnabled else {
            return
        }

        if force {
            log("[REFRESH] Force refresh requested, clearing screenSpaceCache")
            screenSpaceCache.removeAll()
        }

        let screens = NSScreen.screens

        // 主线程预解析：提取 Sendable 值（NSScreen 不可跨 actor 传递）。
        // 命中 cachedDisplayIndices 的 screen 直接复用，避免后台重复 fork query --displays。
        let preResolved: [(index: Int, uuid: UUID, displayID: UInt32, displayIndex: Int?)] = screens.enumerated().map { (index, screen) in
            let uuid = uuidForScreen(screen)
            let displayID: UInt32 = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return (index, uuid, displayID, cachedDisplayIndices[uuid])
        }

        // 后台并发查询所有 screen 的 space index —— yabai fork 在后台串行队列执行，
        // 不阻塞主线程。这是消除 toggle 后 force refresh 卡顿的核心：space 切换后
        // yabai 查询可能卡顿接近 2s timeout，同步调用会冻结 UI（实测 restore 后 2.18s）。
        Task { [weak self] in
            guard let self else { return }

            // P-INST-42: refreshSpaceIndices 后台 Task 总耗时。
            let rsiStart = Date()

            // 快速路径：所有屏 displayIndex 都已缓存（稳态切屏常态——display 映射不随 space 切换变化）
            // 时，一次全量 query --spaces 拿所有 space，本地按 display 分组算每屏 spaceIndex。
            // 把原本 focused(1) + 每屏 spaces(N) 共 N+1 次 yabai fork 压缩为 1 次。
            // 切屏瞬间 WindowServer 繁忙会让单次 yabai query 变慢（实测 290ms~1s），减少 fork 次数
            // 是降低切屏卡顿的关键：SIGUSR1 风暴时 N+1 fork/轮 × 主+follow-up 多轮 会雪崩。
            let allCached = preResolved.allSatisfy { $0.displayIndex != nil }
            if allCached, let snapshot = await self.queryAllSpacesSnapshotAsync(), !snapshot.isEmpty {
                let focusedSpaceIndex = snapshot.first(where: { $0.hasFocus })?.index
                let byDisplay = Dictionary(grouping: snapshot, by: \.display)
                let results: [(index: Int, uuid: UUID, displayIndex: Int?, spaceIndex: Int?)] = preResolved.map { item in
                    guard let displayIndex = item.displayIndex else {
                        return (item.index, item.uuid, nil, nil)
                    }
                    let spaces = (byDisplay[displayIndex] ?? []).sorted { $0.index < $1.index }
                    var spaceIndex: Int? = nil
                    if let focusedSpaceIndex,
                       let pos = spaces.firstIndex(where: { $0.index == focusedSpaceIndex }) {
                        spaceIndex = pos + 1
                    }
                    if spaceIndex == nil,
                       let pos = spaces.firstIndex(where: { $0.isVisible }) {
                        spaceIndex = pos + 1
                    }
                    return (item.index, item.uuid, displayIndex, spaceIndex)
                }
                await MainActor.run {
                    log("[REFRESH] all-spaces fast path", level: .info, fields: [
                        "spaces": String(snapshot.count),
                        "screens": String(preResolved.count),
                        "focused": focusedSpaceIndex.map(String.init) ?? "nil"
                    ])
                    self.applyRefreshResults(results, screens: NSScreen.screens, startedAt: rsiStart)
                }
                return
            }

            // fallback：displayIndex 未全部缓存（首次/屏幕变化）或全量查询失败时，
            // 保留原 focused + 每屏分查逻辑（含 queryDisplayIndexAsync 解析）。
            let focusedSpaceIndex = await self.queryFocusedSpaceIndexAsync()

            let results = await withTaskGroup(of: (Int, UUID, Int?, Int?).self) { group in
                for item in preResolved {
                    group.addTask { [weak self] in
                        guard let self else { return (item.index, item.uuid, nil, nil) }
                        let (displayIndex, spaceIndex) = await self.getPerScreenSpaceIndexAsync(
                            displayID: item.displayID,
                            cachedDisplayIndex: item.displayIndex,
                            focusedSpaceIndex: focusedSpaceIndex
                        )
                        return (item.index, item.uuid, displayIndex, spaceIndex)
                    }
                }
                var collected: [(Int, UUID, Int?, Int?)] = []
                for await entry in group {
                    collected.append(entry)
                }
                return collected
            }

            // 回主线程更新 cache 和 overlay（UI 操作必须主线程）
            await MainActor.run {
                self.applyRefreshResults(results, screens: NSScreen.screens, startedAt: rsiStart)
            }
        }
    }

    /// 主线程：应用后台查询结果到 cache 和 overlay。
    private func applyRefreshResults(
        _ results: [(index: Int, uuid: UUID, displayIndex: Int?, spaceIndex: Int?)],
        screens: [NSScreen],
        startedAt: Date
    ) {
        // P-INST-42: applyRefreshResults 耗时（主线程 UI 更新 + 可能 refreshOverlays；含后台 Task 的总耗时归因）。
        defer {
            log("[REFRESH] refreshSpaceIndices task finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: startedAt))
            ])
        }
        var needsRefresh = false
        var changedScreens: [String] = []

        for (index, uuid, displayIndex, spaceIndex) in results {
            if let displayIndex {
                cachedDisplayIndices[uuid] = displayIndex
            }
            let currentSpaceIndex = spaceIndex ?? 1

            if let cached = screenSpaceCache[uuid] {
                if cached.screenIndex != index || cached.spaceIndex != currentSpaceIndex {
                    log("[REFRESH] Space index changed: Screen\(index) \(cached.spaceIndex)->\(currentSpaceIndex)")
                    needsRefresh = true
                    changedScreens.append("Screen\(index): \(cached.spaceIndex)->\(currentSpaceIndex)")
                    screenSpaceCache[uuid] = (screenIndex: index, spaceIndex: currentSpaceIndex)

                    if index < screens.count, let overlay = overlayWindows[uuid] {
                        overlay.update(screenIndex: index, spaceIndex: currentSpaceIndex, preferences: preferences)
                        overlay.updatePosition(for: screens[index], position: preferences.position, margin: preferences.panelMargin)
                        overlay.show()
                    } else {
                        log("[REFRESH] No overlay found for uuid \(uuid)", level: .warn)
                    }
                }
            } else {
                needsRefresh = true
                changedScreens.append("Screen\(index): new->\(currentSpaceIndex)")
                screenSpaceCache[uuid] = (screenIndex: index, spaceIndex: currentSpaceIndex)

                if index < screens.count, let overlay = overlayWindows[uuid] {
                    overlay.update(screenIndex: index, spaceIndex: currentSpaceIndex, preferences: preferences)
                    overlay.updatePosition(for: screens[index], position: preferences.position, margin: preferences.panelMargin)
                    overlay.show()
                } else {
                    log("[REFRESH] No overlay found for new screen uuid \(uuid)", level: .warn)
                }
            }
        }

        if overlayWindows.count != screens.count {
            log("[REFRESH] Screen count changed (\(overlayWindows.count) -> \(screens.count)), refreshing overlays")
            refreshOverlays()
        } else if needsRefresh {
            log("[REFRESH] Updated screens: \(changedScreens.joined(separator: ", "))")
        }
    }

    // MARK: - Async Space Index Queries (off main thread)

    /// 后台：查询单 screen 的 space index。不访问 @MainActor 状态，所有 fork 在后台队列。
    /// 返回 (displayIndex, spaceIndex)——displayIndex 可能是新解析出的，调用方在主线程回写 cache。
    func getPerScreenSpaceIndexAsync(
        displayID: UInt32,
        cachedDisplayIndex: Int?,
        focusedSpaceIndex: Int?
    ) async -> (displayIndex: Int?, spaceIndex: Int?) {
        // P-INST-58: overlay 后台单 screen space index 编排耗时（queryDisplayIndex + queryYabaiSpaces；归因 obs 23207 overlay 占用 yabai 的单 display 分布）。
        let pssiStart = Date()
        defer {
            log("[REFRESH] getPerScreenSpaceIndexAsync finished", level: .debug, fields: [
                "displayID": String(displayID),
                "durationMs": String(elapsedMilliseconds(since: pssiStart))
            ])
        }
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

        let sortedSpaces = displaySpaces.sorted { $0.index < $1.index }

        if let focusedSpaceIndex {
            for (position, space) in sortedSpaces.enumerated() where space.index == focusedSpaceIndex {
                return (displayIndex, position + 1)
            }
        }
        for (position, space) in sortedSpaces.enumerated() where space.isVisible {
            return (displayIndex, position + 1)
        }
        return (displayIndex, 1)
    }

    func queryYabaiSpacesAsync(forDisplayIndex displayIndex: Int) async -> [SpaceSnapshot]? {
        // P-INST-58: overlay 后台单 display spaces query 耗时（YabaiClient.runAsync P-INST-37 已覆盖 fork）。
        let qysaStart = Date()
        defer {
            log("[REFRESH] queryYabaiSpacesAsync finished", level: .debug, fields: [
                "displayIndex": String(displayIndex),
                "durationMs": String(elapsedMilliseconds(since: qysaStart))
            ])
        }
        guard let result = await YabaiClient.runAsync(arguments: ["-m", "query", "--spaces", "--display", "\(displayIndex)"]),
              result.exitCode == 0 else {
            log("queryYabaiSpacesAsync: yabai query failed")
            return nil
        }
        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            log("queryYabaiSpacesAsync: failed to parse yabai spaces JSON")
            return nil
        }
        return json.compactMap { space in
            guard let index = space["index"] as? Int else { return nil }
            let visible = (space["is-visible"] as? Bool) ?? ((space["is-visible"] as? Int ?? 0) == 1)
            let hasFocus = (space["has-focus"] as? Bool) ?? ((space["has-focus"] as? Int ?? 0) == 1)
            return SpaceSnapshot(index: index, isVisible: visible, hasFocus: hasFocus)
        }
    }

    func queryFocusedSpaceIndexAsync() async -> Int? {
        // P-INST-58: overlay 后台 focused space query 耗时（YabaiClient.runAsync P-INST-37 已覆盖 fork）。
        let qfsiStart = Date()
        defer {
            log("[REFRESH] queryFocusedSpaceIndexAsync finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: qfsiStart))
            ])
        }
        guard let result = await YabaiClient.runAsync(arguments: ["-m", "query", "--spaces", "--space"]),
              result.exitCode == 0 else {
            log("queryFocusedSpaceIndexAsync: yabai query failed")
            return nil
        }
        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let index = json["index"] as? Int else {
            return nil
        }
        return index
    }

    /// 后台：一次全量查询所有 space（含 display index），替代 focused + 每屏分查的多次 fork。
    /// yabai -m query --spaces 返回全部 space，每条含 display(=yabai displayIndex)、is-visible、has-focus、index。
    /// 用于切屏刷新快速路径：所有屏 displayIndex 已缓存时，1 次 fork 拿全量，本地按 display 分组算 spaceIndex。
    func queryAllSpacesSnapshotAsync() async -> [AllSpaceSnapshot]? {
        // P-INST-58: overlay 后台全量 spaces query 耗时（YabaiClient.runAsync P-INST-37 已覆盖 fork）。
        guard let result = await YabaiClient.runAsync(arguments: ["-m", "query", "--spaces"]),
              result.exitCode == 0 else {
            log("queryAllSpacesSnapshotAsync: yabai query failed")
            return nil
        }
        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            log("queryAllSpacesSnapshotAsync: failed to parse yabai spaces JSON")
            return nil
        }
        return json.compactMap { space in
            guard let index = space["index"] as? Int,
                  let display = space["display"] as? Int else { return nil }
            let visible = (space["is-visible"] as? Bool) ?? ((space["is-visible"] as? Int ?? 0) == 1)
            let hasFocus = (space["has-focus"] as? Bool) ?? ((space["has-focus"] as? Int ?? 0) == 1)
            return AllSpaceSnapshot(index: index, display: display, isVisible: visible, hasFocus: hasFocus)
        }
    }

    func queryDisplayIndexAsync(displayID: UInt32) async -> Int? {
        // P-INST-58: overlay 后台 displays query 耗时（YabaiClient.runAsync P-INST-37 已覆盖 fork；cache miss 时调用，全量 displays 扫描）。
        let qdiStart = Date()
        defer {
            log("[REFRESH] queryDisplayIndexAsync finished", level: .debug, fields: [
                "displayID": String(displayID),
                "durationMs": String(elapsedMilliseconds(since: qdiStart))
            ])
        }
        guard let result = await YabaiClient.runAsync(arguments: ["-m", "query", "--displays"]),
              result.exitCode == 0 else {
            return nil
        }
        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return json.first(where: {
            let id = $0["id"] as? UInt32 ?? UInt32($0["id"] as? Int ?? 0)
            return id == displayID
        })?["index"] as? Int
    }

    func getPerScreenSpaceIndex(for screen: NSScreen) -> Int? {
        // P-INST-73: 同步 space index 查询耗时（getYabaiDisplayIndex + queryYabaiSpaces + queryFocusedSpaceIndex 共 3-4 次 yabai fork 累积；cache miss 时主线程同步阻塞 UI；P-INST-58 覆盖 async 版本，此为同步 fallback）。
        let psiStart = Date()
        defer {
            log("[ScreenOverlayManager] getPerScreenSpaceIndex finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: psiStart))
            ])
        }
        guard let yabaiPath = getYabaiPath() else {
            return nil
        }

        guard let displayIndex = getYabaiDisplayIndex(for: screen) else {
            return nil
        }

        guard let displaySpaces = queryYabaiSpaces(forDisplayIndex: displayIndex, yabaiPath: yabaiPath),
              !displaySpaces.isEmpty else {
            return nil
        }

        guard let focusedSpaceIndex = queryFocusedSpaceIndex(yabaiPath: yabaiPath) else {
            return nil
        }

        let sortedSpaces = displaySpaces.sorted { $0.index < $1.index }

        for (position, space) in sortedSpaces.enumerated() {
            if space.index == focusedSpaceIndex {
                return position + 1
            }
        }

        for (position, space) in sortedSpaces.enumerated() {
            if space.isVisible {
                return position + 1
            }
        }

        return 1
    }

    func getYabaiPath() -> String? {
        // P-INST-179: yabai 路径解析耗时（preferences.yabaiPath 自定义路径 FileManager.fileExists stat + YabaiClient.yabaiPath P-INST-178；overlay/space 操作前获取路径）。
        let gypStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: gypStart)
            if durMs >= 30 { log("[Overlay] getYabaiPath slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        if let customPath = preferences.yabaiPath,
           !customPath.isEmpty,
           FileManager.default.fileExists(atPath: customPath) {
            return customPath
        }
        return YabaiClient.yabaiPath()
    }

    func getYabaiDisplayIndex(for screen: NSScreen) -> Int? {
        // P-INST-180: yabai display 索引查询耗时（缓存命中 fast / 未命中 deviceDescription NSScreenNumber 读 + YabaiClient.run -m query --displays fork P-INST-35 + JSONSerialization 解析按 id 匹配 + 缓存写入；overlay 每 display space 刷新调用，缓存命中应 <1ms）。
        let gydiStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: gydiStart)
            if durMs >= 30 { log("[Overlay] getYabaiDisplayIndex slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        let screenUUID = uuidForScreen(screen)
        if let cachedDisplayIndex = cachedDisplayIndices[screenUUID] {
            return cachedDisplayIndex
        }

        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            log("Could not get screenNumber from deviceDescription")
            return nil
        }
        let targetDisplayID = screenNumber.uint32Value

        guard let result = YabaiClient.run(arguments: ["-m", "query", "--displays"]),
              result.exitCode == 0 else {
            log("getYabaiDisplayIndex: yabai query failed")
            return nil
        }

        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        if let display = json.first(where: {
            let id = $0["id"] as? UInt32 ?? UInt32($0["id"] as? Int ?? 0)
            return id == targetDisplayID
        }) {
            let displayIndex = display["index"] as? Int
            if let displayIndex {
                cachedDisplayIndices[screenUUID] = displayIndex
            }
            return displayIndex
        }

        return nil
    }

    func getYabaiSpaceIndex(for screen: NSScreen, preferStableSampling: Bool = false) -> Int? {
        // P-INST-73: 同步 space index 查询耗时（queryFocusedSpaceIndex + getYabaiDisplayIndex + queryYabaiSpaces fork 累积；cache miss 时主线程同步阻塞 UI）。
        let ysiStart = Date()
        defer {
            log("[ScreenOverlayManager] getYabaiSpaceIndex finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: ysiStart))
            ])
        }
        guard let yabaiPath = getYabaiPath() else {
            return nil
        }

        let screenCount = NSScreen.screens.count

        if screenCount <= 1 {
            if let focusedSpaceIndex = queryFocusedSpaceIndex(yabaiPath: yabaiPath) {
                return focusedSpaceIndex
            }
        }

        guard let displayIndex = getYabaiDisplayIndex(for: screen) else {
            return nil
        }

        let focusedSpaceIndex = queryFocusedSpaceIndex(yabaiPath: yabaiPath)
        guard let displaySpaces = queryYabaiSpaces(forDisplayIndex: displayIndex, yabaiPath: yabaiPath) else {
            if screenCount <= 1, let focusedSpaceIndex {
                return focusedSpaceIndex
            }
            log("getYabaiSpaceIndex: display query failed for multi-display, no fallback", level: .warn)
            return nil
        }

        return SpaceIndexResolver.chooseIndex(
            displaySpaces: displaySpaces,
            focusedSpaceIndex: focusedSpaceIndex,
            screenCount: screenCount
        )
    }
}
