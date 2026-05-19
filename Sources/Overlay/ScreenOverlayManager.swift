import AppKit
import Foundation
import Darwin  // for signal.h

// MARK: - Screen Overlay Manager
@MainActor
class ScreenOverlayManager: ObservableObject {
    static let shared = ScreenOverlayManager()

    static var signalSource: DispatchSourceSignal?

    @Published var preferences: ScreenIndexPreferences {
        didSet {
            schedulePreferenceSave()
            schedulePreferenceRefresh()
        }
    }

    var overlayWindows: [UUID: OverlayWindow] = [:]
    var screenSpaceCache: [UUID: (screenIndex: Int, spaceIndex: Int)] = [:]
    var refreshTimer: Timer?
    var pendingSignalRefreshWorkItems: [DispatchWorkItem] = []
    var pendingPreferenceRefreshWorkItem: DispatchWorkItem?
    var pendingPreferenceSaveWorkItem: DispatchWorkItem?
    var workspaceSpaceChangeObserver: NSObjectProtocol?
    var swipeEventMonitor: Any?
    var lastForceRefreshTriggerAt: Date = .distantPast
    var lastSwipeTriggerAt: Date = .distantPast

    // Query result caching to prevent redundant yabai calls
    var cachedDisplayIndices: [UUID: Int] = [:]
    var lastQueryTimes: [UUID: Date] = [:]  // Per-screen query time tracking
    let queryDebounceInterval: TimeInterval = 0.05  // 50ms debounce - 减少延迟
    let signalFollowUpRefreshDelays: [TimeInterval] = [0.03, 0.1]
    let preferenceRefreshDebounceInterval: TimeInterval = 0.08
    let preferenceSaveDebounceInterval: TimeInterval = 0.2
    let yabaiCommandTimeout: TimeInterval = 0.22
    let minForceRefreshTriggerInterval: TimeInterval = 0.06
    let minSwipeTriggerInterval: TimeInterval = 0.12
    let singleScreenFallbackRefreshInterval: TimeInterval = 0.35
    let multiScreenFallbackRefreshInterval: TimeInterval = 0.8
    var automaticRefreshSuspended = false
    var lastLoggedPreferenceSignature: String?

    private init() {
        self.preferences = ScreenIndexPreferences.load()
        log("ScreenOverlayManager initialized, isEnabled=\(preferences.isEnabled)")
        log("ScreenOverlayManager.init entry", level: .debug, fields: ["isEnabled": String(preferences.isEnabled), "position": preferences.position.rawValue])
        // setupScreenNotifications() - DISABLED: causing crashes
        setupSignalHandler()
        registerYabaiSignals()
        startRefreshTimer()
        log("ScreenOverlayManager.init exit", level: .debug)
    }

    // MARK: - Signal Handling


    // MARK: - Setup
    func setupScreenNotifications() {
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

    func startRefreshTimer() {
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
        log("ScreenOverlayManager.setEnabled entry", level: .debug, fields: ["enabled": String(enabled), "wasEnabled": String(preferences.isEnabled)])
        preferences.isEnabled = enabled
        if enabled {
            log("ScreenOverlayManager.setEnabled branch: showing overlays", level: .debug)
            showOverlays()
        } else {
            log("ScreenOverlayManager.setEnabled branch: hiding overlays", level: .debug)
            hideOverlays()
        }
        log("ScreenOverlayManager.setEnabled exit", level: .debug, fields: ["enabled": String(enabled)])
    }

    func updatePosition(_ position: IndexPosition) {
        log("ScreenOverlayManager.updatePosition entry", level: .debug, fields: ["position": position.rawValue, "previousPosition": preferences.position.rawValue])
        preferences.position = position
        updateOverlayPositions()
        log("ScreenOverlayManager.updatePosition exit", level: .debug, fields: ["position": position.rawValue])
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
            log("ScreenOverlayManager.suspendAutomaticRefreshes already suspended", level: .debug, fields: ["reason": reason])
            return
        }
        automaticRefreshSuspended = true
        refreshTimer?.invalidate()
        refreshTimer = nil
        log("Suspended automatic overlay refreshes: \(reason)")
        log("ScreenOverlayManager.suspendAutomaticRefreshes exit", level: .debug, fields: ["reason": reason])
    }

    func resumeAutomaticRefreshes(reason: String) {
        guard automaticRefreshSuspended else {
            log("ScreenOverlayManager.resumeAutomaticRefreshes not suspended", level: .debug, fields: ["reason": reason])
            return
        }
        automaticRefreshSuspended = false
        startRefreshTimer()
        log("Resumed automatic overlay refreshes: \(reason)")
        log("ScreenOverlayManager.resumeAutomaticRefreshes exit", level: .debug, fields: ["reason": reason])
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


    // MARK: - Space Index Detection

    // MARK: - Per-Screen Space Indexing


    var cachedYabaiPath: String? = nil


    func queryYabaiSpaces(forDisplayIndex displayIndex: Int, yabaiPath: String) -> [SpaceSnapshot]? {
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

    func queryFocusedSpaceIndex(yabaiPath: String) -> Int? {
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

    func getCGSpaceIndex(for screen: NSScreen) -> Int? {
        log("ScreenOverlayManager.getCGSpaceIndex entry", level: .debug, fields: ["screenFrame": String(describing: screen.frame)])
        // Try to get space info from Core Graphics
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            log("ScreenOverlayManager.getCGSpaceIndex no screen number", level: .debug)
            return nil
        }

        _ = screenNumber

        // This is a simplified approach - full implementation would need more complex CG API usage
        // For now, return nil to indicate we couldn't get system index
        log("ScreenOverlayManager.getCGSpaceIndex returning nil (not implemented)", level: .debug)
        return nil
    }

    deinit {
        log("ScreenOverlayManager.deinit called", level: .debug)
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
