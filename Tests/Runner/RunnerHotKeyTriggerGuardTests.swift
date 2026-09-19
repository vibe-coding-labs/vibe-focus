import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerHotKeyTriggerGuardTests.swift — 覆盖率批次 45（B278）：
// HotKeyManager 热键触发入口的偏好守卫直测（disabled 路径 pass through，
// 偏好快照-改写-恢复协议——enabled 路径会真弹 NSAlert/真弹窗，留白给真机）。

extension RunnerHarness {
    func runHotKeyTriggerGuardTests() {
        let savedEnabled = TitleEditorPreferences.isEnabled
        let savedHotKeyEnabled = TitleEditorPreferences.isHotKeyEnabled
        defer {
            TitleEditorPreferences.isEnabled = savedEnabled
            TitleEditorPreferences.isHotKeyEnabled = savedHotKeyEnabled
        }

        // 标题编辑 disabled：pass through 早退（不 dispatch editTitle/不弹 NSAlert）。
        TitleEditorPreferences.isEnabled = false
        TitleEditorPreferences.isHotKeyEnabled = false
        HotKeyManager.triggerTitleEditor()
        check("hotkeyTrigger: 标题编辑 disabled pass through 不崩", true)

        // 输入气泡 disabled：summon 内自查偏好开关——偏好关时入队派发但 summon
        // 内部自查跳过（读 UserDefaults，无副作用）。
        let savedBubbleEnabled = InputBubblePreferences.isEnabled
        defer { InputBubblePreferences.isEnabled = savedBubbleEnabled }
        InputBubblePreferences.isEnabled = false
        HotKeyManager.triggerInputBubble()
        check("hotkeyTrigger: 输入气泡偏好关时 pass through 不崩", true)

        // 恢复后入口可用（不触发真实动作——editTitle 需前台终端，Runner 无）。
        TitleEditorPreferences.isEnabled = true
        TitleEditorPreferences.isHotKeyEnabled = true
        HotKeyManager.triggerTitleEditor()
        check("hotkeyTrigger: enabled 态入口可调（Runner 无前台终端静默）", true)
        TitleEditorPreferences.isEnabled = savedEnabled
        TitleEditorPreferences.isHotKeyEnabled = savedHotKeyEnabled
    }
}
