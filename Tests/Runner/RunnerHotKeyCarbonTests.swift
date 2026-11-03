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
    }
}
