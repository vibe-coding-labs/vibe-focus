import AppKit
import ApplicationServices.HIServices
import Carbon
import CoreFoundation
import Foundation

// MARK: - HotKey Manager
/// Manages global hotkey registration, accessibility permissions, and shortcut recording.
@MainActor
public final class HotKeyManager: ObservableObject {
    public static let shared = HotKeyManager()

    @Published private(set) var currentHotKey: HotKeyConfiguration
    @Published var shortcutStatusMessage = "当前快捷键已生效"
    @Published var shortcutStatusIsError = false
    @Published private(set) var accessibilityStatus = false

    var accessibilityGranted: Bool {
        accessibilityStatus
    }

    let hotkeySignature: OSType = 0x56424648
    let hotkeyIdentifier: UInt32 = 1
    var hotKeyRef: EventHotKeyRef?
    var titleEditorHotKeyRef: EventHotKeyRef?
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

    public init() {
        currentHotKey = Self.loadStoredHotKey()
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

    func setup() {
        // P-INST-219: 热键系统启动编排端到端耗时（refreshAccessibilityStatus + setupCGEventTap CGEventTap 创建 + installHandlerIfNeeded + registerHotKey P-INST-140 Carbon + installFallbackMonitors P-INST-141 NSEvent；启动路径单次调用，归因启动延迟）。
        let suStart = Date()
        defer {
            log("[HotKey] setup finished", level: .debug, fields: ["durationMs": String(elapsedMilliseconds(since: suStart))])
        }
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

    func applyShortcut(_ hotKey: HotKeyConfiguration) {
        // P-INST-220: 快捷键应用端到端耗时（validate + registerHotKey P-INST-140 + NSSound.beep + saveStoredHotKey P-INST-189 + NotificationCenter；用户设置 UI 改快捷键触发，含 beep 反馈）。
        let asStart = Date()
        defer {
            log("[HotKey] applyShortcut finished", level: .debug, fields: ["key": hotKey.displayString, "durationMs": String(elapsedMilliseconds(since: asStart))])
        }
        log("[HotKey] applyShortcut requested: \(hotKey.displayString) keyCode=\(hotKey.keyCode) modifiers=\(hotKey.modifiers)")
        CrashContextRecorder.shared.record("hotkey_apply_requested key=\(hotKey.displayString)")

        if hotKey == currentHotKey {
            shortcutStatusMessage = "快捷键未变化：\(hotKey.displayString)"
            shortcutStatusIsError = false
            CrashContextRecorder.shared.record("hotkey_apply_no_change key=\(hotKey.displayString)")
            return
        }

        if let validationError = validate(hotKey) {
            shortcutStatusMessage = validationError
            shortcutStatusIsError = true
            NSSound.beep()
            CrashContextRecorder.shared.record("hotkey_apply_validation_failed key=\(hotKey.displayString)")
            return
        }

        let previousHotKey = currentHotKey
        currentHotKey = hotKey
        registerHotKey()

        if shortcutStatusIsError {
            currentHotKey = previousHotKey
            registerHotKey()
            shortcutStatusMessage = "快捷键已恢复为 \(currentHotKey.displayString)"
            shortcutStatusIsError = true
            NSSound.beep()
            CrashContextRecorder.shared.record("hotkey_apply_rollback key=\(previousHotKey.displayString)")
            return
        }

        saveStoredHotKey(hotKey)
        shortcutStatusMessage = "快捷键已更新：\(hotKey.displayString)"
        shortcutStatusIsError = false
        NotificationCenter.default.post(name: .hotKeyConfigurationDidChange, object: nil)
        CrashContextRecorder.shared.record("hotkey_apply_success key=\(hotKey.displayString)")
    }

    func resetToDefaultShortcut() {
        applyShortcut(.default)
    }

    func openAccessibilitySettings() {
        // P-INST-188: 打开辅助功能系统设置耗时（NSWorkspace.shared.open URL scheme 启动 System Settings；设置 UI 权限按钮调用，LaunchServices 跨进程调用可阻塞）。
        let oasStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: oasStart)
            if durMs >= 50 { log("[HotKey] openAccessibilitySettings slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
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
        let caStart = Date()
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary)
        let caMs = elapsedMilliseconds(since: caStart)
        if caMs >= 50 {
            log("[HotKey] checkAccessibility slow", level: .warn, fields: ["durationMs": String(caMs)])
        }
        return trusted
    }

    private func validate(_ hotKey: HotKeyConfiguration) -> String? {
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
        let sshStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: sshStart)
            if durMs >= 5 { log("[HotKey] saveStoredHotKey slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        guard let data = try? JSONEncoder().encode(hotKey) else {
            return
        }
        UserDefaults.standard.set(data, forKey: HotKeyConfiguration.userDefaultsKey)
    }
}
