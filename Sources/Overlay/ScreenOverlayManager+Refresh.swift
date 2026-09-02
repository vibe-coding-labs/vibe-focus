import AppKit
import SwiftUI
import Foundation

// MARK: - Space Index 刷新编排层
// 负责「取屏幕快照 → 后台查 yabai → 校验一致性 → 应用到 cache 与 overlay」的编排，
// 以及屏幕热插拔竞态防御。查询 I/O 见 +SpaceQuery.swift，纯类型见 SpaceSnapshot.swift。

extension ScreenOverlayManager {

    /// Refresh space indices for all screens asynchronously.
    ///
    /// Queries yabai to determine which Space is currently visible on each screen,
    /// updates the overlay indicators accordingly. Uses background threads for
    /// yabai queries to avoid blocking the main thread.
    ///
    /// ## 场景
    /// 触发源共 4 个（各带独立 debounce，见 ScreenOverlayManager.swift 常量区）：
    /// 兜底 Timer（单屏 0.35s / 多屏 2s）、SIGUSR1（yabai space_changed → force）、
    /// toggle 后 debounce（0.3s → force）、屏幕变化后的 `updateOverlaysInPlace` 之外的
    /// 例行刷新。`force=true` 时无视 `automaticRefreshSuspended` 并清 `screenSpaceCache`。
    ///
    /// ## 竞态防御（2026-08-10 SIGSEGV 循环的教训，必读）
    /// 主线程取 `NSScreen.screens` 快照（preResolved）后，后台 Task fork yabai 可能耗时
    /// 数百 ms~2s；期间若发生显示器插拔，实时 `NSScreen.screens` 已与快照错位。若直接用
    /// 快照里的 enumerated index 访问新屏幕数组并触碰 WindowServer → SIGSEGV。
    /// 防御分三层：
    /// 1. 回主线程后先 `ScreenHotplugGuard.identityMatches`（UUID 集合变了就整体丢弃）；
    /// 2. `applyRefreshResults` 内部以 UUID 重新解析 index，不信任 results 携带的 index；
    /// 3. 插拔本身由 `handleScreenChange`（didChangeScreenParametersNotification）负责重建。
    ///
    /// - Parameter force: If true, bypass suspension and clear cache before refresh.
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

