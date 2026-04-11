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
            schedulePreferenceSave()
            schedulePreferenceRefresh()
        }
    }

    private var overlayWindows: [UUID: OverlayWindow] = [:]
    private var screenSpaceCache: [UUID: (screenIndex: Int, spaceIndex: Int)] = [:]
    private var refreshTimer: Timer?
    private var pendingSignalRefreshWorkItems: [DispatchWorkItem] = []
    private var pendingPreferenceRefreshWorkItem: DispatchWorkItem?
    private var pendingPreferenceSaveWorkItem: DispatchWorkItem?
    private var workspaceSpaceChangeObserver: NSObjectProtocol?
    private var swipeEventMonitor: Any?
    private var lastForceRefreshTriggerAt: Date = .distantPast
    private var lastSwipeTriggerAt: Date = .distantPast

    // Query result caching to prevent redundant yabai calls
    private var cachedSpaceIndices: [UUID: Int] = [:]
    private var cachedDisplayIndices: [UUID: Int] = [:]
    private var lastQueryTimes: [UUID: Date] = [:]  // Per-screen query time tracking
    private let queryDebounceInterval: TimeInterval = 0.05  // 50ms debounce - 减少延迟
    private let signalFollowUpRefreshDelays: [TimeInterval] = [0.03, 0.1]
    private let preferenceRefreshDebounceInterval: TimeInterval = 0.08
    private let preferenceSaveDebounceInterval: TimeInterval = 0.2
    private let yabaiCommandTimeout: TimeInterval = 0.22
    private let minForceRefreshTriggerInterval: TimeInterval = 0.06
    private let minSwipeTriggerInterval: TimeInterval = 0.12
    private let singleScreenFallbackRefreshInterval: TimeInterval = 0.35
    private let multiScreenFallbackRefreshInterval: TimeInterval = 0.8
    private var automaticRefreshSuspended = false
    private var lastLoggedPreferenceSignature: String?

    private init() {
        self.preferences = ScreenIndexPreferences.load()
        log("ScreenOverlayManager initialized, isEnabled=\(preferences.isEnabled)")
        // setupScreenNotifications() - DISABLED: causing crashes
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
            guard let self else {
                return
            }
            let timestamp = ISO8601DateFormatter().string(from: Date())
            log("[SIGUSR1] ====== WORKSPACE SWITCH DETECTED at \(timestamp) ======")
            self.triggerForceRefresh(reason: "sigusr1")
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

    private func cancelPendingSignalRefreshes() {
        for workItem in pendingSignalRefreshWorkItems {
            workItem.cancel()
        }
        pendingSignalRefreshWorkItems.removeAll()
    }

    private func scheduleSignalFollowUpRefreshes() {
        for (offset, delay) in signalFollowUpRefreshDelays.enumerated() {
            let isLast = offset == signalFollowUpRefreshDelays.count - 1
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else {
                    return
                }
                log("[SIGUSR1] Follow-up refresh (\(Int(delay * 1000))ms after signal)")
                self.refreshSpaceIndices(force: true)
                if isLast {
                    log("[SIGUSR1] ====== WORKSPACE SWITCH HANDLING COMPLETE ======")
                }
            }
            pendingSignalRefreshWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func triggerForceRefresh(reason: String) {
        guard !automaticRefreshSuspended else {
            log("[FORCE_REFRESH] Skipped while automatic refresh is suspended, reason=\(reason)")
            return
        }
        let now = Date()
        if now.timeIntervalSince(lastForceRefreshTriggerAt) < minForceRefreshTriggerInterval {
            log("[FORCE_REFRESH] Skip duplicated trigger reason=\(reason)")
            return
        }
        lastForceRefreshTriggerAt = now

        log("[FORCE_REFRESH] Triggered by reason=\(reason), clearing caches and refreshing")
        cancelPendingSignalRefreshes()
        clearSpaceIndexCache()

        log("[FORCE_REFRESH] Immediate refresh starting...")
        refreshSpaceIndices(force: true)
        scheduleSignalFollowUpRefreshes()
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

        workspaceSpaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else {
                return
            }
            log("[SPACE_NOTIFY] NSWorkspace activeSpaceDidChangeNotification")
            Task { @MainActor [weak self] in
                self?.triggerForceRefresh(reason: "nsworkspace_active_space")
            }
        }

        // DISABLED: Swipe event monitor causing crashes
        // swipeEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.swipe]) { [weak self] event in
        //     ...
        // }
    }

    private func startRefreshTimer() {
        if automaticRefreshSuspended {
            return
        }
        // Faster fallback on single display while keeping multi-display polling conservative.
        let interval = NSScreen.screens.count <= 1
            ? singleScreenFallbackRefreshInterval
            : multiScreenFallbackRefreshInterval

        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSpaceIndices()
            }
        }
        log("Started refresh timer with \(interval)s interval")
    }

    @objc private func handleScreenChange() {
        log("Screen configuration changed, refreshing overlays")
        cachedDisplayIndices.removeAll()
        cancelPendingSignalRefreshes()
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
        pendingPreferenceRefreshWorkItem?.cancel()
        pendingPreferenceRefreshWorkItem = nil
        log("refreshOverlays called, isEnabled=\(preferences.isEnabled)")
        hideOverlays()
        if preferences.isEnabled {
            showOverlays()
        }
    }

    func suspendAutomaticRefreshes(reason: String) {
        guard !automaticRefreshSuspended else {
            return
        }
        automaticRefreshSuspended = true
        refreshTimer?.invalidate()
        refreshTimer = nil
        log("Suspended automatic overlay refreshes: \(reason)")
    }

    func resumeAutomaticRefreshes(reason: String) {
        guard automaticRefreshSuspended else {
            return
        }
        automaticRefreshSuspended = false
        startRefreshTimer()
        log("Resumed automatic overlay refreshes: \(reason)")
    }

    func flushPendingPreferenceSave(reason: String = "manual_flush") {
        if pendingPreferenceSaveWorkItem != nil {
            log("Flushing pending preference save: \(reason)")
        }
        pendingPreferenceSaveWorkItem?.cancel()
        pendingPreferenceSaveWorkItem = nil
        preferences.save()
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

            let spaceIndex = getPerScreenSpaceIndex(for: screen) ?? 1
            log("[DEBUG] showOverlays: screen \(index), per-screen index=\(spaceIndex)")

            overlay.update(screenIndex: index, spaceIndex: spaceIndex, preferences: preferences)
            overlay.updatePosition(for: screen, position: preferences.position, margin: preferences.panelMargin)
            overlay.show()

            overlayWindows[uuid] = overlay
            screenSpaceCache[uuid] = (screenIndex: index, spaceIndex: spaceIndex)
        }

        log("Showed overlays for \(screens.count) screens")
    }

    private func schedulePreferenceSave() {
        pendingPreferenceSaveWorkItem?.cancel()
        let snapshot = preferences
        let signature = preferenceSignature(snapshot)
        if signature != lastLoggedPreferenceSignature {
            lastLoggedPreferenceSignature = signature
            log(
                "[Overlay] schedule preference save",
                fields: [
                    "signature": signature
                ]
            )
        }
        let workItem = DispatchWorkItem { [weak self] in
            let startedAt = Date()
            snapshot.save()
            self?.pendingPreferenceSaveWorkItem = nil
            logOperationDuration(
                "[Overlay] preference save finished",
                startedAt: startedAt,
                warnThresholdMs: 120,
                fields: [
                    "signature": signature
                ]
            )
        }
        pendingPreferenceSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + preferenceSaveDebounceInterval, execute: workItem)
    }

    private func schedulePreferenceRefresh() {
        pendingPreferenceRefreshWorkItem?.cancel()
        let signature = preferenceSignature(preferences)
        log(
            "[Overlay] schedule preference refresh",
            fields: [
                "signature": signature
            ]
        )

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.pendingPreferenceRefreshWorkItem = nil
            self.applyPreferenceRefresh(signature: signature)
        }

        pendingPreferenceRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + preferenceRefreshDebounceInterval, execute: workItem)
    }

    private func applyPreferenceRefresh(signature: String) {
        let startedAt = Date()
        guard preferences.isEnabled else {
            hideOverlays()
            logOperationDuration(
                "[Overlay] preference refresh finished",
                startedAt: startedAt,
                warnThresholdMs: 120,
                fields: [
                    "signature": signature,
                    "path": "hide_overlays"
                ]
            )
            return
        }

        if overlayWindows.isEmpty {
            showOverlays()
            logOperationDuration(
                "[Overlay] preference refresh finished",
                startedAt: startedAt,
                warnThresholdMs: 120,
                fields: [
                    "signature": signature,
                    "path": "show_overlays"
                ]
            )
            return
        }

        // Avoid closing/reopening all windows while the user drags sliders in settings.
        // Frequent teardown/rebuild caused unstable AppKit object churn.
        updateOverlaysInPlace()
        logOperationDuration(
            "[Overlay] preference refresh finished",
            startedAt: startedAt,
            warnThresholdMs: 120,
            fields: [
                "signature": signature,
                "path": "update_in_place",
                "overlayCount": String(overlayWindows.count)
            ]
        )
    }

    private func updateOverlaysInPlace() {
        let screens = NSScreen.screens
        var activeUUIDs: Set<UUID> = []

        for (index, screen) in screens.enumerated() {
            let uuid = uuidForScreen(screen)
            activeUUIDs.insert(uuid)
            let spaceIndex = screenSpaceCache[uuid]?.spaceIndex ?? (getPerScreenSpaceIndex(for: screen) ?? 1)

            if let overlay = overlayWindows[uuid] {
                overlay.update(screenIndex: index, spaceIndex: spaceIndex, preferences: preferences)
                overlay.updatePosition(for: screen, position: preferences.position, margin: preferences.panelMargin)
                overlay.show()
            } else {
                let overlay = OverlayWindow(screen: screen)
                overlay.update(screenIndex: index, spaceIndex: spaceIndex, preferences: preferences)
                overlay.updatePosition(for: screen, position: preferences.position, margin: preferences.panelMargin)
                overlay.show()
                overlayWindows[uuid] = overlay
            }

            screenSpaceCache[uuid] = (screenIndex: index, spaceIndex: spaceIndex)
        }

        let staleUUIDs = overlayWindows.keys.filter { !activeUUIDs.contains($0) }
        for uuid in staleUUIDs {
            overlayWindows[uuid]?.close()
            overlayWindows.removeValue(forKey: uuid)
            screenSpaceCache.removeValue(forKey: uuid)
        }

        log("Updated overlays in place for \(screens.count) screens")
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
                overlay.updatePosition(for: screen, position: preferences.position, margin: preferences.panelMargin)
            }
        }
    }

    private func preferenceSignature(_ preferences: ScreenIndexPreferences) -> String {
        "enabled=\(preferences.isEnabled)|pos=\(preferences.position.rawValue)|font=\(String(format: "%.1f", preferences.fontSize))|opacity=\(String(format: "%.2f", preferences.opacity))|scale=\(String(format: "%.2f", preferences.panelScale))|margin=\(String(format: "%.1f", preferences.panelMargin))"
    }

    private func refreshSpaceIndices(force: Bool = false) {
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

    // MARK: - Space Index Detection
    private func getSpaceIndex(for screen: NSScreen, preferStableSampling: Bool = false) -> Int? {
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

    // MARK: - Per-Screen Space Indexing
    private func getPerScreenSpaceIndex(for screen: NSScreen) -> Int? {
        guard let yabaiPath = getYabaiPath() else {
            return nil
        }

        guard let displayIndex = getYabaiDisplayIndex(for: screen) else {
            return nil
        }

        // Get all spaces for this display
        guard let displaySpaces = queryYabaiSpaces(forDisplayIndex: displayIndex, yabaiPath: yabaiPath),
              !displaySpaces.isEmpty else {
            return nil
        }

        // Get the currently focused space index
        guard let focusedSpaceIndex = queryFocusedSpaceIndex(yabaiPath: yabaiPath) else {
            return nil
        }

        // Find the position of the focused space in this display's spaces list
        // Sort spaces by their index to ensure consistent ordering
        let sortedSpaces = displaySpaces.sorted { $0.index < $1.index }

        // Find which position the focused space is in (1-based)
        for (position, space) in sortedSpaces.enumerated() {
            if space.index == focusedSpaceIndex {
                return position + 1  // 1-based index
            }
        }

        // If focused space is not on this display, find the visible one
        for (position, space) in sortedSpaces.enumerated() {
            if space.isVisible {
                return position + 1
            }
        }

        // Fallback: return 1
        return 1
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

    private func getYabaiSpaceIndex(for screen: NSScreen, preferStableSampling: Bool = false) -> Int? {
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

    private func queryYabaiSpaces(forDisplayIndex displayIndex: Int, yabaiPath: String) -> [SpaceSnapshot]? {
        let task = Process()
        task.launchPath = yabaiPath
        task.arguments = ["-m", "query", "--spaces", "--display", "\(displayIndex)"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            let semaphore = DispatchSemaphore(value: 0)
            task.terminationHandler = { _ in
                semaphore.signal()
            }
            let result = semaphore.wait(timeout: .now() + yabaiCommandTimeout)
            if result == .timedOut {
                log("yabai spaces query timed out")
                task.terminate()
                return nil
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                log("[DEBUG] Failed to parse yabai spaces JSON")
                return nil
            }

            log("[DEBUG] yabai --spaces --display \(displayIndex) returned \(json.count) spaces")
            let snapshots: [SpaceSnapshot] = json.compactMap { space in
                guard let index = space["index"] as? Int else {
                    return nil
                }
                let visible = (space["is-visible"] as? Bool) ?? ((space["is-visible"] as? Int ?? 0) == 1)
                let hasFocus = (space["has-focus"] as? Bool) ?? ((space["has-focus"] as? Int ?? 0) == 1)
                return SpaceSnapshot(index: index, isVisible: visible, hasFocus: hasFocus)
            }

            for (i, snapshot) in snapshots.enumerated() {
                log("[DEBUG]   Space \(i): index=\(snapshot.index), is-visible=\(snapshot.isVisible), has-focus=\(snapshot.hasFocus)")
            }

            return snapshots
        } catch {
            log("Failed to query yabai spaces for display: \(error)")
            return nil
        }
    }

    private func queryFocusedSpaceIndex(yabaiPath: String) -> Int? {
        let task = Process()
        task.launchPath = yabaiPath
        task.arguments = ["-m", "query", "--spaces", "--space"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            let semaphore = DispatchSemaphore(value: 0)
            task.terminationHandler = { _ in
                semaphore.signal()
            }
            let result = semaphore.wait(timeout: .now() + yabaiCommandTimeout)
            if result == .timedOut {
                log("yabai focused space query timed out")
                task.terminate()
                return nil
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let index = json["index"] as? Int else {
                return nil
            }
            return index
        } catch {
            log("Failed to query yabai focused space: \(error)")
            return nil
        }
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
