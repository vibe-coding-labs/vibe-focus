import AppKit
import Combine
import Foundation

// 类型定义已移至 SpaceController+Types.swift
// Yabai 执行逻辑已移至 SpaceController+Yabai.swift

final class SpaceController: ObservableObject {
    static let shared = SpaceController()

    @Published var availability: SpaceAvailability = .unknown
    @Published var lastErrorMessage: String?
    @Published private(set) var isEnabled: Bool = false
    @Published var canControlSpaces: Bool = false

    private var lastCheckAt: Date?
    private var cachedYabaiPath: String?
    var didAttemptScriptingAdditionRecovery = false
    var scriptingAdditionRecoverySucceeded = false
    private let checkInterval: TimeInterval = 20
    /// 周期 health check timer — 从启动 fork 竞争等瞬态失败自动恢复 isEnabled
    private var healthCheckTimer: Timer?

    // MARK: - Query Cache (per-toggle lifecycle)

    /// 查询缓存 TTL — 短到不会错过 yabai 状态变化，长到覆盖一次 toggle 操作
    private static let queryCacheTTL: TimeInterval = 2.0

    /// 缓存 queryWindow 结果 — key 是 windowID
    var windowQueryCache: [UInt32: (result: YabaiWindowInfo?, cachedAt: Date)] = [:]
    /// 缓存 querySpaces 结果
    var spacesQueryCache: (result: [YabaiSpaceInfo]?, cachedAt: Date)?

    /// 清除所有查询缓存 — 每次 toggle 操作结束后调用
    func clearQueryCache() {
        windowQueryCache.removeAll()
        spacesQueryCache = nil
    }

    /// 仅清除 queryWindow 缓存，保留 spacesQueryCache。
    /// 用于 moveWindowToMainScreen（yabai space move focus=false）：只改窗口 space/display，
    /// 不切任何 display 的 visible space（visible/index/display 映射不变），spacesQueryCache 保留
    /// 供连续 toggle 的 captureSpaceContext 命中省 querySpaces fork（整机卡时 ~54ms→~0ms）。
    /// 安全性：spacesQueryCache 的 has-focus 字段在 SpaceController 侧无消费方（仅 overlay 层
    /// SpaceSnapshot 读 has-focus，用独立查询不读此缓存），toggle 后 has-focus 陈旧不影响任何
    /// SpaceController 调用方（captureSpaceContext/displayLocalSpaceIndex/nativeSpaceID/visibleSpaceIndex
    /// 只用 index/display/is-visible/id，focus=false 下均不变）。restore 路径仍用 clearQueryCache。
    func clearWindowQueryCache() {
        windowQueryCache.removeAll()
    }

    /// 检查缓存是否过期
    func isCacheExpired(_ cachedAt: Date) -> Bool {
        return Date().timeIntervalSince(cachedAt) > Self.queryCacheTTL
    }

    /// 几何匹配表缓存（1s TTL：move/restore/grid 投递热路径每窗查询，fork 成本必须摊销；
    /// 显示器拓扑变化由 didChangeScreenParametersNotification 即时失效）。
    struct DisplayMatchTable {
        let mappedAt: Date
        let yabaiIndexByCGDisplayID: [CGDirectDisplayID: Int]
        let cgDisplayIDByYabaiIndex: [Int: CGDirectDisplayID]
    }
    // 模块内可见（extension 跨文件读写；单 target 无外泄面）
    var displayMatchTable: DisplayMatchTable?