            // 快速路径：所有屏 displayIndex 都已缓存（稳态切屏常态——display 映射不随 space 切换变化）
            // 时，一次全量 query --spaces 拿所有 space，本地按 display 分组，每屏 spaceIndex
            // 由 resolveScreenSpaceIndex 统一裁决。把原本 focused(1) + 每屏 spaces(N) 共 N+1 次
            // yabai fork 压缩为 1 次。
            let allCached = preResolved.allSatisfy { $0.displayIndex != nil }
            if allCached, let snapshot = await self.queryAllSpacesSnapshotAsync(), !snapshot.isEmpty {
                let focusedSpaceIndex = snapshot.first(where: { $0.hasFocus })?.index
                let byDisplay = Dictionary(grouping: snapshot, by: \.display)
                let results: [(index: Int, uuid: UUID, displayIndex: Int?, spaceIndex: Int?)] = preResolved.map { item in
                    guard let displayIndex = item.displayIndex else {
                        return (item.index, item.uuid, nil, nil)
                    }
                    let spaceIndex = AllSpaceSnapshot.resolveScreenSpaceIndex(
                        from: byDisplay[displayIndex] ?? [],
                        focusedSpaceIndex: focusedSpaceIndex
                    )
                    return (item.index, item.uuid, displayIndex, spaceIndex)
                }
                // 在回主线程应用结果前，校验 Task 启动时的屏幕集合是否仍与当前一致。
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard self.screenIdentityUnchanged(preResolved: preResolved, path: "fast path") else { return }
                    log("[REFRESH] all-spaces fast path", level: .info, fields: [
                        "spaces": String(snapshot.count),
                        "screens": String(preResolved.count),
                        "focused": focusedSpaceIndex.map(String.init) ?? "nil"
                    ])
                    self.applyRefreshResults(results, screens: NSScreen.screens)
                }
                return
            }

            // fallback：displayIndex 未全部缓存（首次/屏幕变化）或全量查询失败时，
            // 保留 focused + 每屏分查逻辑（含 queryDisplayIndexAsync 解析）。
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

            // 回主线程更新 cache 和 overlay（UI 操作必须主线程）。同 fast path，先过守卫。
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.screenIdentityUnchanged(preResolved: preResolved, path: "fallback path") else { return }
                self.applyRefreshResults(results, screens: NSScreen.screens)
            }
        }
    }

    /// 热插拔守卫（防御层 1）：比较 Task 启动时与当前时刻的屏幕 UUID 集合。
    ///
    /// ## 场景
    /// - 两条路径（fast/fallback）回主线程应用结果前的统一入口；
    /// - 集合不等 = 期间发生插拔，丢弃整轮结果，由 `handleScreenChange` 负责重建；
    /// - 集合相等时仍可能有「单个 NSScreen 实例失效」的窄窗口，由
    ///   `applyRefreshResults` 的 UUID 重解析（防御层 2）兜底。
    private func screenIdentityUnchanged(
        preResolved: [(index: Int, uuid: UUID, displayID: UInt32, displayIndex: Int?)],
        path: String
    ) -> Bool {
        let currentUUIDs = Set(NSScreen.screens.map { uuidForScreen($0) })
        let preUUIDs = Set(preResolved.map { $0.uuid })
        guard ScreenHotplugGuard.identityMatches(preUUIDs: preUUIDs, currentUUIDs: currentUUIDs) else {
            log("[REFRESH] screen identity changed during async query (\(path)), discarding stale results", level: .warn, fields: [
                "preCount": String(preUUIDs.count),
                "currentCount": String(currentUUIDs.count)
            ])
            return false
        }
        return true
    }

    /// 主线程：应用后台查询结果到 cache 和 overlay。
    ///
    /// ## 场景
    /// - 仅由 `refreshSpaceIndices` 的两条路径在守卫通过后调用；
    /// - overlay 内容更新只走 `overlay.update/updatePosition/show`（就地改），仅当
    ///   overlay 窗口数与屏幕数不符（插拔后）才 `updateOverlaysInPlace` 增量补齐——
    ///   禁止在本路径 close+重建全部窗口（那是 2026-08-10 SIGSEGV 的直接原因）。
    private func applyRefreshResults(
        _ results: [(index: Int, uuid: UUID, displayIndex: Int?, spaceIndex: Int?)],
        screens: [NSScreen]
    ) {
        var needsRefresh = false
        var changedScreens: [String] = []

        // 构建当前 screens 的 uuid->index 映射，避免使用 results 中过期的 index
        // （后台 Task 执行期间用户可能重排显示器，UUID 集合相同但 enumerated index 已变）
        var currentScreenUUIDs: [UUID: Int] = [:]
        for (index, screen) in screens.enumerated() {
            currentScreenUUIDs[uuidForScreen(screen)] = index
        }

        for (_, uuid, displayIndex, spaceIndex) in results {
            if let displayIndex {
                cachedDisplayIndices[uuid] = displayIndex
            }
            let currentSpaceIndex = spaceIndex ?? 1

            // 用 UUID 在当前 screens 中查找正确的 index（而非使用 results 携带的旧 index）
            guard let currentIndex = currentScreenUUIDs[uuid] else {
                log("[REFRESH] Screen UUID \(uuid) not found in current screens, skipping", level: .warn)
                continue
            }

            // 变更判定统一走 screenCacheChange（原此处内联两份近乎逐行重复的更新块）。
            let change = Self.screenCacheChange(
                cached: screenSpaceCache[uuid],
                currentScreenIndex: currentIndex,
                currentSpaceIndex: currentSpaceIndex
            )
            guard change.needsApply else { continue }
            if let oldSpaceIndex = change.oldSpaceIndex {
                log("[REFRESH] Space index changed: Screen\(currentIndex) \(oldSpaceIndex)->\(currentSpaceIndex)")
                changedScreens.append("Screen\(currentIndex): \(oldSpaceIndex)->\(currentSpaceIndex)")
            } else {
                changedScreens.append("Screen\(currentIndex): new->\(currentSpaceIndex)")
            }
            needsRefresh = true
            screenSpaceCache[uuid] = (screenIndex: currentIndex, spaceIndex: currentSpaceIndex)

            if let overlay = overlayWindows[uuid] {
                overlay.update(screenIndex: currentIndex, spaceIndex: currentSpaceIndex, preferences: preferences)
                overlay.updatePosition(for: screens[currentIndex], position: preferences.position, margin: preferences.panelMargin)
                overlay.show()
            } else {
                log("[REFRESH] No overlay found for uuid \(uuid)", level: .warn)
            }
        }

        if overlayWindows.count != screens.count {
            log("[REFRESH] Screen count changed (\(overlayWindows.count) -> \(screens.count)), updating overlays in place")
            // 仅对消失的屏幕 close、对新屏幕创建，复用其余现有窗口（避免 close+重建 race）。
            updateOverlaysInPlace()
        } else if needsRefresh {
            log("[REFRESH] Updated screens: \(changedScreens.joined(separator: ", "))")
        }
    }

    /// 单屏 overlay 变更判定（纯函数，分支穷尽锁定于 ScreenSpaceIndexResolutionTests）。
    ///
    /// ## 场景
    /// - `applyRefreshResults` 逐屏调用：缓存缺失（新屏/首轮）或 screenIndex/spaceIndex
    ///   任一变化 → 需就地重绘并回写 cache；完全未变 → 不触碰 overlay
    ///   （WindowServer 零干扰，2026-08-10 SIGSEGV 教训的延伸：无变化不产生窗口操作）。
    struct ScreenCacheChange: Equatable {
        /// true = 需就地重绘该屏 overlay 并回写 cache。
        let needsApply: Bool
        /// 变化前的 spaceIndex（日志 "old->new" 用）；新屏（缓存缺失）或未变时为 nil。
        let oldSpaceIndex: Int?
    }

    static func screenCacheChange(
        cached: (screenIndex: Int, spaceIndex: Int)?,
        currentScreenIndex: Int,
        currentSpaceIndex: Int
    ) -> ScreenCacheChange {
        guard let cached else {
            return .init(needsApply: true, oldSpaceIndex: nil)
        }
        if cached.screenIndex == currentScreenIndex, cached.spaceIndex == currentSpaceIndex {
            return .init(needsApply: false, oldSpaceIndex: nil)
        }
        return .init(needsApply: true, oldSpaceIndex: cached.spaceIndex)
    }
}
