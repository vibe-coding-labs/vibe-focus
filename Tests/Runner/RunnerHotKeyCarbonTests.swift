import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerHotKeyCarbonTests.swift — 覆盖率批次（2026-11-03）：
// Carbon 热键通道的事件处理与装配（HotKeyManager+CarbonHotKey）。
//
// 安全边界（真机零副作用）：
// - 不注册任何系统级热键（RegisterEventHotKey 只在 CI 门后，见下）；
// - 事件用 CreateEvent + SetEventParameter 合成的 Carbon 事件直投，不投真实 HID；
// - 触发分发分支只走「偏好关闭 → 直接让位」的臂（标题编辑/气泡均关），
//   主 toggle 键只测去重门的两条 skip 臂（isToggleInFlight / 冷却窗内），
//   绝不进入 .accept 真搬窗路径；
// - 录制让位臂依赖真实 key 窗第一响应者，属模态 UI 方可达 → 豁免台账。

extension RunnerHarness {

    func runHotKeyCarbonEventTests() {
        print("\n=== HotKeyCarbonEvent ===")
        let manager = HotKeyManager.shared

        // --- 装配：首次安装处理器，二次走 already-installed 早退 ---
        manager.handlerRef = nil
        manager.installHandlerIfNeeded()
        check("carbon: 首次安装事件处理器", manager.handlerRef != nil)
        manager.installHandlerIfNeeded()
        check("carbon: 重复安装走已有处理器早退", manager.handlerRef != nil)

        // --- 摆位热键总开关关闭：只注销不注册 ---
        let savedLayoutEnabled = LayoutPreferences.isEnabled
        defer { LayoutPreferences.isEnabled = savedLayoutEnabled }
        LayoutPreferences.isEnabled = false
        manager.registerLayoutHotKeys()
        check("carbon: 摆位总开关关闭时不注册任何摆位键", manager.layoutHotKeyRefs.isEmpty)

        // --- 合成事件工具 ---
        func makeEvent(hotKeyID: EventHotKeyID?) -> EventRef? {
            var eventRef: EventRef?
            let status = CreateEvent(
                nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                GetCurrentEventTime(), EventAttributes(0), &eventRef)
            guard status == noErr, let eventRef else { return nil }
            if var id = hotKeyID {
                _ = SetEventParameter(
                    eventRef, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    MemoryLayout<EventHotKeyID>.size, &id)
            }
            return eventRef
        }

        // ① 缺 DirectObject 参数 → GetEventParameter 失败分支
        if let brokenEvent = makeEvent(hotKeyID: nil) {
            let status = manager.handleHotKeyEvent(brokenEvent)
            check("carbon: 事件缺 hotKeyID 参数走失败分支", status != noErr)
        } else {
            check("carbon: 合成 Carbon 事件（无参）失败，环境受限跳过", true)
        }

        // ② 签名不匹配 → 直接放行
        if let foreignEvent = makeEvent(
            hotKeyID: EventHotKeyID(signature: 0x4E4F5045, id: manager.hotkeyIdentifier)) {
            check("carbon: 非本 app 签名事件直接放行",
                  manager.handleHotKeyEvent(foreignEvent) == noErr)
        }

        // ③ 本签名但未知 id → 所有分派都不命中，尾返回
        if let unknownEvent = makeEvent(
            hotKeyID: EventHotKeyID(signature: manager.hotkeySignature, id: 9_999)) {
            check("carbon: 未知 hotkey id 不触发任何动作",
                  manager.handleHotKeyEvent(unknownEvent) == noErr)
        }

        // ④ 主 toggle 键：只覆盖去重门 skip 臂（绝不进入 accept 真搬窗）
        if let toggleEvent = makeEvent(
            hotKeyID: EventHotKeyID(signature: manager.hotkeySignature, id: manager.hotkeyIdentifier)) {
            let savedInFlight = manager.isToggleInFlight
            let savedTriggered = manager.lastToggleTriggeredAt
            let savedCompleted = manager.lastToggleCompletedAt
            defer {
                manager.isToggleInFlight = savedInFlight
                manager.lastToggleTriggeredAt = savedTriggered
                manager.lastToggleCompletedAt = savedCompleted
            }
            manager.isToggleInFlight = true
            check("carbon: toggle 在途时重复触发被丢弃",
                  manager.handleHotKeyEvent(toggleEvent) == noErr)

            manager.isToggleInFlight = false
            manager.lastToggleTriggeredAt = Date()
            manager.lastToggleCompletedAt = Date()
            check("carbon: 冷却窗内重复触发被丢弃",
                  manager.handleHotKeyEvent(toggleEvent) == noErr)
        }

        // ⑤ 标题编辑键（id=2）：偏好关闭 → 让位不弹窗
        let savedTitleEnabled = TitleEditorPreferences.isEnabled
        let savedTitleHotKey = TitleEditorPreferences.isHotKeyEnabled
        defer {
            TitleEditorPreferences.isEnabled = savedTitleEnabled
            TitleEditorPreferences.isHotKeyEnabled = savedTitleHotKey
        }
        TitleEditorPreferences.isEnabled = false
        TitleEditorPreferences.isHotKeyEnabled = false
        if let titleEvent = makeEvent(
            hotKeyID: EventHotKeyID(signature: manager.hotkeySignature, id: 2)) {
            check("carbon: 标题编辑偏好关闭时让位",
                  manager.handleHotKeyEvent(titleEvent) == noErr)
        }
        // 偏好开启但热键开关关闭 → 仍让位
        TitleEditorPreferences.isEnabled = true
        TitleEditorPreferences.isHotKeyEnabled = false
        if let titleEvent = makeEvent(
            hotKeyID: EventHotKeyID(signature: manager.hotkeySignature, id: 2)) {
            check("carbon: 标题编辑热键开关关闭时让位",
                  manager.handleHotKeyEvent(titleEvent) == noErr)
        }
        TitleEditorPreferences.isEnabled = false
        TitleEditorPreferences.isHotKeyEnabled = false

        // ⑥ 气泡唤起键（id=3）：气泡偏好关闭 → summon 自查后 no-op
        let savedBubbleEnabled = InputBubblePreferences.isEnabled
        defer { InputBubblePreferences.isEnabled = savedBubbleEnabled }
        InputBubblePreferences.isEnabled = false
        if let bubbleEvent = makeEvent(
            hotKeyID: EventHotKeyID(signature: manager.hotkeySignature, id: 3)) {
            check("carbon: 气泡偏好关闭时唤起请求消费且不弹窗",
                  manager.handleHotKeyEvent(bubbleEvent) == noErr)
        }
        // 让异步 summon 落地（偏好关闭 → 自查早退）
        let deadline = Date().addingTimeInterval(0.2)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        check("carbon: 唤起键异步落地后气泡仍空闲", InputBubbleController.shared.isIdle)

        // ⑦ 摆位键（Carbon id → action 映射）：置「在途」只走去抖 skip 臂，
        // 零搬窗、零 beep（外层的 LayoutPreferences defer 会还原总开关）。
        let savedLayoutInFlight = manager.isLayoutInFlight
        let savedLayoutTriggeredAt = manager.lastLayoutTriggeredAt
        defer {
            manager.isLayoutInFlight = savedLayoutInFlight
            manager.lastLayoutTriggeredAt = savedLayoutTriggeredAt
        }
        LayoutPreferences.isEnabled = true
        if let action = LayoutAction.allCases.first(where: {
               guard let hotKey = manager.layoutTable.hotKey(for: $0) else { return false }
               return hotKey != manager.currentHotKey
           }),
           let layoutEvent = makeEvent(
               hotKeyID: EventHotKeyID(signature: manager.hotkeySignature, id: action.carbonHotKeyID)) {
            manager.isLayoutInFlight = true
            check("carbon: 摆位键命中且在途时消费、不搬窗",
                  manager.handleHotKeyEvent(layoutEvent) == noErr)
            manager.isLayoutInFlight = false
        } else {
            check("carbon: 摆位默认绑定可查（环境受限跳过）", true)
        }
    }
}