    private init() {
        // 启动后多次重试 refreshAvailability，覆盖启动 fork 竞争窗口。
        // 启动时 overlay refresh / hook check / querySpaces 并发 fork yabai，可能某次
        // query --spaces Process.launch 失败 → isEnabled=false。moveWindow/setWindowFloat
        // 都 gate on isEnabled，卡 false 会阻断所有 toggle。多次重试确保从瞬态失败恢复。
        for delay in [0.5, 4.0, 12.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshAvailability(force: true)
            }
        }
        // 周期 health check：运行中 fork 失败或 yabai 重启后自动恢复 isEnabled。
        // 每 60s force 重查一次（~30ms fork），确保 isEnabled 不长期卡 false。
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAvailability(force: true) }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        healthCheckTimer = timer
        // 显示器拓扑变化即失效几何匹配表（exactYabaiDisplayIndex/exactNSScreen 的 1s
        // TTL 缓存）：插拔/合盖后旧映射立即可错，不能等 TTL 自然过期。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.invalidateDisplayMatchTable() }
        }
    }

    deinit {}

    func updateEnabledState() {
        let newValue = SpacePreferences.integrationEnabled && availability == .available
        if isEnabled != newValue {
            isEnabled = newValue
            log("[SpaceController] isEnabled changed", fields: ["newValue": String(newValue)])
        }
    }

    func refreshAvailabilityIfNeeded() {
        refreshAvailability(force: false)
    }

    /// B180：availability 刷新完全后台化。原实现在调用线程（主线程）同步跑两次
    /// yabai fork（query --spaces + SA 探针），yabai 忙时实测 1~3s/次、每 20s 节流窗
    /// 口一次——真机看门狗首个战果（[PERF][STALL] 1.39s/2.44s 归因）。现结构：
    /// 节流判定与路径解析即时返回；两个 fork 在后台 utility 线程执行（区间
    /// availability.refresh 落在后台线程，主线程停顿日志不再出现它）；结果经
    /// MainActor.run 应用（@Published 状态保持在主线程变更，SwiftUI 语义不变）。
    /// 探测期间 availability 保持旧值——调用方（设置页/编排热路径）拿到的仍是
    /// 最近一次探测结果，与原节流语义一致。
    func refreshAvailability(force: Bool) {
        let raStart = Date()
        var raResult = "throttled"
        defer {
            log("[SpaceController] refreshAvailability finished", level: .debug, fields: [
                "force": String(force),
                "result": raResult,
                "durationMs": String(elapsedMilliseconds(since: raStart))
            ])
        }
        if !force, let lastCheckAt, Date().timeIntervalSince(lastCheckAt) < checkInterval {
            return
        }

        lastCheckAt = Date()
        lastErrorMessage = nil

        guard let yabaiPath = locateYabai() else {
            availability = .notInstalled
            canControlSpaces = false
            raResult = "not_installed"
            updateEnabledState()
            return
        }

        cachedYabaiPath = yabaiPath
        raResult = "dispatched"

        Task.detached(priority: .utility) { [weak self] in
            PerfMonitor.shared.beginSection("availability.refresh", fields: ["force": String(force)])
            let spacesResult = YabaiClient.run(arguments: ["-m", "query", "--spaces"])
            var saLoaded = false
            if let result = spacesResult, result.exitCode == 0 {
                saLoaded = self?.checkScriptingAdditionLoaded(yabaiPath: yabaiPath) ?? false
            }
            PerfMonitor.shared.endSection()

            await MainActor.run { [weak self] in
                self?.applyAvailability(
                    spacesResult: spacesResult,
                    saLoaded: saLoaded,
                    yabaiPath: yabaiPath,
                    raResultOut: { raResult = $0 }
                )
            }
        }
    }

    /// 后台探测结果 → 主线程状态应用（原 refreshAvailability 的状态变更段原样搬移）。
    @MainActor
    private func applyAvailability(
        spacesResult: ShellResult?,
        saLoaded: Bool,
        yabaiPath: String,
        raResultOut: @escaping (String) -> Void
    ) {
        var raResult = "applied"
        defer { raResultOut(raResult) }
        guard let result = spacesResult else {
            availability = .unavailable
            canControlSpaces = false
            lastErrorMessage = "Unable to launch yabai"
            raResult = "unavailable_launch"
            updateEnabledState()
            return
        }

        if result.exitCode == 0 {
            availability = .available
            WindowManager.shared.focusSpaceKnownBroken = false
            if saLoaded {
                canControlSpaces = true
                lastErrorMessage = nil
                raResult = "available_sa_loaded"
            } else {
                canControlSpaces = false
                lastErrorMessage = "yabai scripting-addition 未加载，跨工作区恢复功能受限。请在设置中加载 scripting-addition。"
                raResult = "available_sa_missing"
                attemptSilentSARecovery(yabaiPath: yabaiPath)
            }
            updateEnabledState()
        } else {
            availability = .unavailable
            canControlSpaces = false
            lastErrorMessage = Self.formatErrorMessage(stdout: result.stdout, stderr: result.stderr)
            raResult = "unavailable_exitcode"
            updateEnabledState()
        }
    }
}
