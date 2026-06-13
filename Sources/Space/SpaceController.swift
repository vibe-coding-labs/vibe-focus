import AppKit
import Combine
import Foundation

// 类型定义已移至 SpaceController+Types.swift
// Yabai 执行逻辑已移至 SpaceController+Yabai.swift

@MainActor
final class SpaceController: ObservableObject {
    static let shared = SpaceController()

    @Published var availability: SpaceAvailability = .unknown
    @Published var lastErrorMessage: String?
    @Published private(set) var isEnabled: Bool = false
    @Published var canControlSpaces: Bool = false

    private var lastCheckAt: Date?
    var cachedYabaiPath: String?
    var didAttemptScriptingAdditionRecovery = false
    var scriptingAdditionRecoverySucceeded = false
    private let checkInterval: TimeInterval = 20
    /// 周期 health check timer — 从启动 fork 竞争等瞬态失败自动恢复 isEnabled
    private var healthCheckTimer: Timer?

    // MARK: - Query Cache (per-toggle lifecycle)

    /// 查询缓存 TTL — 短到不会错过 yabai 状态变化，长到覆盖一次 toggle 操作
    static let queryCacheTTL: TimeInterval = 2.0

    /// 缓存 queryWindow 结果 — key 是 windowID
    var windowQueryCache: [UInt32: (result: YabaiWindowInfo?, cachedAt: Date)] = [:]
    /// 缓存 querySpaces 结果
    var spacesQueryCache: (result: [YabaiSpaceInfo]?, cachedAt: Date)?

    /// 清除所有查询缓存 — 每次 toggle 操作结束后调用
    func clearQueryCache() {
        windowQueryCache.removeAll()
        spacesQueryCache = nil
    }

    /// 检查缓存是否过期
    func isCacheExpired(_ cachedAt: Date) -> Bool {
        return Date().timeIntervalSince(cachedAt) > Self.queryCacheTTL
    }

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

    func refreshAvailability(force: Bool) {
        if !force, let lastCheckAt, Date().timeIntervalSince(lastCheckAt) < checkInterval {
            return
        }

        lastCheckAt = Date()
        lastErrorMessage = nil

        guard let yabaiPath = locateYabai() else {
            availability = .notInstalled
            canControlSpaces = false
            updateEnabledState()
            return
        }

        cachedYabaiPath = yabaiPath

        guard let result = runYabai(arguments: ["-m", "query", "--spaces"]) else {
            availability = .unavailable
            canControlSpaces = false
            lastErrorMessage = "Unable to launch yabai"
            updateEnabledState()
            return
        }

        if result.exitCode == 0 {
            availability = .available
            WindowManager.shared.focusSpaceKnownBroken = false
            let saLoaded = checkScriptingAdditionLoaded(yabaiPath: yabaiPath)
            if saLoaded {
                canControlSpaces = true
                lastErrorMessage = nil
            } else {
                canControlSpaces = false
                lastErrorMessage = "yabai scripting-addition 未加载，跨工作区恢复功能受限。请在设置中加载 scripting-addition。"
                attemptSilentSARecovery(yabaiPath: yabaiPath)
            }
            updateEnabledState()
        } else {
            availability = .unavailable
            canControlSpaces = false
            lastErrorMessage = Self.formatErrorMessage(stdout: result.stdout, stderr: result.stderr)
            updateEnabledState()
        }
    }
}
