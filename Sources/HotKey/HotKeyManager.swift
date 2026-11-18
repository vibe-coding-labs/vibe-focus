import AppKit
import ApplicationServices.HIServices
import Carbon
import CoreFoundation
import Foundation

/// 快捷键录制/应用编排的宿主依赖缝（2026-11-19 覆盖率补齐）：校验、Carbon 注册、
/// 持久化、提示音、审计与通知全可注入。默认 nil → 生产真实实现；Runner 注入假实现
/// 直测改键四态（无变化/校验失败/注册失败回滚/成功）+ 摆位重复/撞车 + 气泡撞车
/// （零 Carbon 全局注册、零 UserDefaults 写）。
struct HotKeyApplyEnvironment {
    var validationError: (HotKeyConfiguration) -> String?
    /// @MainActor：注册结果要写回 shortcutStatusIsError（回滚判定输入），
    /// 与调用点同隔离域，测试闭包可直接持有 manager。
    var registerHotKey: @MainActor () -> Void
    var saveHotKey: (HotKeyConfiguration) -> Void
    var saveLayoutTable: () -> Void
    var setBubbleHotKey: (HotKeyConfiguration) -> Void
    var layoutActionsEnabled: () -> Bool
    var beep: () -> Void
    var record: (String) -> Void
    var notify: (Notification.Name) -> Void
}

// MARK: - HotKey Manager
/// Manages global hotkey registration, accessibility permissions, and shortcut recording.
@MainActor
public final class HotKeyManager: ObservableObject {
    public static let shared = HotKeyManager()

    @Published private(set) var currentHotKey: HotKeyConfiguration
    /// 摆位动作热键表（Rectangle 式半屏/四分等；与主 toggle 键独立注册/匹配）
    @Published private(set) var layoutTable: LayoutHotKeyTable
    @Published var shortcutStatusMessage = "当前快捷键已生效"
    @Published var shortcutStatusIsError = false
    /// B244：set 放开为 internal——HotKey 真机 E2E 以真实 AXIsProcessTrustedWithOptions
    /// 探针置位后才能打穿 setupCGEventTap 创建机器（生产零变更：仍由 refresh 写入）。
    @Published var accessibilityStatus = false

    var accessibilityGranted: Bool {
        accessibilityStatus
    }

    let hotkeySignature: OSType = 0x56424648
    let hotkeyIdentifier: UInt32 = 1
    var hotKeyRef: EventHotKeyRef?
    var titleEditorHotKeyRef: EventHotKeyRef?
    /// B129/B162 输入气泡唤起热键 Carbon 注册表（CGEventTap 不可用时的兜底通道）
    var inputBubbleHotKeyRef: EventHotKeyRef?
    /// 摆位热键 Carbon 注册表：carbonHotKeyID → ref（registerLayoutHotKeys 维护）
    var layoutHotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    var handlerRef: EventHandlerRef?
    var globalMonitor: Any?
    var localMonitor: Any?
    var eventTap: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var cgEventTapActive = false
    var isToggleInFlight = false
    var lastToggleTriggeredAt: Date = .distantPast
    var lastToggleCompletedAt: Date = .distantPast
    let toggleDedupInterval: TimeInterval = 0.15
    let toggleCooldownInterval: TimeInterval = 0.05
    /// 0.1.5 in-flight 闸门看门狗预算：持有时长超此值视为触发链挂死，强制放行
    /// （shouldForceReleaseInFlightGate）。取 120s=executor 熔断预算（90s）之上的
    /// 兜底层，正常 toggle（0.3~2s，B180 风暴极值 66s）永不触发。
    let inFlightGateBudget: TimeInterval = 120
    /// 摆位触发去抖（独立状态，不与 toggle 互锁）
    var isLayoutInFlight = false
    var lastLayoutTriggeredAt: Date = .distantPast

    public init() {
        currentHotKey = Self.loadStoredHotKey()
        layoutTable = Self.loadStoredLayoutTable()
        accessibilityStatus = Self.checkAccessibility()
    }

