import SwiftUI
import AppKit
import Carbon
import ApplicationServices.HIServices
import CoreFoundation
import Foundation

// MARK: - HotKey Manager
@MainActor
final class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()

    @Published private(set) var currentHotKey: HotKeyConfiguration
    @Published private(set) var shortcutStatusMessage = "当前快捷键已生效"
    @Published private(set) var shortcutStatusIsError = false

    var accessibilityGranted: Bool {
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private let hotkeySignature: OSType = 0x56424648
    private let hotkeyIdentifier: UInt32 = 1
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private init() {
        currentHotKey = Self.loadStoredHotKey()
    }

    func setup() {
        installHandlerIfNeeded()
        registerHotKey()
        installFallbackMonitors()
    }

    private func installFallbackMonitors() {
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                _ = self?.handleFallbackEvent(event, source: "global")
            }
            log("Installed global fallback monitor")
        }

        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                _ = self?.handleFallbackEvent(event, source: "local")
                return event
            }
            log("Installed local fallback monitor")
        }
    }

    private func handleFallbackEvent(_ event: NSEvent, source: String) -> Bool {
        guard currentHotKey.matches(event: event) else {
            return false
        }

        log("Fallback hotkey \(currentHotKey.displayString) triggered from \(source)")
        WindowManager.shared.toggle()
        return true
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else {
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let eventRef, let userData else {
                return OSStatus(eventNotHandledErr)
            }

            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            return manager.handleHotKeyEvent(eventRef)
        }

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &handlerRef
        )

        log("Install hotkey handler status: \(installStatus)")
    }

    private func registerHotKey() {
        if let hotKeyRef {
            let unregisterStatus = UnregisterEventHotKey(hotKeyRef)
            log("Unregister previous hotkey status: \(unregisterStatus)")
            self.hotKeyRef = nil
        }

        let hotKeyID = EventHotKeyID(signature: hotkeySignature, id: hotkeyIdentifier)
        let registerStatus = RegisterEventHotKey(
            currentHotKey.keyCode,
            currentHotKey.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        shortcutStatusMessage = registerStatus == noErr
            ? "当前快捷键：\(currentHotKey.displayString)"
            : "快捷键注册失败：\(currentHotKey.displayString)"
        shortcutStatusIsError = registerStatus != noErr
        log("Register hotkey \(currentHotKey.displayString) status: \(registerStatus)")
    }

    private func handleHotKeyEvent(_ eventRef: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr else {
            log("Get hotkey event parameter failed: \(status)")
            return status
        }

        guard hotKeyID.signature == hotkeySignature, hotKeyID.id == hotkeyIdentifier else {
            return noErr
        }

        log("Hotkey \(currentHotKey.displayString) triggered")
        WindowManager.shared.toggle()
        return noErr
    }

    func applyShortcut(_ hotKey: HotKeyConfiguration) {
        if hotKey == currentHotKey {
            shortcutStatusMessage = "快捷键未变化：\(hotKey.displayString)"
            shortcutStatusIsError = false
            return
        }

        if let validationError = validate(hotKey) {
            shortcutStatusMessage = validationError
            shortcutStatusIsError = true
            NSSound.beep()
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
            return
        }

        saveStoredHotKey(hotKey)
        shortcutStatusMessage = "快捷键已更新：\(hotKey.displayString)"
        shortcutStatusIsError = false
        NotificationCenter.default.post(name: .hotKeyConfigurationDidChange, object: nil)
    }

    func resetToDefaultShortcut() {
        applyShortcut(.default)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func validate(_ hotKey: HotKeyConfiguration) -> String? {
        if hotKey.modifiers & (UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)) == 0 {
            return "快捷键至少需要包含 ⌘ / ⌥ / ⌃ 之一"
        }

        if let conflict = HotKeyConfiguration.knownConflicts.first(where: { $0.configuration == hotKey }) {
            return "快捷键冲突：\(conflict.reason)"
        }

        return nil
    }

    private static func loadStoredHotKey() -> HotKeyConfiguration {
        guard let data = UserDefaults.standard.data(forKey: HotKeyConfiguration.userDefaultsKey),
              let hotKey = try? JSONDecoder().decode(HotKeyConfiguration.self, from: data) else {
            return .default
        }
        if hotKey == .legacyDefault {
            return .default
        }
        return hotKey
    }

    private func saveStoredHotKey(_ hotKey: HotKeyConfiguration) {
        guard let data = try? JSONEncoder().encode(hotKey) else {
            return
        }
        UserDefaults.standard.set(data, forKey: HotKeyConfiguration.userDefaultsKey)
    }
}

