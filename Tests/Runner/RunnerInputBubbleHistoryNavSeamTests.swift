import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerInputBubbleHistoryNavSeamTests.swift
// 靶：InputBubbleController.applyHistoryNav / setNavText 的翻阅执行半区——
// 首次进入 stash、逐条换文本、越界不动作、走出最新一条回现场、无历史不消费。
// 纪律：无面板、无 draft/history 库写（target=nil），只动合成 NSTextView。

extension RunnerHarness {
    func runInputBubbleHistoryNavSeamTests() {
        let controller = InputBubbleController.shared
        let savedPhase = controller.phase
        let savedTarget = controller.target
        let savedIndex = controller.historyNavIndex
        let savedStash = controller.historyStashedText
        defer {
            controller.phase = savedPhase
            controller.target = savedTarget
            controller.historyNavIndex = savedIndex
            controller.historyStashedText = savedStash
        }

        controller.phase = .open
        controller.target = nil
        controller.historyNavIndex = nil
        controller.historyStashedText = nil

        let entries = [
            InputBubbleHistoryEntry(text: "newest", at: Date(), status: .draft),
            InputBubbleHistoryEntry(text: "older", at: Date(), status: .draft),
        ]
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        tv.string = "live-text"

        // A. 首次 ↑：进入翻阅并 stash 现场
        let moved = controller.applyHistoryNav(.moveTo(index: 1), entries: entries, textView: tv)
        check("bubbleHistoryNav A1: moveTo 消费按键且展示目标条目",
              moved == true && tv.string == "older" && controller.historyNavIndex == 1)
        check("bubbleHistoryNav A2: 首次进入 stash 现场文本 + 光标跳尾",
              controller.historyStashedText == "live-text"
              && tv.selectedRange() == NSRange(location: 5, length: 0))

        // B. 再次 moveTo 不覆盖 stash
        controller.historyStashedText = "live-text"
        tv.string = "older"
        _ = controller.applyHistoryNav(.moveTo(index: 0), entries: entries, textView: tv)
        check("bubbleHistoryNav B1: 翻阅中换条目不重写 stash",
              tv.string == "newest" && controller.historyStashedText == "live-text"
              && controller.historyNavIndex == 0)

        // C. 越界 moveTo：仍消费但不改文本/下标
        let outOfRange = controller.applyHistoryNav(.moveTo(index: 9), entries: entries, textView: tv)
        check("bubbleHistoryNav C1: 越界条目下标 → 消费但不动作",
              outOfRange == true && tv.string == "newest" && controller.historyNavIndex == 0)

        // D. 走出最新一条 → 回编辑现场
        let exited = controller.applyHistoryNav(.exitToStashed, entries: entries, textView: tv)
        check("bubbleHistoryNav D1: exitToStashed 还原现场并清空翻阅态",
              exited == true && tv.string == "live-text"
              && controller.historyNavIndex == nil && controller.historyStashedText == nil)

        // E. .none 不消费
        let none = controller.applyHistoryNav(.none, entries: [], textView: tv)
        check("bubbleHistoryNav E1: 无历史动作不消费按键", none == false && tv.string == "live-text")

        // F. setNavText 独立换文本（target=nil 不落草稿库）
        controller.setNavText("direct", textView: tv)
        check("bubbleHistoryNav F1: setNavText 换文本并跳尾",
              tv.string == "direct" && tv.selectedRange() == NSRange(location: 6, length: 0))
    }
}
