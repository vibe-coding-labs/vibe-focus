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
    private var lastQueryTime: Date?
    private var cachedSpaceIndices: [UUID: Int] = [:]
    private let queryDebounceInterval: TimeInterval = 0.3  // 300ms debounce

    private init() {
        self.preferences = ScreenIndexPreferences.load()
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
            log("Received SIGUSR1, refreshing space indices")
            self?.refreshSpaceIndices()
        }
        source.resume()

        ScreenOverlayManager.signalSource = source
        log("Signal handler setup complete")
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

        // 获取脚本路径
        guard let scriptPath = Bundle.main.path(forResource: "yabai-space-changed", ofType: "sh") else {
            log("Could not find yabai-space-changed.sh script")
            return
        }

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
        // 降低轮询频率到10秒，作为fallback机制
        // 主要更新由 yabai 信号驱动
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSpaceIndices()
            }
        }
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
            overlay.hide()
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

    private func refreshSpaceIndices() {
        guard preferences.isEnabled else { return }

        let screens = NSScreen.screens
        var needsRefresh = false

        for (index, screen) in screens.enumerated() {
            let uuid = uuidForScreen(screen)

            let currentSpaceIndex = getSpaceIndex(for: screen) ?? 0

            if let cached = screenSpaceCache[uuid] {
                if cached.screenIndex != index || cached.spaceIndex != currentSpaceIndex {
                    needsRefresh = true
                    screenSpaceCache[uuid] = (screenIndex: index, spaceIndex: currentSpaceIndex)

                    if let overlay = overlayWindows[uuid] {
                        overlay.update(screenIndex: index, spaceIndex: currentSpaceIndex, preferences: preferences)
                        overlay.updatePosition(for: screen, position: preferences.position)
                    }
                }
            } else {
                needsRefresh = true
            }
        }

        if needsRefresh || overlayWindows.count != screens.count {
            refreshOverlays()
        }
    }

    // MARK: - Space Index Detection
    private func getSpaceIndex(for screen: NSScreen) -> Int? {
        let uuid = uuidForScreen(screen)

        // Check cache to prevent redundant queries within debounce interval
        if let lastQuery = lastQueryTime,
           Date().timeIntervalSince(lastQuery) < queryDebounceInterval,
           let cached = cachedSpaceIndices[uuid] {
            return cached
        }

        // Try to get from yabai first
        let result: Int?
        if let yabaiIndex = getYabaiSpaceIndex(for: screen) {
            log("Got space index from yabai: \(yabaiIndex)")
            result = yabaiIndex
        } else if let cgIndex = getCGSpaceIndex(for: screen) {
            log("Got space index from CG: \(cgIndex)")
            result = cgIndex
        } else {
            log("Could not get space index for screen, returning 0")
            result = nil
        }

        // Update cache
        lastQueryTime = Date()
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
                let visible = space["is-visible"] as? Int ?? 0
                let focused = space["has-focus"] as? Int ?? 0
                log("Space \(i): index=\(idx), is-visible=\(visible), has-focus=\(focused)")
            }

            // Find the visible or focused space on this display
            if let activeSpace = json.first(where: {
                ($0["is-visible"] as? Int) == 1
            }) ?? json.first(where: {
                ($0["has-focus"] as? Int) == 1
            }) {
                let globalSpaceIndex = activeSpace["index"] as? Int ?? 0

                // Find the position in the display's space list (0-based local index)
                if let localIndex = json.firstIndex(where: {
                    ($0["index"] as? Int) == globalSpaceIndex
                }) {
                    log("Found yabai space: global=\(globalSpaceIndex), local=\(localIndex)")
                    return localIndex
                }

                log("Found yabai space index for display \(displayIndex): \(globalSpaceIndex)")
                return globalSpaceIndex - 1  // Fallback: assume consecutive numbering
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
