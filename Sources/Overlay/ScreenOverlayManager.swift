import AppKit
import Foundation
import Darwin  // for signal.h

// MARK: - Screen Overlay Manager
/// Manages the always-on-top screen index overlay that labels windows by display.
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
    // P3.6: toggle 后 force refresh 的 debounce work item。toggle 的 yabai `window --space`(focus=false)
    // 只移窗口不改可见 space，overlay 编号本就不变；连续 toggle（主场景）每次触发 force refresh 会堆积
    // 后台 yabai query，占用单进程 yabai，导致下次 toggle 的同步 captureSpaceContext/visibleSpaceIndex
    // fork 排队（实测前置 query 650ms + p2SpaceMoveMs 6→36ms）。debounce：连续 toggle 取消前一个，只在
    // toggle 停止 300ms 后刷新一次（20 toggle 60 refresh → 1 refresh），释放 yabai 给 toggle 热路径。
    var pendingPostToggleRefreshWorkItem: DispatchWorkItem?

    var cachedDisplayIndices: [UUID: Int] = [:]
    var lastQueryTimes: [UUID: Date] = [:]
    let queryDebounceInterval: TimeInterval = 0.05
    // 无 follow-up：SIGUSR1 由 yabai space_changed 事件触发，yabai 在 space 状态更新完成后才发信号，
    // VibeFocus 收到时 query --spaces 拿到的 focused/visible 必然是稳态值——第一次 fast path 即正确
    // （实测 2026-06-28 19:08Z 真实切屏 fast path 15-27ms 命中，follow-up 未纠正任何结果，focused
    // 与主 refresh 完全相同）。删 follow-up：切屏 yabai fork 2→1，overlay 编号更新 ~192ms→~27ms。
    // 兜底：偶发 yabai 信号延迟由 multiScreenFallbackRefreshInterval(2s) 定时器 + 下次 SIGUSR1 纠正。
    // 演进：[0.03, 0.1]=3 次 → [0.18]=1 次 → []=0 次。
    let signalFollowUpRefreshDelays: [TimeInterval] = []
    let preferenceRefreshDebounceInterval: TimeInterval = 0.08
    let preferenceSaveDebounceInterval: TimeInterval = 0.2
    let yabaiCommandTimeout: TimeInterval = 0.22
    // SIGUSR1 force-refresh trigger 去抖。切屏时 yabai space_changed 信号在切换动画期间常短时间内
    // 多次到达，0.06s 过短会让连续切屏每次都全量 fork yabai 造成雪崩。0.12s 合并 100ms 内连发信号，
    // 配合全量 query 快速路径显著降低切屏卡顿（仍低于人眼对 overlay 编号更新的感知阈值）。
    let minForceRefreshTriggerInterval: TimeInterval = 0.12
    let singleScreenFallbackRefreshInterval: TimeInterval = 0.35
    // 多屏兜底定时器：SIGUSR1 是 workspace switch 主驱动，定时器仅兜底 signal 遗漏。
    // 0.8s 过激进（空闲时持续 fork yabai），2.0s 足够覆盖遗漏场景。
    let multiScreenFallbackRefreshInterval: TimeInterval = 2.0
    var automaticRefreshSuspended = false
    var lastLoggedPreferenceSignature: String?

    private init() {
        self.preferences = ScreenIndexPreferences.load()
        // init() 只读不写：持久化完全由 didSet → save() 在用户实际修改时驱动。
        // 历史上这里曾有启动期 save()（无条件 → guarded backfill），在 SQLite 瞬时
        // 读取失败时会用 load() 的 fallback 陈旧默认覆盖 SQLite 真实配置
        // （bottomRight→topRight 反复几十次）。彻底移除启动期写路径，根除此类回归。
        log("ScreenOverlayManager initialized, isEnabled=\(preferences.isEnabled)")
        setupSignalHandler()
        registerYabaiSignals()
        startRefreshTimer()
    }

    // MARK: - Setup

    func startRefreshTimer() {
        // P-INST-217: overlay 刷新定时器创建耗时（NSScreen.screens.count + Timer.scheduledTimer 注册；启动 + 屏幕配置变化调用；slow-op ≥30ms warn）。
        let srtStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: srtStart)
            if durMs >= 30 { log("[Overlay] startRefreshTimer slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
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
        // P-INST-126: 屏幕配置变化处理耗时（清缓存 + cancelPendingSignalRefreshes + refreshOverlays P-INST-123 重建 overlay；NSApplication.didChangeScreenParametersNotification 触发，显示器热插拔时调用）。
        let hscStart = Date()
        defer {
            log("[ScreenOverlayManager] handleScreenChange finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: hscStart))
            ])
        }
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
        // P-INST-123: overlay UI 刷新耗时（cancel pending work item + hideOverlays + isEnabled 检查 + showOverlays P-INST-74 重建窗口；screen 变化 handleScreenChange P-INST-126 + space 刷新 applyRefreshResults P-INST-42 + toggle 后调用）。
        let roStart = Date()
        defer {
            log("[ScreenOverlayManager] refreshOverlays finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: roStart))
            ])
        }
        pendingPreferenceRefreshWorkItem?.cancel()
        pendingPreferenceRefreshWorkItem = nil
        hideOverlays()
        if preferences.isEnabled {
            showOverlays()
        }
    }

    func suspendAutomaticRefreshes(reason: String) {
        // P-INST-259: overlay 自动刷新挂起（refreshTimer.invalidate Timer 停止 + 状态置位；设置窗口获焦/toggle 期间调用，归因挂起时机）。
        let sarStart = Date()
        defer {
            log("[Overlay] suspendAutomaticRefreshes finished", level: .debug, fields: ["reason": reason, "durationMs": String(elapsedMilliseconds(since: sarStart))])
        }
        guard !automaticRefreshSuspended else {
            return
        }
        automaticRefreshSuspended = true
        refreshTimer?.invalidate()
        refreshTimer = nil
        log("Suspended automatic overlay refreshes: \(reason)")
    }

    func resumeAutomaticRefreshes(reason: String) {
        // P-INST-260: overlay 自动刷新恢复（startRefreshTimer P-INST-217 Timer 重建 + 状态置位；设置窗口失焦/toggle 结束后调用）。
        let rarStart = Date()
        defer {
            log("[Overlay] resumeAutomaticRefreshes finished", level: .debug, fields: ["reason": reason, "durationMs": String(elapsedMilliseconds(since: rarStart))])
        }
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
        // P-INST-124: 单 display space 查询耗时（YabaiClient.run -m query --spaces --display fork P-INST-37 + JSONSerialization 解析 + compactMap 构造 SpaceSnapshot；refreshSpaceIndices 每 display 调用，overlay space 索引刷新）。
        let qysStart = Date()
        defer {
            log("[ScreenOverlayManager] queryYabaiSpaces finished", level: .debug, fields: [
                "displayIndex": String(displayIndex),
                "durationMs": String(elapsedMilliseconds(since: qysStart))
            ])
        }
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
        // P-INST-125: 焦点 space 索引查询耗时（YabaiClient.run -m query --spaces --space fork P-INST-37 + JSONSerialization 解析取 index；refreshSpaceIndices 调用，overlay 焦点 space 归因）。
        let qfsiStart = Date()
        defer {
            log("[ScreenOverlayManager] queryFocusedSpaceIndex finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: qfsiStart))
            ])
        }
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
        // P-INST-127: yabai 信号注销耗时（YabaiClient.run -m signal --remove fork P-INST-37；registerYabaiSignals P-INST-93 的逆操作，禁用 overlay/卸载时调用）。
        let uysStart = Date()
        defer {
            log("[ScreenOverlayManager] unregisterYabaiSignals finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: uysStart))
            ])
        }
        let _ = YabaiClient.run(arguments: ["-m", "signal", "--remove", "vibefocus-space-changed"])
    }
}
