import AppKit
import Carbon
import Foundation

// MARK: - Fallback Monitors & Toggle Dedup
@MainActor
extension HotKeyManager {

    func installFallbackMonitors() {
        // P-INST-141: 回退事件 monitor 安装耗时（NSEvent.addGlobalMonitorForEvents + addLocalMonitorForEvents 系统级 keyDown 监听注册；CGEvent tap 不可用时回退，reenableEventTap P-INST-122 调用）。
        #if PERF_INSTRUMENT
        let ifmStart = Date()
        defer {
            log("[HotKey] installFallbackMonitors finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: ifmStart))
            ])
        }
        #endif
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
        // P-INST-143: 回退事件 monitor 移除耗时（NSEvent.removeMonitor x2 注销 global + local keyDown 监听；reenableEventTap 切换到 CGEvent tap 后调用，停止 fallback 监听）。
        #if PERF_INSTRUMENT
        let rfmStart = Date()
        defer {
            log("[HotKey] removeFallbackMonitors finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: rfmStart))
            ])
        }
        #endif
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

        // Batch 17：去重门提纯为 ToggleTriggerGate.dedupDecision（门序与阈值语义不变）。
        switch ToggleTriggerGate.dedupDecision(
            isInFlight: isToggleInFlight,
            sinceLastTrigger: now.timeIntervalSince(lastToggleTriggeredAt),
            sinceLastCompletion: now.timeIntervalSince(lastToggleCompletedAt),
            dedupInterval: toggleDedupInterval,
            cooldownInterval: toggleCooldownInterval
        ) {
        case .skipInFlight:
            log(
                "[HotKey] Ignored trigger: toggle already in flight",
                level: .warn,
                fields: ["source": source, "key": hotkey]
            )
            return
        case .skipDuplicate:
            let sinceLastTrigger = now.timeIntervalSince(lastToggleTriggeredAt)
            let sinceLastCompletion = now.timeIntervalSince(lastToggleCompletedAt)
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
        case .accept:
            break
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
        // P-INST-252: 热键 fallback 事件处理耗时（NSEvent keyCode/modifierFlags 解析 + currentHotKey.matches + triggerToggleIfNeeded 或 TitleEditor Ctrl+T DispatchQueue 派发；NSEvent monitor fallback 路径，Carbon event tap 不可用时触发；slow-op ≥50ms warn）。
        #if PERF_INSTRUMENT
        let hfeStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: hfeStart)
            if durMs >= 50 { log("[HotKey] handleFallbackEvent slow", level: .warn, fields: ["source": source, "durationMs": String(durMs)]) }
        }
        #endif
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

        // 各路由命中扫描（保持原扫描语义）；优先级裁决收敛到
        // ToggleTriggerGate.fallbackRoute（Batch 17 纯判定，Runner 矩阵锁定）。
        let titleEditorHit: Bool = {
            let titleEditorKeyCode: UInt32 = 17
            let titleEditorModifiers: UInt32 = UInt32(controlKey)
            guard eventKeyCode == titleEditorKeyCode && eventModifiers == titleEditorModifiers else { return false }
            return TitleEditorPreferences.isEnabled && TitleEditorPreferences.isHotKeyEnabled
        }()
        var layoutHit: LayoutAction?
        if LayoutPreferences.isEnabled, !matches, !titleEditorHit {
            layoutHit = LayoutAction.allCases.first { action in
                guard let hotKey = layoutTable.hotKey(for: action) else { return false }
                return eventKeyCode == hotKey.keyCode && eventModifiers == hotKey.modifiers
            }
        }

        switch ToggleTriggerGate.fallbackRoute(
            isARepeat: false,                        // repeat 已在入口短路
            matchesPrimaryHotKey: matches,
            titleEditorEnabledAndMatched: titleEditorHit,
            layoutMatch: layoutHit
        ) {
        case .ignore:
            return false
        case .toggle:
            log("Fallback hotkey \(currentHotKey.displayString) triggered from \(source)")
            triggerToggleIfNeeded(source: "fallback_\(source)")
            return true
        case .titleEditor:
            log("[HotKey] Title editor Ctrl+T matched in fallback handler")
            DispatchQueue.main.async {
                TitleEditorService.shared.editTitle()
            }
            return true
        case .layout(let action):
            log("[HotKey] Fallback layout hotkey matched", fields: [
                "action": action.rawValue,
                "key": layoutTable.hotKey(for: action)?.displayString ?? "?",
                "source": source
            ])
            triggerLayoutActionIfNeeded(action, source: "fallback_\(source)")
            return true
        }
    }

    /// 摆位动作触发（去抖独立于 toggle；总开关关闭时 beep 拒绝——按下的组合键
    /// 可能已被其它 app 占用，静默吞键会让用户以为 VibeFocus 失灵）。
    func triggerLayoutActionIfNeeded(_ action: LayoutAction, source: String) {
        guard LayoutPreferences.isEnabled else {
            log("[HotKey] Layout action suppressed: hotkeys disabled", fields: [
                "action": action.rawValue,
                "source": source
            ])
            NSSound.beep()
            return
        }

        let now = Date()
        if isLayoutInFlight {
            log("[HotKey] Ignored layout trigger: already in flight", level: .warn, fields: [
                "action": action.rawValue,
                "source": source
            ])
            return
        }
        if now.timeIntervalSince(lastLayoutTriggeredAt) < toggleDedupInterval {
            log("[HotKey] Ignored duplicate layout trigger", level: .warn, fields: [
                "action": action.rawValue,
                "source": source
            ])
            return
        }

        let op = makeOperationID(prefix: "layout-hk")
        isLayoutInFlight = true
        lastLayoutTriggeredAt = now
        defer { isLayoutInFlight = false }

        log("[HotKey] Layout trigger accepted", fields: [
            "op": op,
            "action": action.rawValue,
            "source": source
        ])
        CrashContextRecorder.shared.record("layout_trigger op=\(op) action=\(action.rawValue) source=\(source)")
        WindowManager.shared.applyLayoutAction(action, triggerSource: source, operationID: op)
    }
}