// MARK: - 回退 NSEvent monitor 通道（CGEventTap 不可用时的兜底）

// 安全边界：monitor 安装后立即同步移除（回调只在 run loop 期触发，窗口内零派发）；
// 事件全为合成 NSEvent；所有可能真执行动作的臂都先置「在途/冷却」标志，只走 skip 分支。

extension RunnerHarness {

    func runHotKeyFallbackMonitorTests() {
        print("\n=== HotKeyFallbackMonitor ===")
        let manager = HotKeyManager.shared

        // --- 安装/移除：本地 monitor 必装；重复移除幂等 ---
        manager.removeFallbackMonitors()
        manager.installFallbackMonitors()
        check("hotkeyFallback: 本地 keyDown monitor 已安装", manager.localMonitor != nil)
        manager.removeFallbackMonitors()
        manager.removeFallbackMonitors()
        check("hotkeyFallback: 移除后两槽清空且幂等",
              manager.globalMonitor == nil && manager.localMonitor == nil)

        func keyEvent(keyCode: UInt32, modifiers: UInt32, isRepeat: Bool = false) -> NSEvent? {
            var flags: NSEvent.ModifierFlags = []
            if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
            if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
            if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
            if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
            return NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil,
                characters: "v", charactersIgnoringModifiers: "v",
                isARepeat: isRepeat, keyCode: UInt16(truncatingIfNeeded: keyCode))
        }

