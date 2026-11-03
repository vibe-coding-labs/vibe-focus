import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerBubbleHistoryPanelControllerTests.swift — 覆盖率批次（2026-11-03）：
// 输入历史面板**控制器编排层**直测（B196/B203/B204/B306）。
//
// 与既有域的分工：
// - RunnerBubbleHistoryPanelViewTests（B228）已直测徽章/迷你钮/行视图的 layout 与命中；
// - RunnerInputBubbleTests 的 runBubbleHistoryPanelTests（B196）已测存储/过滤/宽松解码；
// - 本文件补的是**控制器本身**：open→头部构建→refresh 整表重建→搜索实时过滤→
//   范围切换→展开/收起→复制/删除/填充→搜索框回车填充→清空两段确认（含 3s 自动
//   还原与空集提示）→关闭钮/toggle 收面板。
//
// 安全红线：真开一块我方 NSPanel（并短暂 activate）——用户活跃期（2 分钟内有真实
// 输入）诚实跳过；defaults 域（inputBubbleHistory）先快照后恢复；激活策略原样还原。

private func historyPanelHostWindow(_ view: NSView, size: NSSize) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view
    return window
}

extension RunnerHarness {

    func runBubbleHistoryPanelControllerTests() {
        print("\n=== BubbleHistoryPanelController ===")

        // 面板内容底（奶油暖底+圆角描边）——离屏绘制，恒跑
        let contentBG = HistoryPanelContentView(frame: NSRect(x: 0, y: 0, width: 460, height: 520))
        let bgWindow = historyPanelHostWindow(contentBG, size: NSSize(width: 460, height: 520))
        contentBG.layoutSubtreeIfNeeded()
        let bgRep = contentBG.bitmapImageRepForCachingDisplay(in: contentBG.bounds)
        if let bgRep { contentBG.cacheDisplay(in: contentBG.bounds, to: bgRep) }
        check("historyCtl: 内容底离屏绘制且圆角层就位",
              bgRep != nil && bgWindow.contentView === contentBG)

        // ---------- 控制器全链（真面板；用户活跃期跳过） ----------

        let secondsSinceInput = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if secondsSinceInput < 120,
           ProcessInfo.processInfo.environment["VIBEFOCUS_BUBBLE_LIFECYCLE_TESTS"] != "1" {
            check("historyCtl: 用户活跃期诚实跳过真面板链路", true)
            return
        }

        _ = NSApplication.shared
        let savedPolicy = NSApp.activationPolicy()
        let defaults = UserDefaults.standard
        let savedHistory = defaults.data(forKey: "inputBubbleHistory")
        defaults.removeObject(forKey: "inputBubbleHistory")
        let controller = InputBubbleHistoryPanelController.shared
        defer {
            controller.close()
            if let savedHistory {
                defaults.set(savedHistory, forKey: "inputBubbleHistory")
            } else {
                defaults.removeObject(forKey: "inputBubbleHistory")
            }
            NSApp.setActivationPolicy(savedPolicy)
        }

        func pump(_ seconds: Double) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        func panel() -> InputBubbleHistoryPanel? {
            NSApp.windows.compactMap { $0 as? InputBubbleHistoryPanel }.first { $0.isVisible }
        }
        func contentOfPanel() -> NSView? { panel()?.contentView }
        func miniButton(_ title: String) -> HistoryMiniButton? {
            contentOfPanel()?.subviews.compactMap { $0 as? HistoryMiniButton }.first { $0.title == title }
        }
        func searchField() -> NSTextField? {
            contentOfPanel()?.subviews.compactMap { $0 as? NSTextField }
                .first { $0.placeholderString == "搜索正文或窗名…" }
        }
        func countLabel() -> NSTextField? {
            contentOfPanel()?.subviews.compactMap { $0 as? NSTextField }
                .first { $0.frame.origin.x == 152 }
        }
        func toastLabel() -> NSTextField? {
            contentOfPanel()?.subviews.compactMap { $0 as? NSTextField }
                .first { $0.frame.origin.x == 108 }
        }
        func segmented() -> NSSegmentedControl? {
            contentOfPanel()?.subviews.compactMap { $0 as? NSSegmentedControl }.first
        }
        func listRows() -> [HistoryRowView] {
            guard let scroll = contentOfPanel()?.subviews.compactMap({ $0 as? NSScrollView }).first,
                  let document = scroll.documentView else { return [] }
            return document.subviews.compactMap { $0 as? HistoryRowView }
        }
        // 直接走 NSTextFieldDelegate 回调（生产里由字段编辑器触发同一方法；手动投
        // Notification 不会经过 NSControl 的委托分发）。
        func typeSearch(_ text: String) {
            guard let field = searchField() else { return }
            field.stringValue = text
            controller.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: field))
        }
        func switchScope(toAll: Bool) {
            guard let segmented = segmented(),
                  let target = segmented.target as? NSObject,
                  let action = segmented.action else { return }
            segmented.selectedSegment = toAll ? 1 : 0
            _ = target.perform(action, with: segmented)
        }

        let store = InputBubbleHistoryStore.shared
        let seedNow = Date()
        store.record("Alpha 已提交正文", windowID: 5_150, windowTitle: "iTerm2 Alpha",
                     status: .submitted, now: seedNow)
        store.record("Beta 草稿正文", windowID: 5_150, windowTitle: "iTerm2 Alpha",
                     status: .draft, now: seedNow.addingTimeInterval(-60))
        store.record("另一个窗口的正文", windowID: 6_161, windowTitle: "Zsh Beta",
                     status: .submitted, now: seedNow.addingTimeInterval(-120))

        var filled: [String] = []
        controller.toggle(
            anchorFrame: CGRect(x: 200, y: 400, width: 500, height: 180),
            currentWindowID: 5_150,
            fill: { filled.append($0) })
        pump(0.4)

        check("historyCtl: 打开面板并落位", controller.isVisible && panel() != nil)
        check("historyCtl: 默认本窗过滤出 2 条", listRows().count == 2)
        check("historyCtl: 计数标签显示本窗条数", countLabel()?.stringValue == "2 条 · 本窗")
        // makeFirstResponder(field) 会装字段编辑器：firstResponder 可能是字段本身，
        // 也可能是它的 field editor（NSTextView，delegate 指回字段）。
        let responder = panel()?.firstResponder
        check("historyCtl: 搜索框成为第一响应者",
              responder === searchField()
              || (responder as? NSTextView)?.delegate === searchField())

        // 搜索过滤（输入即刷）：命中 1 条 / 无匹配 / 空白恢复
        typeSearch("Beta 草稿")
        check("historyCtl: 搜索命中 1 条",
              listRows().count == 1 && countLabel()?.stringValue == "1 条 · 本窗")
        typeSearch("绝不存在的内容")
        check("historyCtl: 搜索无匹配文案", listRows().isEmpty && countLabel()?.stringValue == "无匹配")
        typeSearch("   ")
        check("historyCtl: 空白搜索恢复全量", listRows().count == 2)

        // 范围切换（分段控件 action 走 @objc 私有实现）
        switchScope(toAll: true)
        check("historyCtl: 切「全部」范围 3 条",
              listRows().count == 3 && countLabel()?.stringValue == "3 条 · 全部")
        switchScope(toAll: false)
        check("historyCtl: 切回「本窗」2 条", listRows().count == 2)

        // 展开全文 → 再点收起
        listRows().first?.onToggleExpand?()
        let expandedRows = listRows()
        check("historyCtl: 首条展开全文",
              expandedRows.count == 2
              && expandedRows.contains { $0.isExpanded && $0.frame.height == 286 })
        expandedRows.first(where: { $0.isExpanded })?.onToggleExpand?()
        check("historyCtl: 再点收起", !listRows().contains { $0.isExpanded })

        // 复制全文 → 剪贴板 + toast
        NSPasteboard.general.clearContents()
        let copiedText = listRows().first?.entry.text
        listRows().first?.onCopy?()
        check("historyCtl: 复制全文进剪贴板",
              NSPasteboard.general.string(forType: .string) == copiedText)
        check("historyCtl: 复制反馈 toast", toastLabel()?.stringValue == "已复制全文 ✓")

        // 删除单条 → 存储减少 + toast
        let doomedText = listRows().first?.entry.text
        listRows().first?.onDelete?()
        check("historyCtl: ✕ 删除单条且不复活",
              store.entries().contains { $0.text == doomedText } == false
              && toastLabel()?.stringValue == "已删除 1 条 ✓")

        // 填回气泡 → handler 收到文本并关面板
        let fillText = listRows().first?.entry.text
        listRows().first?.onFill?()
        pump(0.1)
        check("historyCtl: 填充回气泡并关闭面板",
              filled == [fillText ?? ""] && !controller.isVisible)

        // 搜索框回车：空结果消费不关面板；有结果填充首条并关闭
        controller.toggle(
            anchorFrame: CGRect(x: 200, y: 400, width: 500, height: 180),
            currentWindowID: 5_150,
            fill: { filled.append($0) })
        pump(0.4)
        if let field = searchField() {
            typeSearch("zzz-无匹配")
            _ = controller.control(field, textView: NSTextView(),
                                   doCommandBy: #selector(NSResponder.insertNewline(_:)))
            check("historyCtl: 空结果回车消费且不关面板", controller.isVisible)
            typeSearch("")
            let before = filled.count
            _ = controller.control(field, textView: NSTextView(),
                                   doCommandBy: #selector(NSResponder.insertNewline(_:)))
            pump(0.1)
            check("historyCtl: 有结果回车填充首条并关闭",
                  filled.count == before + 1 && !controller.isVisible)
        } else {
            check("historyCtl: 搜索框可定位", false)
        }

        // 清空两段确认：首点武装（3s 自动还原）、第二点执行「只清当前过滤」
        controller.toggle(
            anchorFrame: CGRect(x: 200, y: 400, width: 500, height: 180),
            currentWindowID: 5_150,
            fill: { filled.append($0) })
        pump(0.4)
        let entriesBeforeClear = store.entries().count
        miniButton("清空")?.onClick?()
        check("historyCtl: 清空首点武装改标题", miniButton("确认清空") != nil)
        pump(3.2)
        check("historyCtl: 3s 未跟第二点自动还原", miniButton("清空") != nil)
        miniButton("清空")?.onClick?()
        miniButton("确认清空")?.onClick?()
        check("historyCtl: 第二点执行清空本窗过滤结果",
              store.entries().count < entriesBeforeClear
              && store.entries().contains { $0.windowID == 6_161 }
              && (toastLabel()?.stringValue?.hasPrefix("已清空") ?? false))
        // 空结果再清 → 提示无可清空
        miniButton("清空")?.onClick?()
        miniButton("确认清空")?.onClick?()
        check("historyCtl: 无记录时清空给出提示",
              toastLabel()?.stringValue == "没有可清空的记录")

        // 全部范围清空 → 存储清空
        switchScope(toAll: true)
        miniButton("清空")?.onClick?()
        miniButton("确认清空")?.onClick?()
        check("historyCtl: 全部范围清空后存储为空", store.entries().isEmpty)

        // 关闭钮 + toggle 开合
        miniButton("✕")?.onClick?()
        pump(0.1)
        check("historyCtl: 关闭钮收面板", !controller.isVisible)
        controller.toggle(anchorFrame: .zero, currentWindowID: nil, fill: { _ in })
        pump(0.3)
        check("historyCtl: 重开（nil 窗）空集文案",
              controller.isVisible && countLabel()?.stringValue == "暂无记录")
        controller.toggle(anchorFrame: .zero, currentWindowID: nil, fill: { _ in })
        pump(0.1)
        check("historyCtl: 可见时 toggle 收面板", !controller.isVisible)
    }
}
