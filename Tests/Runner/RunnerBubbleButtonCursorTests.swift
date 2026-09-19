import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerBubbleButtonCursorTests.swift — 覆盖率批次 36（B268）：
// 气泡提交钮/关闭钮/历史钮的 cursorUpdate/draw 直测（B228 无窗口 NSView 模式，
// 合成 NSEvent 驱动；NSGradient 绘制在无图形上下文时静默无效不崩）。

extension RunnerHarness {
    func runBubbleButtonCursorTests() {
        let event = NSEvent.mouseEvent(
            with: .mouseMoved, location: NSPoint(x: 5, y: 5), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!

        // 提交钮：cursorUpdate 设置小手 + draw 渐变（bounds 有效性不影响不崩）。
        let submit = BubbleSubmitButton()
        submit.frame = NSRect(x: 0, y: 0, width: 64, height: 24)
        submit.cursorUpdate(with: event)
        submit.draw(submit.bounds)
        check("bubbleButton: 提交钮 cursorUpdate/draw 直调不崩", true)

        // 关闭钮：cursorUpdate + draw。
        let close = BubbleCloseButton()
        close.frame = NSRect(x: 0, y: 0, width: 16, height: 16)
        close.cursorUpdate(with: event)
        close.draw(close.bounds)
        check("bubbleButton: 关闭钮 cursorUpdate/draw 直调不崩", true)
    }
}
