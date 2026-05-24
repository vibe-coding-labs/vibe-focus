import AppKit
import Carbon
import Foundation

// MARK: - Fallback Monitors & Toggle Dedup
@MainActor
extension HotKeyManager {

    func installFallbackMonitors() {
        log(
            "[HotKey] installFallbackMonitors called",
            level: .debug,
            fields: [
                "hasGlobalMonitor": String(globalMonitor != nil),
                "hasLocalMonitor": String(localMonitor != nil)
            ]
        )
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

    func removeFallbackMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    func triggerToggleIfNeeded(source: String) {
        let now = Date()
        let hotkey = currentHotKey.displayString

        if isToggleInFlight {
            log(
                "[HotKey] Ignored trigger: toggle already in flight",
                level: .warn,
                fields: ["source": source, "key": hotkey]
            )
            return
        }

        let sinceLastTrigger = now.timeIntervalSince(lastToggleTriggeredAt)
        let sinceLastCompletion = now.timeIntervalSince(lastToggleCompletedAt)
        if sinceLastTrigger < toggleDedupInterval || sinceLastCompletion < toggleCooldownInterval {
            log(
                "[HotKey] Ignored duplicate trigger",
                level: .warn,
                fields: [
                    "source": source,
                    "key": hotkey,
                    "sinceLastTriggerMs": String(Int((sinceLastTrigger * 1000).rounded())),
                    "sinceLastCompletionMs": String(Int((sinceLastCompletion * 1000).rounded()))
                ]
            )
            return
        }

        let operationID = makeOperationID(prefix: "toggle")
        let startedAt = Date()
        isToggleInFlight = true
        lastToggleTriggeredAt = now
        defer {
            lastToggleCompletedAt = Date()
            isToggleInFlight = false
        }

        log(
            "[HotKey] Trigger accepted",
            fields: ["op": operationID, "source": source, "key": hotkey]
        )
        CrashContextRecorder.shared.record("hotkey_trigger_accepted op=\(operationID) source=\(source) key=\(hotkey)")

        WindowManager.shared.toggle(operationID: operationID, triggerSource: source)

        let duration = elapsedMilliseconds(since: startedAt)
        log(
            "[HotKey] Toggle completed",
            fields: ["op": operationID, "source": source, "durationMs": String(duration)]
        )
        CrashContextRecorder.shared.record("hotkey_toggle_completed op=\(operationID) durationMs=\(duration)")
    }

    func handleFallbackEvent(_ event: NSEvent, source: String) -> Bool {
        if event.isARepeat {
            return false
        }

        let eventKeyCode = UInt32(event.keyCode)
        let eventModifiers = event.modifierFlags.intersection(.hotKeyRelevantFlags).carbonHotKeyModifiers
        let matches = currentHotKey.matches(event: event)

        log(
            "[HotKey] handleFallbackEvent",
            level: .debug,
            fields: [
                "source": source,
                "keyCode": String(eventKeyCode),
                "modifiers": String(eventModifiers),
                "expectedKeyCode": String(currentHotKey.keyCode),
                "expectedModifiers": String(currentHotKey.modifiers),
                "matches": String(matches)
            ]
        )

        guard matches else {
            let titleEditorKeyCode: UInt32 = 17
            let titleEditorModifiers: UInt32 = UInt32(controlKey)
            if eventKeyCode == titleEditorKeyCode && eventModifiers == titleEditorModifiers {
                let enabled = TitleEditorPreferences.isEnabled
                let hotKeyEnabled = TitleEditorPreferences.isHotKeyEnabled
                guard enabled && hotKeyEnabled else { return false }
                log("[HotKey] Title editor Ctrl+T matched in fallback handler")
                DispatchQueue.main.async {
                    TitleEditorService.shared.editTitle()
                }
                return true
            }
            return false
        }

        log("Fallback hotkey \(currentHotKey.displayString) triggered from \(source)")
        triggerToggleIfNeeded(source: "fallback_\(source)")
        return true
    }
}