    /// Nonisolated entry point for title editor hotkey — bypasses @MainActor
    /// to avoid StrictConcurrency dispatch issues from CGEventTap C callback.
    nonisolated static func triggerTitleEditor() {
        let enabled = TitleEditorPreferences.isEnabled
        let hotKeyEnabled = TitleEditorPreferences.isHotKeyEnabled
        log("[HotKey] Title editor Ctrl+T matched", fields: ["enabled": String(enabled), "hotKeyEnabled": String(hotKeyEnabled)])
        guard enabled && hotKeyEnabled else {
            log("[HotKey] Title editor disabled, passing event through")
            return
        }
        log("[HotKey] Title editor hotkey detected, dispatching editTitle")
        DispatchQueue.main.async {
            TitleEditorService.shared.editTitle()
        }
    }

    /// Nonisolated entry point for input bubble hotkey（B188 默认 ⌃X）— CGEventTap C callback 域调用，
    /// TitleEditor 同款模式：绕 @MainActor，main 队列转回隔离域（summon 内自查偏好开关）。
    nonisolated static func triggerInputBubble() {
        log("[HotKey] Input bubble hotkey matched")
        DispatchQueue.main.async {
            InputBubbleController.shared.summon()
        }
    }

    func setup() {
        // P-INST-219: 热键系统启动编排端到端耗时（refreshAccessibilityStatus + setupCGEventTap CGEventTap 创建 + installHandlerIfNeeded + registerHotKey P-INST-140 Carbon + installFallbackMonitors P-INST-141 NSEvent；启动路径单次调用，归因启动延迟）。
        #if PERF_INSTRUMENT
        let suStart = Date()
        defer {
            log("[HotKey] setup finished", level: .debug, fields: ["durationMs": String(elapsedMilliseconds(since: suStart))])
        }
        #endif
        refreshAccessibilityStatus()
        log(
            "HotKey setup start",
            fields: [
                "key": currentHotKey.displayString,
                "keyCode": String(currentHotKey.keyCode),
                "modifiers": String(currentHotKey.modifiers),
                "axTrusted": String(accessibilityStatus)
            ]
        )

        cgEventTapActive = setupCGEventTap()
        installHandlerIfNeeded()
        registerHotKey()

        if cgEventTapActive {
            log("CGEventTap setup successful; Carbon hotkey kept as fallback")
            removeFallbackMonitors()
            CrashContextRecorder.shared.record("hotkey_setup cg_event_tap=on carbon=on")
        } else {
            log("CGEventTap failed, falling back to Carbon + NSEvent monitors")
            installFallbackMonitors()
            CrashContextRecorder.shared.record("hotkey_setup cg_event_tap=off carbon=on monitors=on")
        }
    }

    func applyShortcut(_ hotKey: HotKeyConfiguration, environment: HotKeyApplyEnvironment? = nil) {
        // P-INST-220: 快捷键应用端到端耗时（validate + registerHotKey P-INST-140 + NSSound.beep + saveStoredHotKey P-INST-189 + NotificationCenter；用户设置 UI 改快捷键触发，含 beep 反馈）。
        #if PERF_INSTRUMENT
        let asStart = Date()
        defer {
            log("[HotKey] applyShortcut finished", level: .debug, fields: ["key": hotKey.displayString, "durationMs": String(elapsedMilliseconds(since: asStart))])
        }
        #endif
        log("[HotKey] applyShortcut requested: \(hotKey.displayString) keyCode=\(hotKey.keyCode) modifiers=\(hotKey.modifiers)")
        recordHotKeyEvent("hotkey_apply_requested key=\(hotKey.displayString)", environment: environment)

        if hotKey == currentHotKey {
            shortcutStatusMessage = "快捷键未变化：\(hotKey.displayString)"
            shortcutStatusIsError = false
            recordHotKeyEvent("hotkey_apply_no_change key=\(hotKey.displayString)", environment: environment)
            return
        }

        let validation: String?
        if let environment {
            validation = environment.validationError(hotKey)
        } else {
            validation = Self.validationError(for: hotKey)
        }
        if let validationError = validation {
            shortcutStatusMessage = validationError
            shortcutStatusIsError = true
            beepHotKey(environment)
            recordHotKeyEvent("hotkey_apply_validation_failed key=\(hotKey.displayString)", environment: environment)
            return
        }

        let previousHotKey = currentHotKey
        currentHotKey = hotKey
        registerHotKeyInjected(environment)

        if shortcutStatusIsError {
            currentHotKey = previousHotKey
            registerHotKeyInjected(environment)
            shortcutStatusMessage = "快捷键已恢复为 \(currentHotKey.displayString)"
            shortcutStatusIsError = true
            beepHotKey(environment)
            recordHotKeyEvent("hotkey_apply_rollback key=\(previousHotKey.displayString)", environment: environment)
            return
        }

        if let environment {
            environment.saveHotKey(hotKey)
        } else {
            saveStoredHotKey(hotKey)
        }
        shortcutStatusMessage = "快捷键已更新：\(hotKey.displayString)"
        shortcutStatusIsError = false
        notifyHotKey(.hotKeyConfigurationDidChange, environment)
        recordHotKeyEvent("hotkey_apply_success key=\(hotKey.displayString)", environment: environment)
    }

