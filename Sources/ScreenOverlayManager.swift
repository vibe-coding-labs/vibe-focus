import AppKit
import Foundation
import Darwin  // for signal.h

// MARK: - Screen Overlay Manager
@MainActor
class ScreenOverlayManager: ObservableObject {
    static let shared = ScreenOverlayManager()

    private static var signalSource: DispatchSourceSignal?

    @Published var preferences: ScreenIndexPreferences {
        didSet {
            preferences.save()
            refreshOverlays()
        }
    }

    private var overlayWindows: [UUID: OverlayWindow] = [:]
    private var screenSpaceCache: [UUID: (screenIndex: Int, spaceIndex: Int)] = [:]
    private var refreshTimer: Timer?

    // Query result caching to prevent redundant yabai calls
    private var cachedSpaceIndices: [UUID: Int] = [:]
    private var lastQueryTimes: [UUID: Date] = [:]  // Per-screen query time tracking
    private let queryDebounceInterval: TimeInterval = 0.05  // 50ms debounce - 减少延迟

    private init() {
        self.preferences = ScreenIndexPreferences.load()
        log("ScreenOverlayManager initialized, isEnabled=\(preferences.isEnabled)")
        setupScreenNotifications()
        setupSignalHandler()
        registerYabaiSignals()
        startRefreshTimer()
    }

