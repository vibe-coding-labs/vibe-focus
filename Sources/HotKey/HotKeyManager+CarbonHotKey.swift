import Carbon
import Foundation

// MARK: - Carbon HotKey Registration
@MainActor
extension HotKeyManager {

    func installHandlerIfNeeded() {
        guard handlerRef == nil else {
            log(
                "[HotKey] installHandlerIfNeeded: handler already installed",
                level: .debug
            )
            return
        }
        log(
            "[HotKey] installHandlerIfNeeded: installing new handler",
            level: .debug
        )

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

    func registerHotKey() {
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
        CrashContextRecorder.shared.record("hotkey_register key=\(currentHotKey.displayString) status=\(registerStatus)")
    }

    func handleHotKeyEvent(_ eventRef: EventRef) -> OSStatus {
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

        log(
            "[handleHotKeyEvent] GetEventParameter returned",
            level: .debug,
            fields: ["status": String(status)]
        )

        guard status == noErr else {
            log("[HotKey] Get event parameter failed: \(status)")
            return status
        }

        log("[HotKey] Got hotKeyID: signature=\(hotKeyID.signature), id=\(hotKeyID.id), expected: signature=\(hotkeySignature), id=\(hotkeyIdentifier)")

        guard hotKeyID.signature == hotkeySignature, hotKeyID.id == hotkeyIdentifier else {
            log(
                "[handleHotKeyEvent] hotKeyID mismatch",
                level: .debug,
                fields: [
                    "gotSignature": String(hotKeyID.signature),
                    "gotID": String(hotKeyID.id),
                    "expectedSignature": String(hotkeySignature),
                    "expectedID": String(hotkeyIdentifier)
                ]
            )
            log("[HotKey] ID mismatch, ignoring")
            return noErr
        }

        log("[HotKey] Hotkey \(currentHotKey.displayString) triggered")
        triggerToggleIfNeeded(source: "carbon_hotkey")
        log("[HotKey] handleHotKeyEvent finished")
        return noErr
    }
}
