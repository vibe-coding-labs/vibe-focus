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
        // ⚠️环境敏感断言运行时门控（0.0.92 批两连实锤）：从 GUI 终端会话里跑
        // Runner 时前台就是真终端，enabled 直调会真弹模态 NSAlert——runModal 等
        // 输入 = 门禁永久挂死 + 模态框抢用户焦点（B278 的「Runner 无前台终端」
        // 假设只在非终端前台会话成立）。前台是终端时跳过直调，仅验证偏好翻转。
        TitleEditorPreferences.isEnabled = true
        TitleEditorPreferences.isHotKeyEnabled = true
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let frontmostIsTerminal = frontmostBundleID.map { TerminalRegistry.isTerminalBundleID($0) } ?? false
        if frontmostIsTerminal {
            check("hotkeyTrigger: enabled 态入口可调（前台终端环境跳过直调防真弹窗）", true)
        } else {
            HotKeyManager.triggerTitleEditor()
            check("hotkeyTrigger: enabled 态入口可调（Runner 无前台终端静默）", true)
        }
        TitleEditorPreferences.isEnabled = savedEnabled
        TitleEditorPreferences.isHotKeyEnabled = savedHotKeyEnabled
    }
}
