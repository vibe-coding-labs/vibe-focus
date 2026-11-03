import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerBubbleHistoryPanelTests.swift — 覆盖率批次（2026-11-03）：
// 输入历史面板（B196/B203）——徽章/迷你钮/行视图/内容底的真实绘制与命中分流，
// 以及控制器 open→搜索→范围切换→展开→复制→删除→填充→清空两段确认→关闭全链。
//
// 安全红线：
// - 控制器链路会真开一块我方 NSPanel（并短暂 activate），用户活跃期（2 分钟内有
//   真实输入）诚实跳过；VIBEFOCUS_BUBBLE_LIFECYCLE_TESTS=1 可显式放行；
// - 离屏窗口（不 orderFront）承载纯视图件，零屏幕可见、零用户窗触碰；
// - defaults 域（inputBubbleHistory）先快照后恢复；激活策略原样还原。

private func historyPanelHostWindow(_ view: NSView, size: NSSize) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view
    return window
}

private func historyPanelMouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent? {
    NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
}

extension RunnerHarness {

    func runBubbleHistoryPanelTests() {
        print("\n=== BubbleHistoryPanel ===")

        // ---------- 一、纯视图件（离屏渲染，恒跑） ----------

        // 行高契约
        check("history: collapsed/expanded 行高",
              HistoryRowView.height(isExpanded: false) == 56
              && HistoryRowView.height(isExpanded: true) == 286)

        // 时间文案：今天 HH:mm / 跨天 MM-dd HH:mm
        let now = Date()
        let todayText = HistoryRowView.timeText(for: now, now: now)
        check("history: 今天时间戳为 HH:mm", todayText.count == 5 && todayText.contains(":"))
        let oldText = HistoryRowView.timeText(for: now.addingTimeInterval(-86400 * 40), now: now)
        check("history: 跨天时间戳为 MM-dd HH:mm", oldText.count == 11 && oldText.contains(" "))

        // 状态徽章两态绘制（草稿/已提交）
        for status in [InputBubbleHistoryStatus.draft, .submitted] {
            let badge = HistoryStatusBadge(status: status)
            let window = historyPanelHostWindow(badge, size: NSSize(width: 46, height: 14))
            badge.frame = NSRect(x: 0, y: 0, width: 46, height: 14)
            badge.layoutSubtreeIfNeeded()
            let rendered = badge.bitmapImageRepForCachingDisplay(in: badge.bounds)
            if let rendered {
                badge.cacheDisplay(in: badge.bounds, to: rendered)
            }
            check("history: \(status.rawValue) 徽章离屏绘制", rendered != nil && window.contentView === badge)
        }

        // 迷你钮：hover 光标 / 按下重绘 / 命中才触发 onClick / 移出取消
        var clickCount = 0
        let button = HistoryMiniButton(title: "复制", width: 32)
        button.onClick = { clickCount += 1 }
        let buttonWindow = historyPanelHostWindow(button, size: NSSize(width: 32, height: 16))
        button.frame = NSRect(x: 0, y: 0, width: 32, height: 16)
        if let down = historyPanelMouseEvent(.leftMouseDown, at: NSPoint(x: 16, y: 8)) {
            button.mouseDown(with: down)
            button.cursorUpdate(with: down)
            let pressedRep = button.bitmapImageRepForCachingDisplay(in: button.bounds)
            if let pressedRep { button.cacheDisplay(in: button.bounds, to: pressedRep) }
            check("history: 迷你钮按下态离屏绘制", pressedRep != nil)
            button.mouseUp(with: down)
            check("history: 迷你钮按下抬起触发 onClick", clickCount == 1)
        } else {
            check("history: 迷你钮按下抬起触发 onClick（事件构造失败，环境受限跳过）", true)
        }
        check("history: 迷你钮不随窗口拖动", button.mouseDownCanMoveWindow == false)
        if let outside = historyPanelMouseEvent(.leftMouseDown, at: NSPoint(x: 200, y: 200)) {
            button.mouseDown(with: outside)
            button.mouseUp(with: outside)
            check("history: 迷你钮移出抬起不触发 onClick", clickCount == 1)
        }
        check("history: 迷你钮宿主窗就位", buttonWindow.contentView === button)

        // 行视图：折叠/展开两态 layout + 命中分流 + 整行点击 + 离屏绘制
        let draftEntry = InputBubbleHistoryEntry(
            text: "第一行草稿\n第二行草稿", at: now,
            windowID: 5_150, windowTitle: "iTerm2 Alpha", status: .draft)
        for expanded in [false, true] {
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: HistoryRowView.height(isExpanded: expanded)))
            let row = HistoryRowView(entry: draftEntry, isExpanded: expanded, width: 440)
            row.frame = container.bounds
            container.addSubview(row)
            let window = historyPanelHostWindow(container, size: container.bounds.size)
            container.layoutSubtreeIfNeeded()
            row.layout()

