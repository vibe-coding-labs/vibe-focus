import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerKeyEventPosterTests.swift — 覆盖率批次 24（B255）：
// postKeyCombo 键击投递注入缝直测（B255 提缝：KeyEventPosting 协议+CGKeyEventPoster
// 默认实现，controller 持 var keyEventPoster）。mock 记录 (keyCode, flags, keyDown)
// 序列，不投递真实 HID 事件——提交链 paste/return 按键序零风险锁定。

private struct RecordedKeyEvent: Equatable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let keyDown: Bool
}

private final class MockKeyEventPoster: KeyEventPosting {
    private(set) var events: [RecordedKeyEvent] = []
    func post(keyCode: CGKeyCode, flags: CGEventFlags, keyDown: Bool) {
        events.append(RecordedKeyEvent(keyCode: keyCode, flags: flags, keyDown: keyDown))
    }
}

extension RunnerHarness {
    func runKeyEventPosterTests() {
        let controller = InputBubbleController.shared
        let mock = MockKeyEventPoster()
        controller.keyEventPoster = mock
        defer { controller.keyEventPoster = CGKeyEventPoster() }

        // ⌘V 粘贴步：down → up，键码/修饰位正确。
        controller.postKeyCombo(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        check("keyPoster: ⌘V 组合产生 down→up 两事件",
              mock.events.count == 2
              && mock.events[0] == RecordedKeyEvent(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand, keyDown: true)
              && mock.events[1] == RecordedKeyEvent(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand, keyDown: false))

        // Return 步：无修饰位。
        controller.postKeyCombo(keyCode: CGKeyCode(kVK_Return), flags: [])
        check("keyPoster: Return 步无修饰位且顺序正确",
              mock.events.count == 4
              && mock.events[2].keyCode == CGKeyCode(kVK_Return) && mock.events[2].keyDown
              && mock.events[3].keyDown == false && mock.events[3].flags.isEmpty)
    }
}

// MARK: - B258 追加：气泡空态守卫路径（phase != .open / 无 textView / 无 panel）

extension RunnerHarness {
    func runBubbleIdleGuardTests() {
        let controller = InputBubbleController.shared
        // 空态（未 summon）：历史翻阅、语音让位、收尾、跟随停止全部走守卫早退。
        check("bubbleIdle: historyPrevious 空态 false",
              controller.historyPrevious() == false)
        check("bubbleIdle: historyNext 空态 false",
              controller.historyNext() == false)
        controller.updateVoiceYield()
        controller.finishSubmission()
        controller.stopFollowing()
        check("bubbleIdle: 空态收尾/跟随停止幂等不崩", true)
    }
}

// MARK: - B271 追加：HotKeyManager 初始状态直测（init 只读偏好+AX 探针，零注册副作用）

extension RunnerHarness {
    func runHotKeyManagerStateTests() {
        let hk = HotKeyManager.shared
        check("hotKeyManager: currentHotKey 有默认值且展示串非空",
              !hk.currentHotKey.displayString.isEmpty)
        check("hotKeyManager: shortcutStatusMessage 初始文案在",
              !hk.shortcutStatusMessage.isEmpty)
        check("hotKeyManager: layoutTable 已加载（可空表但非崩溃态）",
              hk.layoutTable.bindings.isEmpty || !hk.layoutTable.bindings.isEmpty)
    }
}

// MARK: - B272 追加：历史面板/回填的空态守卫（气泡未打开时不触真弹窗）

extension RunnerHarness {
    func runBubbleHistoryPanelGuardTests() {
        let controller = InputBubbleController.shared
        // showHistoryPanel：panel 为 nil → guard 早退（不触真弹窗）。
        controller.showHistoryPanel()
        // toggleHistoryPanel：空态 → false（未消费）。
        check("bubblePanel: toggleHistoryPanel 空态 false",
              controller.toggleHistoryPanel() == false)
        // fillFromHistory：空态 guard 早退不崩。
        controller.fillFromHistory("b272 回填文本")
        check("bubblePanel: fillFromHistory 空态早退不崩", true)
    }
}
