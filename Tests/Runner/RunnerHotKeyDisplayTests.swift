import Foundation
import Carbon
@testable import VibeFocusKit

// Tests/Runner/RunnerHotKeyDisplayTests.swift — B65：HotKey 展示契约直测。
// Tests/Standalone/HotKeyDisplayTests.swift 漂移镜像就此退役：镜像复制了 struct +
// 56 个 kVK 常量 + displayKey/modifierDisplay 全套形状，测的是副本而非真身，
// 真身改动不会红。本文件改测 Sources/HotKey/HotKeyConfiguration.swift 真实实现，
// 修饰键符号走 displayString 复合通道（modifierDisplay 为 private，复合表达式
// = modifierDisplay + displayKey 全覆盖）。

extension RunnerHarness {
    func runHotKeyDisplayTests() {
        // A. displayLabels 全表契约锁：字典整表比对——多一条、少一条、改任何文案都会红。
        let expectedLabels: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Space: "Space", kVK_Return: "Return", kVK_Escape: "Esc",
            kVK_Delete: "Delete", kVK_ForwardDelete: "Fn⌫", kVK_Tab: "Tab",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        check("hotkeyDisplay: displayLabels 与展示契约逐键一致（58 键全表）",
              HotKeyConfiguration.displayLabels == expectedLabels)
        check("hotkeyDisplay: displayKey 查表命中与表外 ? 兜底",
              HotKeyConfiguration.displayKey(for: UInt32(kVK_ANSI_Q)) == "Q"
              && HotKeyConfiguration.displayKey(for: UInt32(kVK_ForwardDelete)) == "Fn⌫"
              && HotKeyConfiguration.displayKey(for: UInt32(0xFF)) == "?"
              && HotKeyConfiguration.displayKey(for: UInt32(0xFE)) == "?")

        // B. 修饰键符号与固定序（⌃⌥⇧⌘）——经 displayString 复合通道锁定。
        func display(_ keyCode: Int, _ modifiers: UInt32) -> String {
            HotKeyConfiguration(keyCode: UInt32(keyCode), modifiers: modifiers).displayString
        }
        check("hotkeyDisplay: 单修饰键符号逐一锁定",
              display(kVK_ANSI_Q, UInt32(controlKey)) == "⌃Q"
              && display(kVK_ANSI_Q, UInt32(optionKey)) == "⌥Q"
              && display(kVK_ANSI_Q, UInt32(shiftKey)) == "⇧Q"
              && display(kVK_ANSI_Q, UInt32(cmdKey)) == "⌘Q")
        check("hotkeyDisplay: 无修饰键 = 裸键名",
              display(kVK_ANSI_Q, 0) == "Q")
        check("hotkeyDisplay: 全修饰键固定序 ⌃⌥⇧⌘",
              display(kVK_Escape, UInt32(controlKey | optionKey | shiftKey | cmdKey)) == "⌃⌥⇧⌘Esc")
        check("hotkeyDisplay: 部分组合跳过缺位修饰键",
              display(kVK_ANSI_F, UInt32(controlKey | cmdKey)) == "⌃⌘F"
              && display(kVK_ANSI_F, UInt32(optionKey | shiftKey | cmdKey)) == "⌥⇧⌘F")

        // C. 值语义：Codable 回环 / JSON 字段 / Equatable + Hashable。
        let original = HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(controlKey))
        let decoded = try? JSONDecoder().decode(
            HotKeyConfiguration.self, from: JSONEncoder().encode(original))
        check("hotkeyDisplay: Codable 回环保真",
              decoded == original)
        let json = (try? JSONSerialization.jsonObject(
            with: JSONEncoder().encode(original))) as? [String: Any]
        check("hotkeyDisplay: JSON 含 keyCode/modifiers 两字段",
              json?.count == 2 && json?["keyCode"] != nil && json?["modifiers"] != nil)
        let twin = HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(controlKey))
        let other = HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(optionKey))
        check("hotkeyDisplay: Equatable + Hashable 同值同散列",
              original == twin && original != other
              && Set([original, twin]).count == 1
              && Set([original, other]).count == 2)

        // D. 默认值与系统冲突清单契约（热键默认改动能被红字捕获）。
        check("hotkeyDisplay: default=⌃Q / legacyDefault=⌃⌥⌘M",
              HotKeyConfiguration.default == HotKeyConfiguration(
                  keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(controlKey))
              && HotKeyConfiguration.legacyDefault == HotKeyConfiguration(
                  keyCode: UInt32(kVK_ANSI_M),
                  modifiers: UInt32(controlKey | optionKey | cmdKey)))
        check("hotkeyDisplay: userDefaultsKey 稳定",
              HotKeyConfiguration.userDefaultsKey == "hotKeyConfiguration")
        let conflicts = HotKeyConfiguration.knownConflicts
        check("hotkeyDisplay: knownConflicts 9 条、理由非空、配置互异",
              conflicts.count == 9
              && conflicts.allSatisfy { !$0.reason.isEmpty }
              && Set(conflicts.map(\.configuration)).count == conflicts.count)
    }
}