    // MARK: - 注入原语（environment nil → 生产真实通道）

    private func registerHotKeyInjected(_ environment: HotKeyApplyEnvironment?) {
        if let environment {
            environment.registerHotKey()
        } else {
            registerHotKey()
        }
    }

    private func recordHotKeyEvent(_ audit: String, environment: HotKeyApplyEnvironment?) {
        if let environment {
            environment.record(audit)
        } else {
            CrashContextRecorder.shared.record(audit)
        }
    }

    private func beepHotKey(_ environment: HotKeyApplyEnvironment?) {
        if let environment {
            environment.beep()
        } else {
            NSSound.beep()
        }
    }

    private func notifyHotKey(_ name: Notification.Name, _ environment: HotKeyApplyEnvironment?) {
        if let environment {
            environment.notify(name)
        } else {
            NotificationCenter.default.post(name: name, object: nil)
        }
    }

    func resetToDefaultShortcut() {
        applyShortcut(.default)
    }

    func openAccessibilitySettings() {
        // P-INST-188: 打开辅助功能系统设置耗时（NSWorkspace.shared.open URL scheme 启动 System Settings；设置 UI 权限按钮调用，LaunchServices 跨进程调用可阻塞）。
        #if PERF_INSTRUMENT
        let oasStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: oasStart)
            if durMs >= 50 { log("[HotKey] openAccessibilitySettings slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        #endif
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshAccessibilityStatus() {
        let previous = accessibilityStatus
        accessibilityStatus = Self.checkAccessibility()
        log(
            "[HotKey] refreshAccessibilityStatus",
            level: .debug,
            fields: [
                "previous": String(previous),
                "current": String(accessibilityStatus)
            ]
        )
    }

    private static func checkAccessibility() -> Bool {
        // P-INST-65: AX 权限检查耗时（AXIsProcessTrustedWithOptions；HotKey setup/refresh 调用；slow-op ≥50ms warn）。
        #if PERF_INSTRUMENT
        let caStart = Date()
        #endif
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary)
        #if PERF_INSTRUMENT
        let caMs = elapsedMilliseconds(since: caStart)
        if caMs >= 50 {
            log("[HotKey] checkAccessibility slow", level: .warn, fields: ["durationMs": String(caMs)])
        }
        #endif
        return trusted
    }

    /// 快捷键校验唯一事实源（纯函数，B45 提纯）：修饰键要求 + 系统冲突表 +
    /// 标题编辑键占用（B165；开关注册表实时读，热键开关关闭时 ⌃T 释放可绑）。
    /// nonisolated static——Runner 直测真身，消除 Runner 内同语义镜像的漂移面。
    nonisolated static func validationError(for hotKey: HotKeyConfiguration) -> String? {
        if hotKey.modifiers & (UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)) == 0 {
            log(
                "[HotKey] validate: no modifier key",
                level: .debug,
                fields: ["keyCode": String(hotKey.keyCode), "modifiers": String(hotKey.modifiers)]
            )
            return "快捷键至少需要包含 ⌘ / ⌥ / ⌃ 之一"
        }

        if let conflict = HotKeyConfiguration.knownConflicts.first(where: { $0.configuration == hotKey }) {
            log(
                "[HotKey] validate: conflict found",
                level: .debug,
                fields: ["conflictReason": conflict.reason]
            )
            return "快捷键冲突：\(conflict.reason)"
        }

        if TitleEditorPreferences.isHotKeyEnabled, hotKey == HotKeyConfiguration.titleEditor {
            log(
                "[HotKey] validate: title editor hotkey collision",
                level: .debug,
                fields: ["keyCode": String(hotKey.keyCode), "modifiers": String(hotKey.modifiers)]
            )
            return "快捷键冲突：与标题编辑快捷键 ⌃T 冲突"
        }

        log(
            "[HotKey] validate: passed",
            level: .debug,
            fields: ["keyCode": String(hotKey.keyCode), "modifiers": String(hotKey.modifiers)]
        )
        return nil
    }

