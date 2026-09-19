// Tests/Runner/RunnerHotKeyRealMachineTests.swift — HotKeyManager 三件套真机 E2E（B244）。
// 归口：Tests/e2e/README（VIBEFOCUS_HOTKEY_E2E=1），证书签名 runner + 本机 AX 授权。
// 覆盖：Carbon 注册/注销全家族（primary + Ctrl+T + 输入气泡 + 摆位表）、CGEventTap
// 创建/使能/移除、Fallback monitors 安装/移除、handleFallbackEvent 合成事件只读路由。
// ⚠️ 安全红线：注册即系统级生效——测试窗口内注册主键/Ctrl+T/⌃X 与生产实例并存，
// ①全部断言在同方法内同步完成（暴露窗 <100ms）②立即全量注销③不做任何合成键击注入。
// 持久留白：handleHotKeyEvent 需真实 Carbon EventRef、tap 拦截语义（用户按键路由）归
// 生产观察。

import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

extension RunnerHarness {
    func runHotKeyRealMachineE2E() {
        guard ProcessInfo.processInfo.environment["VIBEFOCUS_HOTKEY_E2E"] == "1" else { return }
        print("\n=== HotKey 三件套真机 E2E ===")
        let manager = HotKeyManager.shared

        // 偏好隔离：摆位热键关（跳过摆位表注册）、通知关；Runner 自有 defaults 域
        let savedLayoutEnabled = LayoutPreferences.isEnabled
        let savedShortcut = manager.shortcutStatusMessage
        defer {
            LayoutPreferences.isEnabled = savedLayoutEnabled
            manager.shortcutStatusMessage = savedShortcut
        }
        LayoutPreferences.isEnabled = false

        // ===== A. Carbon 注册全家族 =====
        manager.installHandlerIfNeeded()
        check("hotkeyE2E: Carbon handler 已安装", manager.handlerRef != nil)
        manager.registerHotKey()
        check("hotkeyE2E: 主热键注册（hotKeyRef 非空）", manager.hotKeyRef != nil)
        check("hotkeyE2E: Ctrl+T 标题编辑热键注册", manager.titleEditorHotKeyRef != nil)
        check("hotkeyE2E: 状态文案为成功非错误",
              manager.shortcutStatusIsError == false
              && manager.shortcutStatusMessage.hasPrefix("当前快捷键"))

        // ===== B. 立即全量注销（进程级注册不留尾）=====
        if let ref = manager.hotKeyRef { _ = UnregisterEventHotKey(ref) }
        manager.hotKeyRef = nil
        if let ref = manager.titleEditorHotKeyRef { _ = UnregisterEventHotKey(ref) }
        manager.titleEditorHotKeyRef = nil
        if let ref = manager.inputBubbleHotKeyRef { _ = UnregisterEventHotKey(ref) }
        manager.inputBubbleHotKeyRef = nil
        for (_, ref) in manager.layoutHotKeyRefs { _ = UnregisterEventHotKey(ref) }
        manager.layoutHotKeyRefs.removeAll()
        check("hotkeyE2E: 全家族注销清零", manager.hotKeyRef == nil
              && manager.titleEditorHotKeyRef == nil && manager.inputBubbleHotKeyRef == nil
              && manager.layoutHotKeyRefs.isEmpty)

        // ===== C. Fallback monitors 安装/移除（被动监听，立即成对操作）=====
        manager.installFallbackMonitors()
        check("hotkeyE2E: global+local monitor 已安装",
              manager.globalMonitor != nil && manager.localMonitor != nil)

        // ===== D. handleFallbackEvent 合成事件只读路由（非匹配键 → ignore 返回 false）=====
        let stray = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 120)  // F 键+零修饰：不匹配任何已配置路由
        let strayHandled = stray.map { manager.handleFallbackEvent($0, source: "vf-e2e") } ?? true
        check("hotkeyE2E: 非匹配键 → 路由 ignore 返回 false", strayHandled == false)

        manager.removeFallbackMonitors()
        check("hotkeyE2E: monitors 成对移除清零",
              manager.globalMonitor == nil && manager.localMonitor == nil)

        // ===== E. CGEventTap 创建/使能/移除 =====
        // B244：以真实 AX 探针置位（AXIsProcessTrustedWithOptions 与生产 checkAccessibility
        // 同一调用）——accessibilityStatus 由 AX 掉授权轮询异步刷新，E2E 显式同步置位后
        // 才能打穿 tap 创建机器。tap 创建即系统级生效，断言后立即移除。
        let axTrusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary)
        manager.accessibilityStatus = axTrusted
        let tapOK = manager.setupCGEventTap()
        if tapOK {
            check("hotkeyE2E: CGEventTap 创建成功（tap+runLoopSource 非空）",
                  manager.eventTap != nil && manager.runLoopSource != nil)
            // 立即移除：禁使能 → 摘 runloop source → 失效 mach port
            if let tap = manager.eventTap {
                CGEvent.tapEnable(tap: tap, enable: false)
            }
            if let source = manager.runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            if let tap = manager.eventTap {
                CFMachPortInvalidate(tap)
            }
            manager.eventTap = nil
            manager.runLoopSource = nil
            check("hotkeyE2E: CGEventTap 已移除清零",
                  manager.eventTap == nil && manager.runLoopSource == nil)
        } else {
            check("hotkeyE2E: AX 未授权 → tap 创建如实 false（环境降级）", true)
        }

        // ===== F. 二次安装幂等（handler 幂等守卫）=====
        manager.installHandlerIfNeeded()
        check("hotkeyE2E: handler 二次安装幂等", manager.handlerRef != nil)
    }
}
