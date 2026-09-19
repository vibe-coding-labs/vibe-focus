import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerBubbleHistoryPanelViewTests.swift — 覆盖率批次 4（B228）：
// 输入气泡历史面板视图族直测（HistoryStatusBadge / HistoryMiniButton / HistoryRowView）。
//
// NSView 子类在 CLI 进程可安全构造与驱动：draw 直调时 NSGraphicsContext 为 nil，
// 贝塞尔路径填充静默无效但不崩；mouseDown/mouseUp/cursorUpdate 用合成 NSEvent 驱动；
// layout() 直调验证 frame 计算契约。历史面板控制器（真实 NSPanel orderFront 弹窗）
// 依赖窗口服务器，诚实留白。timeText/height 是纯函数（now 可注入）。

extension RunnerHarness {
    func runBubbleHistoryPanelViewTests() {
        // MARK: A. 静态布局契约
        check("historyRow: height 折叠/展开契约",
              HistoryRowView.height(isExpanded: false) == 56
              && HistoryRowView.height(isExpanded: true) == 286)

        // timeText：同日只显示 HH:mm，跨日带 MM-dd 前缀（now 注入）。
        var comps = DateComponents(); comps.year = 2026; comps.month = 9; comps.day = 18
        comps.hour = 8; comps.minute = 5
        let date = Calendar.current.date(from: comps)!
        var nowComps = DateComponents(); nowComps.year = 2026; nowComps.month = 9; nowComps.day = 19
        nowComps.hour = 22; nowComps.minute = 0
        let nextDay = Calendar.current.date(from: nowComps)!
        check("historyRow: timeText 跨日显示 MM-dd HH:mm",
              HistoryRowView.timeText(for: date, now: nextDay) == "09-18 08:05")
        var sameDayComps = nowComps; sameDayComps.hour = 8; sameDayComps.minute = 5
        let sameDay = Calendar.current.date(from: sameDayComps)!
        check("historyRow: timeText 同日只显示 HH:mm",
              HistoryRowView.timeText(for: sameDay, now: nextDay) == "08:05")

        // MARK: B. HistoryStatusBadge：双状态构造与 draw 直调（无图形上下文安全）
        for status in [InputBubbleHistoryStatus.draft, .submitted] {
            let badge = HistoryStatusBadge(status: status)
            badge.frame = NSRect(x: 0, y: 0, width: 40, height: 14)
            badge.draw(NSRect(x: 0, y: 0, width: 40, height: 14))
        }

        // MARK: C. HistoryMiniButton：点击状态机与回调送达
        var clickCount = 0
        let button = HistoryMiniButton(title: "复制", width: 32)
        button.onClick = { clickCount += 1 }
        check("historyButton: mouseDownCanMoveWindow 恒 false",
              button.mouseDownCanMoveWindow == false)
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 5, y: 5), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: 5, y: 5), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
        button.mouseDown(with: down)
        button.cursorUpdate(with: down)
        button.draw(button.bounds)
        button.mouseUp(with: up)
        check("historyButton: 按下-抬起在界内触发 onClick 恰一次",
              clickCount == 1)
        // 抬起在界外：不触发（B203 两段确认的边界语义）。
        let upOutside = NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: 500, y: 500), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        button.mouseDown(with: down)
        button.mouseUp(with: upOutside)
        check("historyButton: 按下-界外抬起不触发 onClick",
              clickCount == 1)
        // 独立 mouseUp（无按下态）：不触发。
        button.mouseUp(with: up)
        check("historyButton: 无按下态的抬起不触发 onClick",
              clickCount == 1)

        // MARK: D. HistoryRowView：构造双态、layout 契约、命中分流
        let draftEntry = InputBubbleHistoryEntry(
            text: "第一行\n第二行", at: date, windowID: 42,
            windowTitle: "终端窗", status: .draft)
        let submittedEntry = InputBubbleHistoryEntry(
            text: "已提交文本", at: date, windowID: nil, windowTitle: nil, status: .submitted)

        let collapsed = HistoryRowView(entry: draftEntry, isExpanded: false, width: 320)
        check("historyRow: 折叠态高度与子视图数（badge+时间+窗名+预览+三钮）",
              collapsed.frame.height == 56 && collapsed.subviews.count == 7)
        let expanded = HistoryRowView(entry: submittedEntry, isExpanded: true, width: 320)
        check("historyRow: 展开态高度与子视图数（多一个全文 NSScrollView）",
              expanded.frame.height == 286 && expanded.subviews.count == 8)

        // layout：draft 徽章 34 宽 / submitted 46 宽双分支。
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        container.addSubview(collapsed)
        collapsed.frame = NSRect(x: 0, y: 0, width: 320, height: 56)
        collapsed.layout()
        let collapsedBadge = collapsed.subviews.compactMap { $0 as? HistoryStatusBadge }.first
        check("historyRow: draft 徽章 layout 后 34 宽",
              collapsedBadge?.frame.width == 34)

        let container2 = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        container2.addSubview(expanded)
        expanded.frame = NSRect(x: 0, y: 0, width: 320, height: 286)
        expanded.layout()
        let expandedBadge = expanded.subviews.compactMap { $0 as? HistoryStatusBadge }.first
        check("historyRow: submitted 徽章 layout 后 46 宽",
              expandedBadge?.frame.width == 46)

        // hitTest 分流：按钮命中→返回按钮；界外→nil；其余空白→整行自身。
        let copyButton = collapsed.subviews.compactMap {
            $0 as? HistoryMiniButton
        }.first { $0.title == "复制" }
        if let copyButton {
            let centerInRow = NSPoint(x: copyButton.frame.midX, y: copyButton.frame.midY)
            check("historyRow: hitTest 点中复制钮返回按钮自身",
                  collapsed.hitTest(centerInRow) === copyButton)
        }
        check("historyRow: hitTest 界外点返回 nil",
              collapsed.hitTest(NSPoint(x: -80, y: -80)) == nil)
        check("historyRow: hitTest 空白区返回整行",
              collapsed.hitTest(NSPoint(x: 160, y: 10)) === collapsed)

        // mouseDown → onToggleExpand 回调送达。
        var toggles = 0
        collapsed.onToggleExpand = { toggles += 1 }
        collapsed.mouseDown(with: down)
        check("historyRow: mouseDown 触发展开回调", toggles == 1)

        // 回调插槽：onCopy/onFill/onDelete 由 MiniButton onClick 桥接。
        var copyHits = 0
        collapsed.onCopy = { copyHits += 1 }
        if let copyButton {
            copyButton.onClick?()
        }
        check("historyRow: onCopy 桥接送达", copyHits == 1)

        // E. 面板控制器 close：无面板时幂等（不开真实弹窗——窗口服务器依赖留白）。
        let controller = InputBubbleHistoryPanelController()
        controller.close()
        check("historyPanel: close 无面板时幂等不崩", true)
    }
}