    // MARK: - Signal Handling
    private func setupSignalHandler() {
        // 设置 SIGUSR1 信号处理
        signal(SIGUSR1, SIG_IGN)  // 忽略默认处理

        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            log("[SIGUSR1] Received signal at \(timestamp), clearing caches and refreshing...")
            // Clear cache to force fresh query on space change
            self?.clearSpaceIndexCache()
            // 立即刷新，减少延迟
            log("[SIGUSR1] Immediate refresh")
            self?.refreshSpaceIndices(force: true)

            // 100ms 后再次刷新作为保险（处理可能的竞态条件）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                log("[SIGUSR1] Second refresh (100ms after signal)")
                self?.refreshSpaceIndices(force: true)
            }
        }
        source.resume()

        ScreenOverlayManager.signalSource = source
        log("Signal handler setup complete")
    }

    private func clearSpaceIndexCache() {
        cachedSpaceIndices.removeAll()
        lastQueryTimes.removeAll()
        // 关键修复：同时清除 screenSpaceCache，确保信号触发时强制刷新
        screenSpaceCache.removeAll()
        log("Cleared all caches including screenSpaceCache")
    }

    private func registerYabaiSignals() {
        guard let yabaiPath = getYabaiPath() else { return }

        // 检查是否已注册信号
        let checkTask = Process()
        checkTask.launchPath = yabaiPath
        checkTask.arguments = ["-m", "signal", "--list"]

        let pipe = Pipe()
        checkTask.standardOutput = pipe
        checkTask.launch()
        checkTask.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return }

        // 如果已经注册了 vibefocus 信号，跳过
        if output.contains("vibefocus-space-changed") {
            return
        }

        // 获取脚本路径 - 优先从 Bundle 查找，如果不存在则从项目目录查找
        let scriptPath: String
        if let bundlePath = Bundle.main.path(forResource: "yabai-space-changed", ofType: "sh") {
            scriptPath = bundlePath
        } else if FileManager.default.fileExists(atPath: "Resources/yabai-space-changed.sh") {
            // 开发模式：从项目根目录查找
            scriptPath = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent("Resources/yabai-space-changed.sh")
        } else {
            log("Could not find yabai-space-changed.sh script in Bundle or project directory")
            return
        }
        log("Using yabai-space-changed script at: \(scriptPath)")

        // 注册信号: 空间切换时触发
        let registerTask = Process()
        registerTask.launchPath = yabaiPath
        registerTask.arguments = [
            "-m", "signal", "--add",
            "event=space_changed",
            "action=\"\(scriptPath)\"",
            "label=vibefocus-space-changed"
        ]
        registerTask.launch()
        registerTask.waitUntilExit()

        log("Registered yabai signal for space changes")
    }

    // MARK: - Setup
    private func setupScreenNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func startRefreshTimer() {
        // 轮询频率 200ms，快速检测三指滑动（yabai 信号提供即时更新，轮询作为备用）
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSpaceIndices()
            }
        }
        log("Started refresh timer with 0.2s interval (for native workspace switching)")
    }

    @objc private func handleScreenChange() {
        log("Screen configuration changed, refreshing overlays")
        refreshOverlays()
    }

    // MARK: - Public Methods
    func setEnabled(_ enabled: Bool) {
        preferences.isEnabled = enabled
        if enabled {
            showOverlays()
        } else {
            hideOverlays()
        }
    }

    func updatePosition(_ position: IndexPosition) {
        preferences.position = position
        updateOverlayPositions()
    }

    func refreshOverlays() {
        log("refreshOverlays called, isEnabled=\(preferences.isEnabled)")
        hideOverlays()
        if preferences.isEnabled {
            showOverlays()
        }
    }

    // MARK: - Private Methods
    private func uuidForScreen(_ screen: NSScreen) -> UUID {
        if let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            // Use the uint32 value as UUID's uuid_t bytes
            var uuidBytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            let value = screenID.uint32Value
            // Store the uint32 in the first 4 bytes
            uuidBytes.0 = UInt8((value >> 24) & 0xFF)
            uuidBytes.1 = UInt8((value >> 16) & 0xFF)
            uuidBytes.2 = UInt8((value >> 8) & 0xFF)
            uuidBytes.3 = UInt8(value & 0xFF)
            return UUID(uuid: uuidBytes)
        }
        // Fallback: use the screen's hash
        return UUID(uuid: uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(abs(screen.hashValue % 256))))
    }

    private func showOverlays() {
        let screens = NSScreen.screens

        for (index, screen) in screens.enumerated() {
            let uuid = uuidForScreen(screen)

            let overlay = OverlayWindow(screen: screen)
            let spaceIndex = getSpaceIndex(for: screen) ?? 0

            overlay.update(screenIndex: index, spaceIndex: spaceIndex, preferences: preferences)
            overlay.updatePosition(for: screen, position: preferences.position)
            overlay.show()

            overlayWindows[uuid] = overlay
            screenSpaceCache[uuid] = (screenIndex: index, spaceIndex: spaceIndex)
        }

        log("Showed overlays for \(screens.count) screens")
    }

    private func hideOverlays() {
        for (_, overlay) in overlayWindows {
            overlay.close()  // 使用 close() 完全关闭窗口，而不是仅隐藏
        }
        overlayWindows.removeAll()
        log("Hid all overlays")
    }

    private func updateOverlayPositions() {
        let screens = NSScreen.screens

        for screen in screens {
            let uuid = uuidForScreen(screen)

            if let overlay = overlayWindows[uuid] {
                overlay.updatePosition(for: screen, position: preferences.position)
            }
        }
    }

    private func refreshSpaceIndices(force: Bool = false) {
        guard preferences.isEnabled else { return }

        if force {
            log("[refreshSpaceIndices] Force refresh requested, clearing screenSpaceCache")
            screenSpaceCache.removeAll()
        }

        let screens = NSScreen.screens
        var needsRefresh = false
        var changedScreens: [String] = []

        for (index, screen) in screens.enumerated() {
            let uuid = uuidForScreen(screen)

            let currentSpaceIndex = getSpaceIndex(for: screen) ?? 0

            if let cached = screenSpaceCache[uuid] {
                if cached.screenIndex != index || cached.spaceIndex != currentSpaceIndex {
                    needsRefresh = true
                    changedScreens.append("Screen\(index): \(cached.spaceIndex)->\(currentSpaceIndex)")
                    screenSpaceCache[uuid] = (screenIndex: index, spaceIndex: currentSpaceIndex)

                    if let overlay = overlayWindows[uuid] {
                        log("[refreshSpaceIndices] Updating overlay for screen \(index): spaceIndex \(currentSpaceIndex)")
                        overlay.update(screenIndex: index, spaceIndex: currentSpaceIndex, preferences: preferences)
                        overlay.updatePosition(for: screen, position: preferences.position)
                        overlay.show() // 确保窗口在最前面
                    }
                }
            } else {
                needsRefresh = true
                changedScreens.append("Screen\(index): new->\(currentSpaceIndex)")
                screenSpaceCache[uuid] = (screenIndex: index, spaceIndex: currentSpaceIndex)
            }
        }

        // 只有在屏幕数量变化时才需要重建窗口
        // 工作区索引变化已经在上面直接更新了 overlay
        if overlayWindows.count != screens.count {
            log("[refreshSpaceIndices] Screen count changed, refreshing overlays")
            refreshOverlays()
        } else if needsRefresh {
            log("[refreshSpaceIndices] Space indices updated: \(changedScreens.joined(separator: ", "))")
            // 工作区变化已经通过 overlay.update() 直接更新，不需要重建窗口
        } else if force {
            log("[refreshSpaceIndices] Force refresh but no changes detected")
        }
    }

    // MARK: - Space Index Detection
    private func getSpaceIndex(for screen: NSScreen) -> Int? {
        let uuid = uuidForScreen(screen)

        // Check cache to prevent redundant queries within debounce interval (per screen)
        if let lastQuery = lastQueryTimes[uuid],
           Date().timeIntervalSince(lastQuery) < queryDebounceInterval,
           let cached = cachedSpaceIndices[uuid] {
            log("Using cached space index for screen \(uuid): \(cached)")
            return cached
        }

        // Try to get from yabai first
        let result: Int?
        log("Querying space index for screen \(uuid)...")
        if let yabaiIndex = getYabaiSpaceIndex(for: screen) {
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

    private func getYabaiPath() -> String? {
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

    private var cachedYabaiPath: String? = nil

    private func getYabaiPathFromUserShell() -> String? {
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

    private func getYabaiDisplayIndex(for screen: NSScreen) -> Int? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            log("Could not get screenNumber from deviceDescription")
            return nil
        }
        let targetDisplayID = screenNumber.uint32Value
        log("Looking for yabai display with ID: \(targetDisplayID)")

        guard let yabaiPath = getYabaiPath() else {
            log("yabai binary not found")
            return nil
        }
        log("Using yabai at: \(yabaiPath)")

        let task = Process()
        task.launchPath = yabaiPath
        task.arguments = ["-m", "query", "--displays"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorPipe = task.standardError as? Pipe
            if let stderr = errorPipe?.fileHandleForReading.readDataToEndOfFile(),
               let errStr = String(data: stderr, encoding: .utf8), !errStr.isEmpty {
                log("yabai displays query stderr: \(errStr)")
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                log("Failed to parse yabai displays JSON")
                if let str = String(data: data, encoding: .utf8) {
                    log("Raw output: \(str)")
                }
                return nil
            }

            log("yabai returned \(json.count) displays")
            for (i, display) in json.enumerated() {
                let id = display["id"] as? UInt32 ?? 0
                let index = display["index"] as? Int ?? 0
                log("Display \(i): id=\(id), index=\(index)")
            }

            // Find the display with matching CGDirectDisplayID
            if let display = json.first(where: {
                ($0["id"] as? UInt32) == targetDisplayID
            }) {
                let idx = display["index"] as? Int
                log("Found matching display with index: \(idx ?? -1)")
                return idx
            }

            log("No matching display found for ID \(targetDisplayID)")
        } catch {
            log("Failed to get yabai display index: \(error)")
        }

        return nil
    }

    private func getYabaiSpaceIndex(for screen: NSScreen) -> Int? {
        // Get the yabai display index for this screen
        guard let displayIndex = getYabaiDisplayIndex(for: screen) else {
            log("Could not get yabai display index for screen")
            return nil
        }

        log("Querying spaces for display index: \(displayIndex)")

        guard let yabaiPath = getYabaiPath() else {
            log("yabai binary not found for space query")
            return nil
        }

        // Get spaces for this specific display
        let task = Process()
        task.launchPath = yabaiPath
        task.arguments = ["-m", "query", "--spaces", "--display", "\(displayIndex)"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                log("Failed to parse yabai spaces JSON for display \(displayIndex)")
                if let str = String(data: data, encoding: .utf8) {
                    log("Raw spaces output: \(str)")
                }
                return nil
            }

            log("yabai returned \(json.count) spaces for display \(displayIndex)")
            for (i, space) in json.enumerated() {
                let idx = space["index"] as? Int ?? 0
                // Handle both Bool and Int types (yabai returns Bool in newer versions)
                let visible: Bool
                let focused: Bool
                if let visibleBool = space["is-visible"] as? Bool {
                    visible = visibleBool
                } else {
                    visible = (space["is-visible"] as? Int ?? 0) == 1
                }
                if let focusedBool = space["has-focus"] as? Bool {
                    focused = focusedBool
                } else {
                    focused = (space["has-focus"] as? Int ?? 0) == 1
                }
                log("Space \(i): index=\(idx), is-visible=\(visible), has-focus=\(focused)")
            }

            // Find the visible or focused space on this display
            if let activeSpaceIndex = json.firstIndex(where: {
                // Handle both Bool and Int types
                if let visible = $0["is-visible"] as? Bool {
                    return visible
                }
                return ($0["is-visible"] as? Int ?? 0) == 1
            }) ?? json.firstIndex(where: {
                if let focused = $0["has-focus"] as? Bool {
                    return focused
                }
                return ($0["has-focus"] as? Int ?? 0) == 1
            }) {
                // 返回屏幕级别的工作区索引（1-based）
                // 比如：屏幕2的第1个工作区，显示 1 而不是全局索引 4
                let localSpaceIndex = activeSpaceIndex + 1
                let globalSpaceIndex = json[activeSpaceIndex]["index"] as? Int ?? 0

                log("Found yabai space: local=\(localSpaceIndex), global=\(globalSpaceIndex)")
                return localSpaceIndex
            }

            log("No visible/focused space found for display \(displayIndex)")
        } catch {
            log("Failed to get yabai space index: \(error)")
        }

        return nil
    }

    private func getCGSpaceIndex(for screen: NSScreen) -> Int? {
        // Try to get space info from Core Graphics
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        _ = screenNumber

        // This is a simplified approach - full implementation would need more complex CG API usage
        // For now, return nil to indicate we couldn't get system index
        return nil
    }

    deinit {
        // Timer invalidation must be done on MainActor
        // Since this is a singleton, deinit is rarely called
        // The timer will be cleaned up when the app exits
    }

    // MARK: - Cleanup
    func unregisterYabaiSignals() {
        guard let yabaiPath = getYabaiPath() else { return }

        let task = Process()
        task.launchPath = yabaiPath
        task.arguments = ["-m", "signal", "--remove", "vibefocus-space-changed"]
        task.launch()
        task.waitUntilExit()

        log("Unregistered yabai signals")
    }
}