    private static func loadStoredHotKey() -> HotKeyConfiguration {
        // P-INST-204: 热键持久化读取耗时（UserDefaults.standard.data CFPreferences 同步读 + JSONDecoder.decode；HotKeyManager init 启动 + registerHotKey 前调用，读取已存热键配置）。
        let lshStart = Date()
        let hotKey: HotKeyConfiguration = {
            guard let data = UserDefaults.standard.data(forKey: HotKeyConfiguration.userDefaultsKey),
                  let decoded = try? JSONDecoder().decode(HotKeyConfiguration.self, from: data) else {
                return .default
            }
            return decoded
        }()
        let durMs = elapsedMilliseconds(since: lshStart)
        if durMs >= 5 { log("[HotKey] loadStoredHotKey slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        if hotKey == .legacyDefault {
            return .default
        }
        return hotKey
    }

    private func saveStoredHotKey(_ hotKey: HotKeyConfiguration) {
        // P-INST-189: 热键持久化耗时（JSONEncoder.encode + UserDefaults.standard.set CFPreferences 同步写；applyShortcut/resetToDefaultShortcut 调用，热键变更写）。
        #if PERF_INSTRUMENT
        let sshStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: sshStart)
            if durMs >= 5 { log("[HotKey] saveStoredHotKey slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        #endif
        guard let data = try? JSONEncoder().encode(hotKey) else {
            return
        }
        UserDefaults.standard.set(data, forKey: HotKeyConfiguration.userDefaultsKey)
    }

    // MARK: 摆位热键表

    private static func loadStoredLayoutTable() -> LayoutHotKeyTable {
        guard let data = UserDefaults.standard.data(forKey: LayoutHotKeyTable.userDefaultsKey),
              let table = LayoutHotKeyTable.decode(data) else {
            return .withDefaults
        }
        return table
    }

    private func saveStoredLayoutTable() {
        if let data = layoutTable.encoded() {
            UserDefaults.standard.set(data, forKey: LayoutHotKeyTable.userDefaultsKey)
        }
    }

    /// 录制摆位动作热键。返回错误信息（nil = 成功）。
    /// 校验链：修饰键/系统冲突（validate）→ 表内组合键重复 → 与主 toggle 键撞车。
    @discardableResult
    func applyLayoutShortcut(
        _ hotKey: HotKeyConfiguration,
        for action: LayoutAction,
        environment: HotKeyApplyEnvironment? = nil
    ) -> String? {
        log("[HotKey] applyLayoutShortcut requested: \(action.rawValue) \(hotKey.displayString)")
        let validation: String?
        if let environment {
            validation = environment.validationError(hotKey)
        } else {
            validation = Self.validationError(for: hotKey)
        }
        if let validationError = validation {
            return validationError
        }

        var updated = layoutTable
        updated.bindings[action.rawValue] = hotKey
        if let duplicate = LayoutHotKeyTable.duplicateBinding(in: updated) {
            let names = duplicate.actions.map { $0.displayName }.joined(separator: " / ")
            return "组合键 \(duplicate.hotKey.displayString) 已绑定为「\(names)」"
        }
        if LayoutHotKeyTable.collidesWithToggleHotKey(updated, toggleHotKey: currentHotKey) != nil {
            return "组合键与主开关快捷键 \(currentHotKey.displayString) 冲突"
        }

        layoutTable = updated
        if let environment {
            environment.saveLayoutTable()
        } else {
            saveStoredLayoutTable()
        }
        registerHotKeyInjected(environment)
        notifyHotKey(.layoutHotKeyTableDidChange, environment)
        recordHotKeyEvent("layout_hotkey_apply action=\(action.rawValue) key=\(hotKey.displayString)", environment: environment)
        return nil
    }

    /// 恢复某个摆位动作的默认热键
    func resetLayoutShortcut(for action: LayoutAction) {
        var updated = layoutTable
        updated.bindings.removeValue(forKey: action.rawValue)
        layoutTable = updated
        saveStoredLayoutTable()
        registerHotKey()
        NotificationCenter.default.post(name: .layoutHotKeyTableDidChange, object: nil)
    }

    /// 摆位热键总开关（共存策略 / 设置页切换）。只影响热键注册与匹配，菜单入口不受限。
    func setLayoutActionsEnabled(_ enabled: Bool) {
        LayoutPreferences.isEnabled = enabled
        registerHotKey()
        NotificationCenter.default.post(name: .layoutHotKeyTableDidChange, object: nil)
        CrashContextRecorder.shared.record("layout_hotkey_enabled value=\(enabled)")
    }

    // MARK: 输入气泡唤起热键（B188：默认 ⌃X，设置页可自定义）

    /// 录制气泡唤起热键。返回错误信息（nil = 成功）。
    /// 校验链：修饰键/系统冲突（validate）→ 与主 toggle 键撞车 → 与摆位键撞车。
    @discardableResult
    func applyBubbleShortcut(_ hotKey: HotKeyConfiguration, environment: HotKeyApplyEnvironment? = nil) -> String? {
        log("[HotKey] applyBubbleShortcut requested: \(hotKey.displayString)")
        let validation: String?
        if let environment {
            validation = environment.validationError(hotKey)
        } else {
            validation = Self.validationError(for: hotKey)
        }
        if let validationError = validation {
            return validationError
        }
        if hotKey.keyCode == currentHotKey.keyCode && hotKey.modifiers == currentHotKey.modifiers {
            return "组合键与主开关快捷键 \(currentHotKey.displayString) 冲突"
        }
        let layoutEnabled = environment.map { $0.layoutActionsEnabled() } ?? LayoutPreferences.isEnabled
        if layoutEnabled,
           LayoutAction.allCases.contains(where: { layoutTable.hotKey(for: $0) == hotKey }) {
            return "组合键已被摆位快捷键占用：\(hotKey.displayString)"
        }

        if let environment {
            environment.setBubbleHotKey(hotKey)
        } else {
            InputBubblePreferences.hotKey = hotKey
        }
        registerHotKeyInjected(environment)
        notifyHotKey(.inputBubbleHotKeyDidChange, environment)
        recordHotKeyEvent("bubble_hotkey_apply key=\(hotKey.displayString)", environment: environment)
        return nil
    }

    /// 恢复气泡唤起热键默认值（⌃X）。
    func resetBubbleShortcut() {
        InputBubblePreferences.hotKey = InputBubbleHotKeyPlan.defaultConfig
        registerHotKey()
        NotificationCenter.default.post(name: .inputBubbleHotKeyDidChange, object: nil)
        CrashContextRecorder.shared.record("bubble_hotkey_reset key=\(InputBubbleHotKeyPlan.defaultConfig.displayString)")
    }
}
