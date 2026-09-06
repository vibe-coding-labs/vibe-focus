import ApplicationServices.HIServices
import Carbon
import CoreFoundation
import Foundation

// MARK: - CGEventTap
@MainActor
extension HotKeyManager {

    func setupCGEventTap() -> Bool {
        // P-INST-120: CGEvent tap 安装耗时（CGEvent.tapCreate 创建系统级 keyDown 事件 tap + CFMachPortCreateRunLoopSource + CFRunLoopAddSource main runloop + CGEvent.tapEnable；启动路径调用；系统事件 tap 注册涉及 WindowServer 可阻塞）。
        #if PERF_INSTRUMENT
        let scgStart = Date()
        defer {
            log("[HotKey] setupCGEventTap finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: scgStart))
            ])
        }
        #endif
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
        // P-INST-121: 热键检测耗时（仅 hotkey 匹配时记录 durationMs，非匹配 keyDown 不记避免每键日志泛滥；含 event 字段读取 + 修饰键比较 + async dispatch triggerToggleIfNeeded；toggle 最早期 stage 0，物理按键到 "HotKey triggered" 日志之间的归因）。
        let hceStart = Date()
        var hotkeyMatched = false
        defer {
            if hotkeyMatched {
                log("[HotKey] handleCGEvent hotkey detection", level: .debug, fields: [
                    "durationMs": String(elapsedMilliseconds(since: hceStart))
                ])
            }
        }
        guard type == .keyDown || type == .tapDisabledByTimeout || type == .tapDisabledByUserInput else {
            return Unmanaged.passUnretained(event)
        }

        let isAutorepeat = type == .keyDown
            && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        var modifiers: UInt32 = 0
        if flags.contains(.maskControl) { modifiers |= UInt32(controlKey) }
        if flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
        if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }

        let primaryMatch = keyCode == currentHotKey.keyCode && modifiers == currentHotKey.modifiers
        // 摆位热键表匹配（总开关关闭时不拦截）
        var layoutMatch: LayoutAction?
        if LayoutPreferences.isEnabled {
            layoutMatch = LayoutAction.allCases.first { action in
                guard let hotKey = layoutTable.hotKey(for: action) else { return false }
                return keyCode == hotKey.keyCode && modifiers == hotKey.modifiers
            }
        }

        // Batch 17：事件路由判定提纯为 ToggleTriggerGate.cgEventRoute
        //（tapDisabled 自愈 / 连发与非 keyDown 放行 / 主键与摆位命中消费，优先级与拆分前一致）。
        switch ToggleTriggerGate.cgEventRoute(
            type: type,
            isAutorepeat: isAutorepeat,
            primaryMatch: primaryMatch,
            layoutMatch: layoutMatch
        ) {
        case .reenableTap(let reason):
            log("[CGEventTap] Disabled by \(reason == .timeout ? "timeout" : "user_input"), attempting re-enable")
            reenableEventTap(reason: reason == .timeout ? "timeout" : "user_input")
            return Unmanaged.passUnretained(event)
        case .ignore, .passThrough:
            return Unmanaged.passUnretained(event)
        case .toggle:
            hotkeyMatched = true
            log(
                "[HotKey] CGEventTap hotkey match",
                fields: ["displayString": currentHotKey.displayString]
            )
            DispatchQueue.main.async { [weak self] in
                self?.triggerToggleIfNeeded(source: "cg_event_tap")
            }
            return nil
        case .layout(let action):
            hotkeyMatched = true
            log("[HotKey] CGEventTap layout hotkey match", fields: [
                "action": action.rawValue,
                "displayString": layoutTable.hotKey(for: action)?.displayString ?? "?"
            ])
            DispatchQueue.main.async { [weak self] in
                self?.triggerLayoutActionIfNeeded(action, source: "cg_event_tap")
            }
            return nil
        }
    }

    func reenableEventTap(reason: String) {
        // P-INST-122: 事件 tap 重启用耗时（CGEvent.tapEnable + 可能 installFallbackMonitors 回退；event tap 被 timeout/user_input 禁用时调用，低频但含系统调用）。
        #if PERF_INSTRUMENT
        let retStart = Date()
        defer {
            log("[HotKey] reenableEventTap finished", level: .debug, fields: [
                "reason": reason,
                "durationMs": String(elapsedMilliseconds(since: retStart))
            ])
        }
        #endif
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
