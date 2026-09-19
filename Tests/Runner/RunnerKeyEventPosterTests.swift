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
