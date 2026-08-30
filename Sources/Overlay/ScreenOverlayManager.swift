import AppKit
import Foundation
import Darwin  // for signal.h

// MARK: - Screen Overlay Manager
/// Manages the always-on-top screen index overlay that labels windows by display.
@MainActor
final class ScreenOverlayManager: ObservableObject {
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
    // 屏幕配置变化（didChangeScreenParametersNotification）debounce work item。
    // 拔插屏时该通知常短时间内多次到达，立即重建 overlay 会与 refreshSpaceIndices
    // 后台 Task 竞争 WindowServer。debounce 合并连发，等配置稳定后重建一次。
    var pendingScreenChangeWorkItem: DispatchWorkItem?
    /// 屏幕变化通知 debounce 间隔。0.25s 合并拔插屏的多次连发（display removal +
    /// reconfiguration），又远低于人眼感知，避免在 WindowServer 重排中途重建 overlay。
    static let screenChangeDebounceInterval: TimeInterval = 1.0  // 增加到 1 秒，给 WindowServer 足够时间稳定

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

    /// 崩溃循环熔断开关（2026-08-31 修复）。
    ///
    /// ## 场景
    /// - init 时检测 60s 内是否有致命信号记录（CrashContextRecorder.capturePreviousCrashFatalDate
    ///   在 AppDelegate 启动最早期捕获），命中则置位；
    /// - 置位后禁止创建 overlay 窗口（showOverlays/updateOverlaysInPlace no-op、不起刷新
    ///   Timer），切断"启动→创建 overlay→SIGSEGV→keepalive 10s 拉起→再崩"的循环
    ///   （7-18、8-10 归档每 10 秒一条 crash-fatal 实证）；
    /// - 只挡窗口创建：菜单栏/热键/hook 等功能不受影响；下次启动无新崩溃即自动恢复。
    var crashLoopSuppressed = false

    private init() {
        self.preferences = ScreenIndexPreferences.load()
        // init() 只读不写：持久化完全由 didSet → save() 在用户实际修改时驱动。
        // 历史上这里曾有启动期 save()（无条件 → guarded backfill），在 SQLite 瞬时
        // 读取失败时会用 load() 的 fallback 陈旧默认覆盖 SQLite 真实配置
        // （bottomRight→topRight 反复几十次）。彻底移除启动期写路径，根除此类回归。
        log("ScreenOverlayManager initialized, isEnabled=\(preferences.isEnabled)")
        crashLoopSuppressed = CrashContextRecorder.shared.isWithinCrashLoopWindow()
        if crashLoopSuppressed {
            log("[ScreenOverlayManager] CRASH LOOP detected (fatal signal within 60s), overlay window creation suppressed for this launch", level: .error)
        }
        setupSignalHandler()
        registerYabaiSignals()
        // 屏幕配置变化（显示器插拔/重排）主动响应。此前 handleScreenChange 是死代码
        // （从未注册 observer），屏幕变化全靠 refreshSpaceIndices 的 2s Timer 轮询被动发现，
        // 把后台 Task 跨 race 的窗口放大到秒级。注册后由系统通知即时触发（debounce 0.25s）。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
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
        guard crashLoopSuppressed == false else {
            log("[Overlay] startRefreshTimer skipped (crash loop suppression)", level: .debug)
            return
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
        // 防抖：didChangeScreenParametersNotification 在拔插屏时常短时间内多次到达
        // （display removal + display reconfiguration + 应用窗口重排）。
        //
        // 崩溃根因（2026-08-10 SIGSEGV 循环）：此前此路径调 refreshOverlays() →
        // hideOverlays()(close 全部 NSWindow + removeAll 立即释放) + showOverlays()(创建全部
        // 新 NSWindow + orderFrontRegardless)。在屏幕重排期间对 N 个窗口执行 close+重建 =
        // 2N 次 WindowServer 窗口操作，与 WindowServer 自身的异步重排/释放竞争 → SIGSEGV。
        // 决定性证据：崩溃前最后日志 `[Overlay] showOverlays finished` 已打印，崩溃在返回后、
        // 本函数 finished 日志之前。
        //
        // 修复：改用 updateOverlaysInPlace() 就地更新。当屏幕 UUID 集合不变（绝大多数情况——
        // 应用前台切换、Electron 窗口重排触发的 didChangeScreenParametersNotification 并未真正
        // 拔插屏）时，零 close 零创建，只 update 内容，彻底消除 WindowServer 竞争。仅当屏幕
        // 真正增减时才对消失的屏幕 close、对新屏幕创建。
        // P-INST-126: 屏幕配置变化处理耗时归因（清缓存 + cancelPendingSignalRefreshes +
        // updateOverlaysInPlace P-INST-74 就地更新 overlay；NSApplication.didChangeScreenParametersNotification 触发）。

        // FIX: 屏幕变化是高风险操作，崩溃时需要诊断数据
        updateCrashSnapshotFromRuntime()

        pendingScreenChangeWorkItem?.cancel()
        let startedAt = Date()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            log("Screen configuration changed, refreshing overlays")
            self.cachedDisplayIndices.removeAll()
            self.cancelPendingSignalRefreshes()
            // 禁用偏好未启用时不操作窗口，避免无谓的 WindowServer 交互
            guard self.preferences.isEnabled, !self.crashLoopSuppressed else {
                log("[ScreenOverlayManager] handleScreenChange skipped (overlay disabled or crash loop suppression)", level: .debug)
                return
            }
            self.updateOverlaysInPlace()
            log("[ScreenOverlayManager] handleScreenChange finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: startedAt))
            ])
        }
        pendingScreenChangeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ScreenOverlayManager.screenChangeDebounceInterval, execute: work)
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

    // Space 查询/刷新已分层：I/O 见 +SpaceQuery.swift，编排见 +Refresh.swift，
    // 纯类型与解析见 SpaceSnapshot.swift（2026-08-31 拆分；同步查询死代码一并移除）。

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