            var toggled = false
            row.onToggleExpand = { toggled = true }
            if let down = historyPanelMouseEvent(.leftMouseDown, at: NSPoint(x: 220, y: 20)) {
                row.mouseDown(with: down)
            }
            check("history: \(expanded ? "展开" : "折叠")行整行点击走展开回调", toggled)

            let copyButton = row.subviews.compactMap { $0 as? HistoryMiniButton }.first { $0.title == "复制" }
            if let copyButton {
                let hit = row.hitTest(NSPoint(x: copyButton.frame.midX, y: copyButton.frame.midY))
                check("history: \(expanded ? "展开" : "折叠")行命中分流通向复制钮", hit === copyButton)
            } else {
                check("history: 行内复制钮存在", false)
            }
            let rowHit = row.hitTest(NSPoint(x: 20, y: 10))
            check("history: \(expanded ? "展开" : "折叠")行空白区命中行自身", rowHit === row)
            check("history: 行外坐标命中为空", row.hitTest(NSPoint(x: 20, y: 400)) == nil)

            let rowRep = row.bitmapImageRepForCachingDisplay(in: row.bounds)
            if let rowRep { row.cacheDisplay(in: row.bounds, to: rowRep) }
            check("history: \(expanded ? "展开" : "折叠")行离屏绘制", rowRep != nil)

