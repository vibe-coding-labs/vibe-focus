import AppKit
import SwiftUI
import Foundation

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

    func getSpaceIndex(for screen: NSScreen, preferStableSampling: Bool = false) -> Int? {
        let uuid = uuidForScreen(screen)

        // Check cache to prevent redundant queries within debounce interval (per screen).
        if !preferStableSampling,
           let lastQuery = lastQueryTimes[uuid],
           Date().timeIntervalSince(lastQuery) < queryDebounceInterval,
           let cached = cachedSpaceIndices[uuid] {
            log("Using cached space index for screen \(uuid): \(cached)")
            return cached
        }

        // Try to get from yabai first
        let result: Int?
        log("Querying space index for screen \(uuid)... preferStableSampling=\(preferStableSampling)")
        if let yabaiIndex = getYabaiSpaceIndex(for: screen, preferStableSampling: preferStableSampling) {
            log("Got space index from yabai for screen \(uuid): \(yabaiIndex)")
            result = yabaiIndex
        } else if let cgIndex = getCGSpaceIndex(for: screen) {
            log("Got space index from CG for screen \(uuid): \(cgIndex)")
            result = cgIndex
        } else {
            log("Could not get space index for screen \(uuid), returning nil")
            result = nil
        }

        // Update cache for this specific screen
        lastQueryTimes[uuid] = Date()
        cachedSpaceIndices[uuid] = result

        return result
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
        // First, check if user has configured a custom path
        if let customPath = preferences.yabaiPath,
           !customPath.isEmpty,
           FileManager.default.fileExists(atPath: customPath) {
            log("Using user-configured yabai path: \(customPath)")
            return customPath
        }

        // Check cached path
        if let cached = cachedYabaiPath, FileManager.default.fileExists(atPath: cached) {
            return cached
        }

        // Try common installation paths
        let commonPaths = [
            "/opt/homebrew/bin/yabai",
            "/usr/local/bin/yabai",
            "/usr/bin/yabai",
            "/bin/yabai",
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/yabai"),
            (NSHomeDirectory() as NSString).appendingPathComponent("bin/yabai"),
            (NSHomeDirectory() as NSString).appendingPathComponent(".nix-profile/bin/yabai")
        ]

        for path in commonPaths {
            if FileManager.default.fileExists(atPath: path) {
                cachedYabaiPath = path
                log("Found yabai at: \(path)")
                return path
            }
        }

        // Try to find using user's shell
        if let shellPath = getYabaiPathFromUserShell() {
            cachedYabaiPath = shellPath
            log("Found yabai via user shell: \(shellPath)")
            return shellPath
        }

        // Try to find using which via bash -l
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-l", "-c", "which yabai"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty,
               FileManager.default.fileExists(atPath: path) {
                cachedYabaiPath = path
                log("Found yabai via bash -l: \(path)")
                return path
            }
        } catch {
            log("Failed to locate yabai using bash: \(error)")
        }

        log("yabai binary not found in any location")
        return nil
    }

    func getYabaiPathFromUserShell() -> String? {
        // Get user's default shell
        let shellTask = Process()
        shellTask.launchPath = "/usr/bin/env"
        shellTask.arguments = ["bash", "-l", "-c", "echo $SHELL"]

        let shellPipe = Pipe()
        shellTask.standardOutput = shellPipe
        shellTask.standardError = Pipe()

        do {
            try shellTask.run()
            shellTask.waitUntilExit()

            let shellData = shellPipe.fileHandleForReading.readDataToEndOfFile()
            guard let userShell = String(data: shellData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !userShell.isEmpty else {
                return nil
            }

            // Use user's shell to find yabai
            let whichTask = Process()
            whichTask.launchPath = userShell
            whichTask.arguments = ["-l", "-c", "which yabai"]

            let whichPipe = Pipe()
            whichTask.standardOutput = whichPipe
            whichTask.standardError = Pipe()

            try whichTask.run()
            whichTask.waitUntilExit()

            let pathData = whichPipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: pathData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty,
               FileManager.default.fileExists(atPath: path) {
                return path
            }
        } catch {
            log("Failed to get yabai path from user shell: \(error)")
        }

        return nil
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

        guard let yabaiPath = getYabaiPath() else {
            return nil
        }

        let task = Process()
        task.launchPath = yabaiPath
        task.arguments = ["-m", "query", "--displays"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            // Use waitUntilExit with timeout to prevent blocking
            let semaphore = DispatchSemaphore(value: 0)
            task.terminationHandler = { _ in
                semaphore.signal()
            }
            let result = semaphore.wait(timeout: .now() + yabaiCommandTimeout)
            if result == .timedOut {
                log("yabai displays query timed out")
                task.terminate()
                return nil
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return nil
            }

            // Find the display with matching CGDirectDisplayID
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
        } catch {
            log("Failed to get yabai display index: \(error)")
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
