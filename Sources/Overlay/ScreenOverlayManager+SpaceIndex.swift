import AppKit
import SwiftUI
import Foundation

/// Captured state of Space-to-display mappings at a point in time.
struct SpaceSnapshot: Equatable {
    let index: Int
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

            // focused space 所有 screen 共享，只查一次
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
                self.applyRefreshResults(results, screens: NSScreen.screens)
            }
        }
    }

    /// 主线程：应用后台查询结果到 cache 和 overlay。
    private func applyRefreshResults(
        _ results: [(index: Int, uuid: UUID, displayIndex: Int?, spaceIndex: Int?)],
        screens: [NSScreen]
    ) {
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

    func queryDisplayIndexAsync(displayID: UInt32) async -> Int? {
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
        if let customPath = preferences.yabaiPath,
           !customPath.isEmpty,
           FileManager.default.fileExists(atPath: customPath) {
            return customPath
        }
        return YabaiClient.yabaiPath()
    }

    func getYabaiDisplayIndex(for screen: NSScreen) -> Int? {
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
