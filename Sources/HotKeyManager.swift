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
    @Published private(set) var accessibilityStatus = false

    var accessibilityGranted: Bool {
        accessibilityStatus
    }

    private let hotkeySignature: OSType = 0x56424648
    private let hotkeyIdentifier: UInt32 = 1
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var cgEventTapActive = false
    private var lastToggleTriggeredAt: Date = .distantPast
    private let toggleDedupInterval: TimeInterval = 0.15

    private init() {
        currentHotKey = Self.loadStoredHotKey()
        accessibilityStatus = Self.checkAccessibility()
    }

    func setup() {
        refreshAccessibilityStatus()
        log("HotKey setup start: current=\(currentHotKey.displayString) keyCode=\(currentHotKey.keyCode) modifiers=\(currentHotKey.modifiers)")

        cgEventTapActive = setupCGEventTap()
        if cgEventTapActive {
            log("CGEventTap setup successful")
            // Avoid duplicate toggles: don't install fallback monitors when CGEventTap is active.
            removeFallbackMonitors()
        } else {
            log("CGEventTap failed, falling back to Carbon + NSEvent monitors")
            installHandlerIfNeeded()
            registerHotKey()
            installFallbackMonitors()
        }
    }

    private func setupCGEventTap() -> Bool {
        guard accessibilityStatus else {
            log("CGEventTap requires accessibility permission")
            return false
        }

        // Create event tap for key down events
        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)

        // Try annotatedSessionEventTap for better event capture
        let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,  // Use defaultTap to intercept events
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleCGEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        guard let tap else {
            log("Failed to create CGEventTap")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        guard let runLoopSource else {
            log("Failed to create run loop source")
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        log("CGEventTap enabled successfully")
        return true
    }

    private func handleCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Convert CGEvent flags to Carbon modifiers
        var modifiers: UInt32 = 0
        if flags.contains(.maskControl) { modifiers |= UInt32(controlKey) }
        if flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
        if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }

        // Debug: log M key and Space key events
        if keyCode == 46 || keyCode == 49 {
            log("[CGEventTap DEBUG] keyCode=\(keyCode) modifiers=\(modifiers) expected=\(currentHotKey.keyCode)/\(currentHotKey.modifiers)")
        }

        // Check if this matches our hotkey
        if keyCode == currentHotKey.keyCode && modifiers == currentHotKey.modifiers {
            log("[CGEventTap] Hotkey \(currentHotKey.displayString) triggered")
            // 切换到主线程执行去重后的 toggle
            DispatchQueue.main.async { [weak self] in
                self?.triggerToggleIfNeeded(source: "cg_event_tap")
            }
            return nil // Consume the event
        }

        return Unmanaged.passUnretained(event)
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

    private func removeFallbackMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func triggerToggleIfNeeded(source: String) {
        let now = Date()
        if now.timeIntervalSince(lastToggleTriggeredAt) < toggleDedupInterval {
            log("[HotKey] Ignored duplicate trigger from \(source)")
            return
        }
        lastToggleTriggeredAt = now
        log("[HotKey] Trigger accepted from \(source), calling toggle()")
        WindowManager.shared.toggle()
    }

    private func handleFallbackEvent(_ event: NSEvent, source: String) -> Bool {
        // Debug: log ALL key events to diagnose hotkey issues
        let eventKeyCode = UInt32(event.keyCode)
        let eventModifiers = event.modifierFlags.intersection(.hotKeyRelevantFlags).carbonHotKeyModifiers
        let matches = currentHotKey.matches(event: event)

        // Log every 46 (M key) event for debugging
        if eventKeyCode == 46 {
            log("[FALLBACK DEBUG] source=\(source) keyCode=\(eventKeyCode) modifiers=\(eventModifiers) expected=\(currentHotKey.modifiers) matches=\(matches)")
        }

        guard matches else {
            return false
        }

        log("Fallback hotkey \(currentHotKey.displayString) triggered from \(source)")
        triggerToggleIfNeeded(source: "fallback_\(source)")
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
        log("[HotKey] handleHotKeyEvent called")
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
            log("[HotKey] Get event parameter failed: \(status)")
            return status
        }

        log("[HotKey] Got hotKeyID: signature=\(hotKeyID.signature), id=\(hotKeyID.id), expected: signature=\(hotkeySignature), id=\(hotkeyIdentifier)")

        guard hotKeyID.signature == hotkeySignature, hotKeyID.id == hotkeyIdentifier else {
            log("[HotKey] ID mismatch, ignoring")
            return noErr
        }

        log("[HotKey] Hotkey \(currentHotKey.displayString) triggered")
        triggerToggleIfNeeded(source: "carbon_hotkey")
        log("[HotKey] handleHotKeyEvent finished")
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

    func refreshAccessibilityStatus() {
        accessibilityStatus = Self.checkAccessibility()
    }

    private static func checkAccessibility() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
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
