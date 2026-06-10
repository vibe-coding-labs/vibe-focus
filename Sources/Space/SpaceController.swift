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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshAvailability(force: true)
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
