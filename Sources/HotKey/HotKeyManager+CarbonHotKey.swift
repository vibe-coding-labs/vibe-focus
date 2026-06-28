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
        // P-INST-140: Carbon 热键注册耗时（UnregisterEventHotKey 注销旧 + 2x RegisterEventHotKey 注册主热键 + Ctrl+T title editor + GetApplicationEventTarget；Carbon 系统调用，启动 + 偏好变更时调用）。
        let rhkStart = Date()
        defer {
            log("[HotKey] registerHotKey finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: rhkStart))
            ])
        }
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

        // Register title editor hotkey: Ctrl+T (keyCode 17)
        if let titleEditorHotKeyRef {
            UnregisterEventHotKey(titleEditorHotKeyRef)
            self.titleEditorHotKeyRef = nil
        }

        let titleEditorHotKeyID = EventHotKeyID(signature: hotkeySignature, id: 2)
        let titleEditorStatus = RegisterEventHotKey(
            17,
            UInt32(controlKey),
            titleEditorHotKeyID,
            GetApplicationEventTarget(),
            0,
            &titleEditorHotKeyRef
        )

        if titleEditorStatus == noErr {
            log("[HotKey] Registered title editor Carbon hotkey Ctrl+T")
        } else {
            log("[HotKey] Failed to register title editor Carbon hotkey: \(titleEditorStatus)", level: .warn)
        }
    }

    func handleHotKeyEvent(_ eventRef: EventRef) -> OSStatus {
        // P-INST-142: Carbon 热键事件回调耗时（GetEventParameter 读 hotKeyID + 触发 triggerToggleIfNeeded/title editor；Carbon 热键仅在精确匹配注册组合时触发，无 keypress 刷屏问题，installHandlerIfNeeded 注册的 callback 路径）。
        let hkeStart = Date()
        defer {
            log("[HotKey] handleHotKeyEvent finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: hkeStart))
            ])
        }
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

        guard hotKeyID.signature == hotkeySignature else {
            return noErr
        }

        if hotKeyID.id == hotkeyIdentifier {
            log("[HotKey] Carbon hotkey \(currentHotKey.displayString) triggered")
            triggerToggleIfNeeded(source: "carbon_hotkey")
            return noErr
        }

        if hotKeyID.id == 2 {
            HotKeyManager.triggerTitleEditor()
            return noErr
        }

        return noErr
    }
}
