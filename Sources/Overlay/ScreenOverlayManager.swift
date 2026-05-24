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
    var lastForceRefreshTriggerAt: Date = .distantPast

    var cachedDisplayIndices: [UUID: Int] = [:]
    var lastQueryTimes: [UUID: Date] = [:]
    let queryDebounceInterval: TimeInterval = 0.05
    let signalFollowUpRefreshDelays: [TimeInterval] = [0.03, 0.1]
    let preferenceRefreshDebounceInterval: TimeInterval = 0.08
    let preferenceSaveDebounceInterval: TimeInterval = 0.2
    let yabaiCommandTimeout: TimeInterval = 0.22
    let minForceRefreshTriggerInterval: TimeInterval = 0.06
    let singleScreenFallbackRefreshInterval: TimeInterval = 0.35
    let multiScreenFallbackRefreshInterval: TimeInterval = 0.8
    var automaticRefreshSuspended = false
    var lastLoggedPreferenceSignature: String?

    private init() {
        self.preferences = ScreenIndexPreferences.load()
        log("ScreenOverlayManager initialized, isEnabled=\(preferences.isEnabled)")
        setupSignalHandler()
        registerYabaiSignals()
        startRefreshTimer()
    }

    // MARK: - Setup

    func startRefreshTimer() {
        if automaticRefreshSuspended {
            return
        }
        let interval = NSScreen.screens.count <= 1
            ? singleScreenFallbackRefreshInterval
            : multiScreenFallbackRefreshInterval

        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSpaceIndices()
            }
        }
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
        pendingPreferenceSaveWorkItem?.cancel()
        pendingPreferenceSaveWorkItem = nil
        preferences.save()
    }

    // MARK: - Private Methods

    // MARK: - Space Index Detection

    // MARK: - Per-Screen Space Indexing

    func queryYabaiSpaces(forDisplayIndex displayIndex: Int, yabaiPath: String) -> [SpaceSnapshot]? {
        guard let result = YabaiClient.run(arguments: ["-m", "query", "--spaces", "--display", "\(displayIndex)"]),
              result.exitCode == 0 else {
            log("queryYabaiSpaces: yabai query failed")
            return nil
        }

        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            log("queryYabaiSpaces: failed to parse yabai spaces JSON")
            return nil
        }

        return json.compactMap { space in
            guard let index = space["index"] as? Int else {
                return nil
            }
            let visible = (space["is-visible"] as? Bool) ?? ((space["is-visible"] as? Int ?? 0) == 1)
            let hasFocus = (space["has-focus"] as? Bool) ?? ((space["has-focus"] as? Int ?? 0) == 1)
            return SpaceSnapshot(index: index, isVisible: visible, hasFocus: hasFocus)
        }
    }

    func queryFocusedSpaceIndex(yabaiPath: String) -> Int? {
        guard let result = YabaiClient.run(arguments: ["-m", "query", "--spaces", "--space"]),
              result.exitCode == 0 else {
            log("queryFocusedSpaceIndex: yabai query failed")
            return nil
        }

        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let index = json["index"] as? Int else {
            return nil
        }
        return index
    }

    deinit {
        // Singleton — deinit rarely called; timer cleaned up on app exit
    }

    // MARK: - Cleanup
    func unregisterYabaiSignals() {
        let _ = YabaiClient.run(arguments: ["-m", "signal", "--remove", "vibefocus-space-changed"])
    }
}
