import AppKit
import Carbon
import Foundation

extension Notification.Name {
    static let hotKeyConfigurationDidChange = Notification.Name("HotKeyConfigurationDidChange")
    static let hookServerStateChanged = Notification.Name("ClaudeHookServerStateChanged")
    /// B162：输入气泡唤起热键变更（applyBubbleShortcut/resetBubbleShortcut 发布）
    static let inputBubbleHotKeyDidChange = Notification.Name("InputBubbleHotKeyDidChange")
}

/// Describes a conflict between the configured hotkey and a system shortcut.
struct HotKeyConflict: Equatable {
    let configuration: HotKeyConfiguration
    let reason: String
}

/// 快捷键录制器状态（B164 引入、B165 改活体派生）：录制期间 CGEventTap / NSEvent
/// monitor / Carbon handler 对本 app 已注册的热键组合全量让位——否则「录制与当前
/// 相同的组合键」（如把气泡唤起键重录成 ⌘B 本身）会在到达录制器前被自家通道消费，
/// 永远录不上。
/// 判据=key 窗第一响应者是否是录制钮。不能用布尔标志：设置窗被 orderOut/关闭时
/// resignFirstResponder 未必触发（真实链路：录制中焦点落到 Claude 终端窗→自动弹出
/// orderOut 设置窗），标志卡 true 会让位变成全部全局热键永久失灵；派生实现没有
/// 卡死态——窗口失 key 瞬间判据自动归 false。
enum ShortcutRecordingState {
    /// 活体派生：key 窗第一响应者是录制钮 → 让位。tap 回调域由 main runloop 驱动，
    /// isMainThread 守卫 + assumeIsolated 保证不 trap；非主线程回落 false（fail-closed，
    /// 录制只能从主线程 UI 发起，回落只会让位失效、不会误吞全局键）。
    static var isRecording: Bool {
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated {
            isRecordingResponder(NSApplication.shared.keyWindow?.firstResponder)
        }
    }

    /// 纯判定缝（Runner 直测）：录制钮本身 → 让位；其他响应者（含 nil）→ 不让位。
    static func isRecordingResponder(_ responder: NSResponder?) -> Bool {
        responder is ShortcutRecorderButton
    }
}

/// Global hotkey configuration stored in UserDefaults.
struct HotKeyConfiguration: Codable, Equatable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let userDefaultsKey = "hotKeyConfiguration"
    /// 标题编辑快捷键唯一事实源（⌃T，B165 提取，nonisolated struct 上无隔离问题）：
    /// 此前 17+controlKey 硬编码散在 tap/fallback/Carbon 三处，冲突校验与让位判定
    /// 漏了它——用户可把主开关/摆位/气泡键绑成 ⌃T，静默杀死标题编辑热键。
    static let titleEditor = HotKeyConfiguration(
        keyCode: UInt32(kVK_ANSI_T),
        modifiers: UInt32(controlKey)
    )
    static let legacyDefault = HotKeyConfiguration(
        keyCode: UInt32(kVK_ANSI_M),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )
    static let `default` = HotKeyConfiguration(
        keyCode: UInt32(kVK_ANSI_Q),
        modifiers: UInt32(controlKey)
    )

    static let knownConflicts: [HotKeyConflict] = [
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey)), reason: "与 Spotlight 冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | optionKey)), reason: "与 Finder 搜索冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_Tab), modifiers: UInt32(cmdKey)), reason: "与应用切换器冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_Tab), modifiers: UInt32(cmdKey | shiftKey)), reason: "与反向应用切换冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey)), reason: "与退出应用冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey)), reason: "与关闭窗口冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey)), reason: "与最小化窗口冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey)), reason: "与隐藏应用冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(cmdKey | controlKey)), reason: "与许多应用的全屏快捷键冲突")
    ]

    var displayString: String {
        modifierDisplay + Self.displayKey(for: keyCode)
    }

    private var modifierDisplay: String {
        var output = ""
        if modifiers & UInt32(controlKey) != 0 { output += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { output += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { output += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { output += "⌘" }
        return output
    }

    func matches(event: NSEvent) -> Bool {
        let eventKeyCode = UInt32(event.keyCode)
        let eventModifiers = event.modifierFlags.intersection(.hotKeyRelevantFlags).carbonHotKeyModifiers
        return eventKeyCode == keyCode && eventModifiers == modifiers
    }

    static func from(event: NSEvent) -> HotKeyConfiguration? {
        let modifiers = event.modifierFlags.intersection(.hotKeyRelevantFlags).carbonHotKeyModifiers
        guard modifiers != 0 else {
            return nil
        }

        let keyCode = UInt32(event.keyCode)
        guard displayKey(for: keyCode) != "?" else {
            return nil
        }

        return HotKeyConfiguration(keyCode: keyCode, modifiers: modifiers)
    }

    /// keyCode → 展示标签全表（58 键：字母/数字/常用编辑键/方向键/F1~F12）。
    /// 展示契约以数据形式存在；表外键码回落 "?"（from(event:) 借此滤除不可命名键）。
    static let displayLabels: [Int: String] = [
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

    static func displayKey(for keyCode: UInt32) -> String {
        displayLabels[Int(keyCode)] ?? "?"
    }
}

extension NSEvent.ModifierFlags {
    static let hotKeyRelevantFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var carbonHotKeyModifiers: UInt32 {
        var result: UInt32 = 0
        if contains(.command) { result |= UInt32(cmdKey) }
        if contains(.option) { result |= UInt32(optionKey) }
        if contains(.control) { result |= UInt32(controlKey) }
        if contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