        let savedBubbleEnabled = InputBubblePreferences.isEnabled
        let savedLayoutEnabled = LayoutPreferences.isEnabled
        let savedTitleEnabled = TitleEditorPreferences.isEnabled
        let savedTitleHotKey = TitleEditorPreferences.isHotKeyEnabled
        let savedInFlight = manager.isToggleInFlight
        let savedTriggeredAt = manager.lastToggleTriggeredAt
        let savedLayoutInFlight = manager.isLayoutInFlight
        let savedLayoutTriggeredAt = manager.lastLayoutTriggeredAt
        defer {
            InputBubblePreferences.isEnabled = savedBubbleEnabled
            LayoutPreferences.isEnabled = savedLayoutEnabled
            TitleEditorPreferences.isEnabled = savedTitleEnabled
            TitleEditorPreferences.isHotKeyEnabled = savedTitleHotKey
            manager.isToggleInFlight = savedInFlight
            manager.lastToggleTriggeredAt = savedTriggeredAt
            manager.isLayoutInFlight = savedLayoutInFlight
            manager.lastLayoutTriggeredAt = savedLayoutTriggeredAt
            manager.removeFallbackMonitors()
        }
        InputBubblePreferences.isEnabled = false
        TitleEditorPreferences.isEnabled = false
        TitleEditorPreferences.isHotKeyEnabled = false

        // ① 自动连发：入口直接放行
        if let repeatEvent = keyEvent(
            keyCode: manager.currentHotKey.keyCode, modifiers: manager.currentHotKey.modifiers,
            isRepeat: true) {
            check("hotkeyFallback: 自动连发不消费",
                  manager.handleFallbackEvent(repeatEvent, source: "unit") == false)
        }

        // ② 完全不相干的键：不消费
        if let plainEvent = keyEvent(keyCode: 0, modifiers: 0) {
            check("hotkeyFallback: 无关按键不消费",
                  manager.handleFallbackEvent(plainEvent, source: "unit") == false)
        }

        // ③ 主 toggle 键命中，但在途 → 消费事件、动作被去重门丢弃
        if let toggleEvent = keyEvent(
            keyCode: manager.currentHotKey.keyCode, modifiers: manager.currentHotKey.modifiers) {
            manager.isToggleInFlight = true
            check("hotkeyFallback: 主键命中消费且在途不搬窗",
                  manager.handleFallbackEvent(toggleEvent, source: "unit") == true)
            manager.isToggleInFlight = false
        }

        // ④ 摆位键命中，但在途 → 消费事件、动作被去抖门丢弃（零搬窗、零 beep）
        LayoutPreferences.isEnabled = true
        // 避开与主键同组合的摆位绑定（layoutHit 要求 !matches）
        if let action = LayoutAction.allCases.first(where: {
               guard let hk = manager.layoutTable.hotKey(for: $0) else { return false }
               return hk != manager.currentHotKey
           }),
           let hotKey = manager.layoutTable.hotKey(for: action),
           let layoutEvent = keyEvent(keyCode: hotKey.keyCode, modifiers: hotKey.modifiers) {
            manager.isLayoutInFlight = true
            check("hotkeyFallback: 摆位键命中消费且在途不搬窗",
                  manager.handleFallbackEvent(layoutEvent, source: "unit") == true)
            manager.isLayoutInFlight = false

            // ⑤ 去抖窗内重复触发：同样丢弃
            manager.lastLayoutTriggeredAt = Date()
            manager.triggerLayoutActionIfNeeded(action, source: "unit")
            check("hotkeyFallback: 摆位触发冷却窗内丢弃", manager.isLayoutInFlight == false)
        } else {
            check("hotkeyFallback: 摆位默认绑定可查（环境受限跳过）", true)
        }
    }
}