            if expanded {
                let scroll = row.subviews.compactMap { $0 as? NSScrollView }.first
                check("history: 展开行内嵌全文滚动区", scroll != nil)
                if let scroll {
                    let hit = row.hitTest(NSPoint(x: scroll.frame.minX + 4, y: scroll.frame.minY + 4))
                    check("history: 展开行全文区命中滚动态", hit === scroll)
                }
            }
            _ = window
        }

        // 内容底视图绘制
        let contentBG = HistoryPanelContentView(frame: NSRect(x: 0, y: 0, width: 460, height: 520))
        let bgWindow = historyPanelHostWindow(contentBG, size: NSSize(width: 460, height: 520))
        contentBG.layoutSubtreeIfNeeded()
        let bgRep = contentBG.bitmapImageRepForCachingDisplay(in: contentBG.bounds)
        if let bgRep { contentBG.cacheDisplay(in: contentBG.bounds, to: bgRep) }
        check("history: 内容底离屏绘制且圆角层就位", bgRep != nil && bgWindow.contentView === contentBG)

        // 面板可成为 key（搜索框打字前提）
        let barePanel = InputBubbleHistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        check("history: 历史面板可成为 key", barePanel.canBecomeKey)

        // 定位纯函数三档：右贴 / 左贴 / 夹进可视区
        let vf = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let panelSize = NSSize(width: 460, height: 520)
        let right = InputBubbleHistoryPanelController.panelOrigin(
            anchorFrame: CGRect(x: 100, y: 300, width: 500, height: 200),
            panelSize: panelSize, visibleFrame: vf)
        check("history: 定位右贴气泡", right.x == 608)
        let left = InputBubbleHistoryPanelController.panelOrigin(
            anchorFrame: CGRect(x: 1200, y: 300, width: 200, height: 200),
            panelSize: panelSize, visibleFrame: vf)
        check("history: 定位右侧放不下改左贴", left.x == 1200 - 8 - 460)
        let clamped = InputBubbleHistoryPanelController.panelOrigin(
            anchorFrame: CGRect(x: 20, y: 880, width: 40, height: 40),
            panelSize: panelSize, visibleFrame: vf)
        check("history: 定位 Y 轴夹进可视区", clamped.y == 900 - 520 - 8)

        // ---------- 二、控制器全链（真面板；用户活跃期跳过） ----------

        let secondsSinceInput = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if secondsSinceInput < 120,
           ProcessInfo.processInfo.environment["VIBEFOCUS_BUBBLE_LIFECYCLE_TESTS"] != "1" {
            check("history: 用户活跃期诚实跳过真面板链路", true)
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
        func listRows() -> [HistoryRowView] {
            guard let scroll = contentOfPanel()?.subviews.compactMap({ $0 as? NSScrollView }).first,
                  let document = scroll.documentView else { return [] }
            return document.subviews.compactMap { $0 as? HistoryRowView }
        }
        // 直接走 NSTextFieldDelegate 回调（生产里由字段编辑器触发同一方法；手动
        // 投 Notification 不会经过 NSControl 的委托分发）。
        func typeSearch(_ text: String) {
            guard let field = searchField() else { return }
            field.stringValue = text
            controller.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: field))
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

        check("history: 打开面板并落位", controller.isVisible && panel() != nil)
        check("history: 默认本窗过滤出 2 条", listRows().count == 2)
        check("history: 计数标签显示本窗条数", countLabel()?.stringValue == "2 条 · 本窗")
        // makeFirstResponder(field) 会装字段编辑器：firstResponder 可能是字段本身，
        // 也可能是它的 field editor（NSTextView，delegate 指回字段）。
        let responder = panel()?.firstResponder
        check("history: 搜索框成为第一响应者",
              responder === searchField()
              || (responder as? NSTextView)?.delegate === searchField())

        // 搜索过滤（输入即刷）：命中 1 条 / 无匹配 / 清空恢复
        typeSearch("Beta 草稿")
        check("history: 搜索命中 1 条", listRows().count == 1 && countLabel()?.stringValue == "1 条 · 本窗")
        typeSearch("绝不存在的内容")
        check("history: 搜索无匹配文案", listRows().isEmpty && countLabel()?.stringValue == "无匹配")
        typeSearch("   ")
        check("history: 空白搜索恢复全量", listRows().count == 2)

        // 范围切换（分段控件 action 走 @objc 私有实现）
        if let segmented = contentOfPanel()?.subviews.compactMap({ $0 as? NSSegmentedControl }).first,
           let target = segmented.target as? NSObject, let action = segmented.action {
            segmented.selectedSegment = 1
            _ = target.perform(action, with: segmented)
            check("history: 切「全部」范围 3 条", listRows().count == 3
                  && countLabel()?.stringValue == "3 条 · 全部")
            segmented.selectedSegment = 0
            _ = target.perform(action, with: segmented)
            check("history: 切回「本窗」2 条", listRows().count == 2)
        } else {
            check("history: 分段控件可定位", false)
        }

        // 展开全文 → 再点收起
        if let firstRow = listRows().first {
            firstRow.onToggleExpand?()
            let expandedRows = listRows()
            check("history: 首条展开全文",
                  expandedRows.count == 2
                  && expandedRows.contains { $0.isExpanded && $0.frame.height == 286 })
            expandedRows.first(where: { $0.isExpanded })?.onToggleExpand?()
            check("history: 再点收起", !listRows().contains { $0.isExpanded })
        }

        // 复制全文 → 剪贴板 + toast
        NSPasteboard.general.clearContents()
        listRows().first?.onCopy?()
        check("history: 复制全文进剪贴板",
              NSPasteboard.general.string(forType: .string) == listRows().first?.entry.text)
        check("history: 复制反馈 toast", toastLabel()?.stringValue == "已复制全文 ✓")

        // 删除单条 → 存储减少 + toast
        let doomedText = listRows().first?.entry.text
        listRows().first?.onDelete?()
        check("history: ✕ 删除单条且不复活",
              store.entries().contains { $0.text == doomedText } == false
              && toastLabel()?.stringValue == "已删除 1 条 ✓")

        // 填回气泡 → handler 收到文本并关面板
        let fillText = listRows().first?.entry.text
        listRows().first?.onFill?()
        pump(0.1)
        check("history: 填充回气泡并关闭面板",
              filled == [fillText ?? ""] && !controller.isVisible)

        // Esc/⌘Y 之外的键盘闭环：搜索框回车填充第一条可见记录
        controller.toggle(
            anchorFrame: CGRect(x: 200, y: 400, width: 500, height: 180),
            currentWindowID: 5_150,
            fill: { filled.append($0) })
        pump(0.4)
        if let field = searchField() {
            typeSearch("zzz-无匹配")
            _ = controller.control(field, textView: NSTextView(),
                                   doCommandBy: #selector(NSResponder.insertNewline(_:)))
            check("history: 空结果回车消费且不关面板", controller.isVisible)
            typeSearch("")
            let before = filled.count
            _ = controller.control(field, textView: NSTextView(),
                                   doCommandBy: #selector(NSResponder.insertNewline(_:)))
            pump(0.1)
            check("history: 有结果回车填充首条并关闭",
                  filled.count == before + 1 && !controller.isVisible)
        } else {
            check("history: 搜索框可定位", false)
        }

        // 清空两段确认：首点武装（3s 自动还原）、第二点执行「只清当前过滤」
        controller.toggle(
            anchorFrame: CGRect(x: 200, y: 400, width: 500, height: 180),
            currentWindowID: 5_150,
            fill: { filled.append($0) })
        pump(0.4)
        let entriesBeforeClear = store.entries().count
        miniButton("清空")?.onClick?()
        check("history: 清空首点武装改标题", miniButton("确认清空") != nil)
        pump(3.2)
        check("history: 3s 未跟第二点自动还原", miniButton("清空") != nil)
        miniButton("清空")?.onClick?()
        miniButton("确认清空")?.onClick?()
        check("history: 第二点执行清空本窗过滤结果",
              store.entries().count < entriesBeforeClear
              && store.entries().contains { $0.windowID == 6_161 }
              && (toastLabel()?.stringValue?.hasPrefix("已清空") ?? false))
        // 空结果再清 → 提示无可清空
        miniButton("清空")?.onClick?()
        miniButton("确认清空")?.onClick?()
        check("history: 无记录时清空给出提示",
              toastLabel()?.stringValue == "没有可清空的记录")

        // 过滤全部范围后清空，legacy 条目一并删除 + 再开再关闭环
        if let segmented = contentOfPanel()?.subviews.compactMap({ $0 as? NSSegmentedControl }).first,
           let target = segmented.target as? NSObject, let action = segmented.action {
            segmented.selectedSegment = 1
            _ = target.perform(action, with: segmented)
        }
        miniButton("清空")?.onClick?()
        miniButton("确认清空")?.onClick?()
        check("history: 全部范围清空后存储为空", store.entries().isEmpty)

        // 关闭钮 + toggle 开合
        miniButton("✕")?.onClick?()
        pump(0.1)
        check("history: 关闭钮收面板", !controller.isVisible)
        controller.toggle(anchorFrame: .zero, currentWindowID: nil, fill: { _ in })
        pump(0.3)
        check("history: 重开（nil 窗）空集文案",
              controller.isVisible && countLabel()?.stringValue == "暂无记录")
        controller.toggle(anchorFrame: .zero, currentWindowID: nil, fill: { _ in })
        pump(0.1)
        check("history: 可见时 toggle 收面板", !controller.isVisible)
    }
}
