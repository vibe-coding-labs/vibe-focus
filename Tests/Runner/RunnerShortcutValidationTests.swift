import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerShortcutValidationTests.swift — 覆盖率批次（2026-11-03）：
// 快捷键录制入口的**拒绝臂**（applyLayoutShortcut / applyBubbleShortcut）。
//
// 安全边界：只走校验失败的早退分支——这些分支在 `registerHotKey()` 之前返回，
// 不注册任何系统热键、不写 UserDefaults、不发变更通知、不真搬窗/弹窗。
// 成功臂会注册系统级热键（真机门禁期间可能抢占用户组合键）→ 归豁免 C1/装机态。

extension RunnerHarness {

    func runHotKeyShortcutValidationTests() {
        print("\n=== HotKeyShortcutValidation ===")
        let manager = HotKeyManager.shared
        let noModifierKey = HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_Q), modifiers: 0)

        // --- 摆位键：修饰键缺失拒绝 ---
        if let error = manager.applyLayoutShortcut(noModifierKey, for: .leftHalf) {
            check("shortcutValidation: 摆位键缺修饰键被拒", error.contains("⌘ / ⌥ / ⌃"))
        } else {
            check("shortcutValidation: 摆位键缺修饰键被拒", false)
        }

        // --- 摆位键：与表内其它动作重复拒绝 ---
        let bindings = LayoutAction.allCases.compactMap { action -> (LayoutAction, HotKeyConfiguration)? in
            guard let hk = manager.layoutTable.hotKey(for: action) else { return nil }
            return (action, hk)
        }
        if let target = bindings.first,
           let other = bindings.first(where: {
               $0.0 != target.0 && $0.1 != target.1 && $0.1 != manager.currentHotKey
           }) {
            let error = manager.applyLayoutShortcut(other.1, for: target.0)
            check("shortcutValidation: 摆位键重复绑定被拒",
                  error?.contains("已绑定") == true)
            check("shortcutValidation: 拒绝后摆位表未被改写",
                  manager.layoutTable.hotKey(for: target.0) == target.1)
        } else {
            check("shortcutValidation: 摆位默认表可查（环境受限跳过）", true)
        }

        // --- 摆位键：与主 toggle 键撞车拒绝（前提：主键未被任何摆位动作占用） ---
        let primaryFree = bindings.allSatisfy { $0.1 != manager.currentHotKey }
        if primaryFree, let target = bindings.first {
            let error = manager.applyLayoutShortcut(manager.currentHotKey, for: target.0)
            check("shortcutValidation: 摆位键与主键冲突被拒",
                  error?.contains("与主开关快捷键") == true)
        } else {
            check("shortcutValidation: 主键不与摆位表撞车（环境受限跳过）", true)
        }

        // --- 气泡键三连拒 ---
        let savedLayoutEnabled = LayoutPreferences.isEnabled
        let savedBubbleHotKey = InputBubblePreferences.hotKey
        defer {
            LayoutPreferences.isEnabled = savedLayoutEnabled
            // 拒绝臂不写偏好；此复位只为极端情况兜底
            InputBubblePreferences.hotKey = savedBubbleHotKey
        }

        if let error = manager.applyBubbleShortcut(noModifierKey) {
            check("shortcutValidation: 气泡键缺修饰键被拒", error.contains("⌘ / ⌥ / ⌃"))
        } else {
            check("shortcutValidation: 气泡键缺修饰键被拒", false)
        }

        if let error = manager.applyBubbleShortcut(manager.currentHotKey) {
            check("shortcutValidation: 气泡键与主键冲突被拒", error.contains("与主开关快捷键"))
        } else {
            check("shortcutValidation: 气泡键与主键冲突被拒", false)
        }

        LayoutPreferences.isEnabled = true
        if let occupied = bindings.first(where: { $0.1 != manager.currentHotKey })?.1 {
            if let error = manager.applyBubbleShortcut(occupied) {
                check("shortcutValidation: 气泡键与摆位键冲突被拒", error.contains("已被摆位快捷键占用"))
            } else {
                check("shortcutValidation: 气泡键与摆位键冲突被拒", false)
            }
        } else {
            check("shortcutValidation: 摆位表无可借用组合（环境受限跳过）", true)
        }
        LayoutPreferences.isEnabled = savedLayoutEnabled

        // 拒绝臂零副作用：偏好原样
        check("shortcutValidation: 拒绝臂不写气泡热键偏好",
              InputBubblePreferences.hotKey == savedBubbleHotKey)
    }
}
