import ApplicationServices.HIServices
import Carbon
import CoreFoundation
import Foundation

// MARK: - CGEventTap
@MainActor
extension HotKeyManager {

    func setupCGEventTap() -> Bool {
        guard accessibilityStatus else {
            log(
                "[HotKey] setupCGEventTap: accessibility not granted",
                level: .debug
            )
            return false
        }

        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)

        let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(refcon).takeUnretainedValue()

                // Title editor hotkey: Ctrl+T — detect BEFORE @MainActor dispatch
                if type == .keyDown {
                    let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
                    let flags = event.flags
                    let hasControl = flags.contains(.maskControl)
                    let hasCommand = flags.contains(.maskCommand)
                    let hasAlt = flags.contains(.maskAlternate)
                    let hasShift = flags.contains(.maskShift)

                    if keyCode == 17 && hasControl && !hasCommand && !hasAlt && !hasShift
                        && event.getIntegerValueField(.keyboardEventAutorepeat) == 0
                    {
                        HotKeyManager.triggerTitleEditor()
                        return nil
                    }
                }

                return manager.handleCGEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        guard let tap else {
            log(
                "[HotKey] setupCGEventTap: CGEvent.tapCreate returned nil",
                level: .debug
            )
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        guard let runLoopSource else {
            log(
                "[HotKey] setupCGEventTap: CFMachPortCreateRunLoopSource returned nil",
                level: .debug
            )
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        log("CGEventTap enabled successfully")
        return true
    }

    func handleCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let reason = type == .tapDisabledByTimeout ? "timeout" : "user_input"
            log("[CGEventTap] Disabled by \(reason), attempting re-enable")
            reenableEventTap(reason: reason)
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        var modifiers: UInt32 = 0
        if flags.contains(.maskControl) { modifiers |= UInt32(controlKey) }
        if flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
        if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }

        if keyCode == currentHotKey.keyCode && modifiers == currentHotKey.modifiers {
            log(
                "[HotKey] CGEventTap hotkey match",
                fields: ["displayString": currentHotKey.displayString]
            )
            DispatchQueue.main.async { [weak self] in
                self?.triggerToggleIfNeeded(source: "cg_event_tap")
            }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    func reenableEventTap(reason: String) {
        log(
            "[HotKey] reenableEventTap called",
            level: .debug,
            fields: ["reason": reason]
        )
        guard let tap = eventTap else {
            cgEventTapActive = false
            log("[CGEventTap] Re-enable skipped: eventTap missing")
            CrashContextRecorder.shared.record("hotkey_event_tap_missing reason=\(reason)")
            installFallbackMonitors()
            return
        }

        CGEvent.tapEnable(tap: tap, enable: true)
        let enabled = CGEvent.tapIsEnabled(tap: tap)
        cgEventTapActive = enabled

        if enabled {
            removeFallbackMonitors()
            log("[CGEventTap] Re-enabled successfully after \(reason)")
            CrashContextRecorder.shared.record("hotkey_event_tap_reenabled reason=\(reason)")
        } else {
            installFallbackMonitors()
            log("[CGEventTap] Re-enable failed after \(reason), fallback monitors enabled")
            CrashContextRecorder.shared.record("hotkey_event_tap_reenable_failed reason=\(reason)")
        }
    }
}
