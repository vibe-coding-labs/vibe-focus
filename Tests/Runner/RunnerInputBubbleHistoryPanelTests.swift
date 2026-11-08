import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerInputBubbleHistoryPanelTests.swift — B318 历史面板视图族直测
// 靶：InputBubbleHistoryPanel.swift 32.77%（437 行未覆盖）中可脱离面板控制器构造的
// 视图族——HistoryRowView / HistoryStatusBadge / HistoryMiniButton 的构建、layout
// 几何、hitTest 分流、draw 双外观、纯函数（height/timeText）。
// 留白：InputBubbleHistoryPanelController 编排（open/refresh/monitor 族）硬绑
// InputBubbleHistoryStore.shared 且开真实 NSPanel——归真机/E2E；mouseUp 点击语义
// 依赖 view 所在 window 坐标转换（无窗 convert(from:nil) 不可靠）不做合成断言。

extension RunnerHarness {

    private func makeHistoryEntry(
        text: String = "hello 世界",
        at: Date = Date(timeIntervalSince1970: 1_762_600_000),
        windowID: UInt32? = 321,
        title: String? = "iTerm2 — zsh",
        status: InputBubbleHistoryStatus = .submitted
    ) -> InputBubbleHistoryEntry {
        InputBubbleHistoryEntry(text: text, at: at, windowID: windowID, windowTitle: title, status: status)
    }

    func runInputBubbleHistoryPanelViewTests() {
        // ===== A. 纯函数 =====
        check("histRow: height 折叠=56 / 展开=286",
              HistoryRowView.height(isExpanded: false) == 56
                  && HistoryRowView.height(isExpanded: true) == 286)

        let now = Date(timeIntervalSince1970: 1_762_652_400)  // 固定基准
        let sameDay = now.addingTimeInterval(-3600)
        let otherDay = now.addingTimeInterval(-48 * 3600)
        let sameDayText = HistoryRowView.timeText(for: sameDay, now: now)
        let otherDayText = HistoryRowView.timeText(for: otherDay, now: now)
        check("histRow: 同日 HH:mm（5 字符无日期段）",
              sameDayText.count == 5 && !sameDayText.contains("-"))
        check("histRow: 跨日 MM-dd HH:mm（11 字符含日期段）",
              otherDayText.count == 11 && otherDayText.contains("-"))

        // ===== B. 折叠行构建 =====
        let collapsed = HistoryRowView(entry: makeHistoryEntry(), isExpanded: false, width: 300)
        check("histRow: 折叠行 frame 高=56 子视图含徽章/时间/标题/预览/三钮",
              collapsed.frame.height == 56 && collapsed.subviews.count == 7)
        check("histRow: 折叠行无展开滚动区",
              !collapsed.subviews.contains(where: { $0 is NSScrollView }))
        let multiline = HistoryRowView(entry: makeHistoryEntry(text: "a\nb\nc"), isExpanded: false, width: 300)
        let multilinePreview = multiline.subviews.compactMap { $0 as? NSTextField }.first {
            $0.stringValue == "a b c"
        }
        check("histRow: 预览换行折叠为空格", multilinePreview != nil)

        // 窗标题缺失回退「未知窗口」
        let noTitle = HistoryRowView(entry: makeHistoryEntry(title: nil), isExpanded: false, width: 300)
        let titleLabel = noTitle.subviews.compactMap { $0 as? NSTextField }.first {
            $0.stringValue == "未知窗口"
        }
        check("histRow: 无窗标题回退「未知窗口」", titleLabel != nil)

        // ===== C. 展开行构建 =====
        let expanded = HistoryRowView(entry: makeHistoryEntry(text: "line1\nline2"), isExpanded: true, width: 300)
        let scroll = expanded.subviews.compactMap { $0 as? NSScrollView }.first
        let doc = scroll?.documentView as? NSTextView
        check("histRow: 展开行 frame 高=286 带滚动区且全文=entry 文本",
              expanded.frame.height == 286 && doc?.string == "line1\nline2")

        // ===== D. layout 几何：徽章宽度随状态、删除钮贴右缘 =====
        func badgeWidth(status: InputBubbleHistoryStatus) -> CGFloat {
            let row = HistoryRowView(entry: makeHistoryEntry(status: status), isExpanded: false, width: 300)
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
            container.addSubview(row)
            row.layout()
            return row.subviews.first(where: { $0 is HistoryStatusBadge })?.frame.width ?? -1
        }
        check("histRow: layout 徽章宽 draft=34 / submitted=46",
              badgeWidth(status: .draft) == 34 && badgeWidth(status: .submitted) == 46)

        do {
            let row = HistoryRowView(entry: makeHistoryEntry(), isExpanded: false, width: 300)
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
            container.addSubview(row)
            row.layout()
            // init 添加序 badge/time/title/preview/copy/fill/delete——subviews.last=删除钮
            // layout：delete.x = w-26 = 274，宽 16 → maxX = 290
            let deleteMaxX = row.subviews.last?.frame.maxX ?? -1
            check("histRow: 删除钮贴右缘（maxX=290）", deleteMaxX == 290)
        }

        // ===== E. hitTest 分流（嵌入容器后按全局点换算） =====
        do {
            let row = HistoryRowView(entry: makeHistoryEntry(), isExpanded: false, width: 300)
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
            container.addSubview(row)
            row.layout()
            // 行内空白区（左下）→ 整行接管
            let body = row.hitTest(NSPoint(x: 20, y: 10))
            check("histRow: hitTest 行体→自身", body === row)
            // 容器外 → nil
            let outside = row.hitTest(NSPoint(x: -50, y: 10))
            check("histRow: hitTest 界外→nil", outside == nil)
        }

        // ===== F. draw 双外观 + 鼠标按下（无 crash 契约，离屏执行方法体） =====
        do {
            let row = HistoryRowView(entry: makeHistoryEntry(), isExpanded: true, width: 300)
            row.draw(NSRect(x: 0, y: 0, width: 300, height: 286))
            let dummy = NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0)
            if let dummy { row.mouseDown(with: dummy) }
            check("histRow: 展开行 draw+mouseDown 离屏执行零崩溃", true)
        }

        // ===== G. 徽章双状态 draw =====
        let badgeDraft = HistoryStatusBadge(status: .draft)
        badgeDraft.frame = NSRect(x: 0, y: 0, width: 34, height: 14)
        badgeDraft.draw(.infinite)
        let badgeSubmitted = HistoryStatusBadge(status: .submitted)
        badgeSubmitted.frame = NSRect(x: 0, y: 0, width: 46, height: 14)
        badgeSubmitted.draw(.infinite)
        check("histBadge: 双状态 draw 离屏零崩溃", true)

        // ===== H. 迷你钮构建+按下态 draw =====
        let mini = HistoryMiniButton(title: "复制", width: 32)
        check("histMini: 构建 frame 32×16", mini.frame.width == 32 && mini.frame.height == 16)
        mini.draw(.infinite)
        if let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0) {
            mini.mouseDown(with: down)
        }
        mini.draw(.infinite)
        check("histMini: 常态/按下态 draw 离屏零崩溃", true)
    }
}
