import AppKit
import SwiftUI
import Foundation

struct SpaceSnapshot: Equatable {
    let index: Int
    let isVisible: Bool
    let hasFocus: Bool
}

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

    private static func activeDisplaySpaceIndex(in spaces: [SpaceSnapshot]) -> Int? {
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
            log("[REFRESH] Skipped - preferences disabled")
            return
        }

        if force {
            log("[REFRESH] ====== FORCE REFRESH ======")
            log("[REFRESH] Force refresh requested, clearing screenSpaceCache")
            screenSpaceCache.removeAll()
        }

        let screens = NSScreen.screens
        log("[REFRESH] Checking \(screens.count) screens...")

        var needsRefresh = false
        var changedScreens: [String] = []

        for (index, screen) in screens.enumerated() {
            let uuid = uuidForScreen(screen)

            let currentSpaceIndex = getPerScreenSpaceIndex(for: screen) ?? 1
            log("[REFRESH] Screen \(index): per-screen index=\(currentSpaceIndex), uuid=\(uuid)")

            if let cached = screenSpaceCache[uuid] {
                log("[REFRESH]   Cached: screenIndex=\(cached.screenIndex), spaceIndex=\(cached.spaceIndex)")
                if cached.screenIndex != index || cached.spaceIndex != currentSpaceIndex {
                    log("[REFRESH]   *** CHANGE DETECTED ***")
                    needsRefresh = true
                    changedScreens.append("Screen\(index): \(cached.spaceIndex)->\(currentSpaceIndex)")
                    screenSpaceCache[uuid] = (screenIndex: index, spaceIndex: currentSpaceIndex)

                    if let overlay = overlayWindows[uuid] {
                        log("[REFRESH]   Updating overlay: screen=\(index), space=\(currentSpaceIndex)")
                        overlay.update(screenIndex: index, spaceIndex: currentSpaceIndex, preferences: preferences)
                        overlay.updatePosition(for: screen, position: preferences.position, margin: preferences.panelMargin)
                        overlay.show()
                        log("[REFRESH]   Overlay updated and shown")
                    } else {
                        log("[REFRESH]   WARNING: No overlay found for uuid \(uuid)")
                    }
                } else {
                    log("[REFRESH]   No change (spaceIndex unchanged)")
                }
            } else {
                log("[REFRESH]   New screen: Screen\(index): new->\(currentSpaceIndex)")
                needsRefresh = true
                changedScreens.append("Screen\(index): new->\(currentSpaceIndex)")
                screenSpaceCache[uuid] = (screenIndex: index, spaceIndex: currentSpaceIndex)

                // FIX: Also update overlay for new screens
                if let overlay = overlayWindows[uuid] {
                    log("[REFRESH]   Updating overlay for new screen: screen=\(index), space=\(currentSpaceIndex)")
                    overlay.update(screenIndex: index, spaceIndex: currentSpaceIndex, preferences: preferences)
                    overlay.updatePosition(for: screen, position: preferences.position, margin: preferences.panelMargin)
                    overlay.show()
                    log("[REFRESH]   Overlay for new screen updated")
                } else {
                    log("[REFRESH]   WARNING: No overlay found for new screen uuid \(uuid)")
                }
            }
        }

        if overlayWindows.count != screens.count {
            log("[REFRESH] Screen count changed (\(overlayWindows.count) -> \(screens.count)), refreshing overlays")
            refreshOverlays()
        } else if needsRefresh {
            log("[REFRESH] Updated screens: \(changedScreens.joined(separator: ", "))")
        } else if force {
            log("[REFRESH] Force refresh but no changes detected")
        }

        log("[REFRESH] ====== REFRESH COMPLETE ======")
    }

    func getPerScreenSpaceIndex(for screen: NSScreen) -> Int? {
        log("ScreenOverlayManager.getPerScreenSpaceIndex entry", level: .debug, fields: ["screenFrame": String(describing: screen.frame)])
        guard let yabaiPath = getYabaiPath() else {
            log("ScreenOverlayManager.getPerScreenSpaceIndex yabai not found", level: .debug)
            return nil
        }

        guard let displayIndex = getYabaiDisplayIndex(for: screen) else {
            log("ScreenOverlayManager.getPerScreenSpaceIndex display index not found", level: .debug)
            return nil
        }

        // Get all spaces for this display
        guard let displaySpaces = queryYabaiSpaces(forDisplayIndex: displayIndex, yabaiPath: yabaiPath),
              !displaySpaces.isEmpty else {
            log("ScreenOverlayManager.getPerScreenSpaceIndex no display spaces", level: .debug, fields: ["displayIndex": String(displayIndex)])
            return nil
        }

        // Get the currently focused space index
        guard let focusedSpaceIndex = queryFocusedSpaceIndex(yabaiPath: yabaiPath) else {
            log("ScreenOverlayManager.getPerScreenSpaceIndex focused space not found", level: .debug)
            return nil
        }

        // Find the position of the focused space in this display's spaces list
        // Sort spaces by their index to ensure consistent ordering
        let sortedSpaces = displaySpaces.sorted { $0.index < $1.index }

        // Find which position the focused space is in (1-based)
        for (position, space) in sortedSpaces.enumerated() {
            if space.index == focusedSpaceIndex {
                log("ScreenOverlayManager.getPerScreenSpaceIndex found focused space", level: .debug, fields: ["focusedSpaceIndex": String(focusedSpaceIndex), "position": String(position + 1)])
                return position + 1  // 1-based index
            }
        }

        // If focused space is not on this display, find the visible one
        log("ScreenOverlayManager.getPerScreenSpaceIndex focused space not on this display, looking for visible", level: .debug, fields: ["focusedSpaceIndex": String(focusedSpaceIndex)])
        for (position, space) in sortedSpaces.enumerated() {
            if space.isVisible {
                log("ScreenOverlayManager.getPerScreenSpaceIndex found visible space", level: .debug, fields: ["spaceIndex": String(space.index), "position": String(position + 1)])
                return position + 1
            }
        }

        // Fallback: return 1
        log("ScreenOverlayManager.getPerScreenSpaceIndex fallback to 1", level: .debug)
        return 1
    }

    func getYabaiPath() -> String? {
        // 先检查用户自定义路径
        if let customPath = preferences.yabaiPath,
           !customPath.isEmpty,
           FileManager.default.fileExists(atPath: customPath) {
            return customPath
        }
        // 委托到 YabaiClient — 共享缓存和完整 fallback 链
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

        // Fast path for single-display setups: focused-space query is the lowest-latency source.
        if screenCount <= 1 {
            if let focusedSpaceIndex = queryFocusedSpaceIndex(yabaiPath: yabaiPath) {
                log("[DEBUG] Selected active space with focused-only fast path: index=\(focusedSpaceIndex), stable=\(preferStableSampling)")
                return focusedSpaceIndex
            }
            log("[DEBUG] focused-only fast path failed, falling back to display query")
        }

        // Get the yabai display index for this screen
        guard let displayIndex = getYabaiDisplayIndex(for: screen) else {
            return nil
        }

        let focusedSpaceIndex = queryFocusedSpaceIndex(yabaiPath: yabaiPath)
        guard let displaySpaces = queryYabaiSpaces(forDisplayIndex: displayIndex, yabaiPath: yabaiPath) else {
            if screenCount <= 1, let focusedSpaceIndex {
                log("[DEBUG] display query failed, fallback to focused=\(focusedSpaceIndex), stable=\(preferStableSampling)")
                return focusedSpaceIndex
            }
            log("[DEBUG] display query failed, no fallback for multi-display")
            return nil
        }

        let resolved = SpaceIndexResolver.chooseIndex(
            displaySpaces: displaySpaces,
            focusedSpaceIndex: focusedSpaceIndex,
            screenCount: screenCount
        )

        if let resolved {
            log("[DEBUG] Selected active space with index: \(resolved), focused=\(focusedSpaceIndex.map(String.init) ?? "nil"), stable=\(preferStableSampling)")
        } else {
            log("[DEBUG] Failed to resolve active space index, focused=\(focusedSpaceIndex.map(String.init) ?? "nil"), stable=\(preferStableSampling)")
        }

        return resolved
    }
}
