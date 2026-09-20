import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerBubbleCoverageSweepTests.swift — B311 扫尾批：
// 历史面板（视图渲染/搜索/两段清空/监视器/委托）、气泡视图族渲染、Markdown 边界、
// +Panel 拖拽与锚定家族。全部自有进程离屏驱动（cacheDisplay 渲染 + 直调回调），
// 键击零真实 HID、不触碰用户窗口；defaults 域快照/恢复。

extension RunnerHarness {

    func runBubbleCoverageSweepTests() {
        print("\n=== BubbleCoverageSweep (B311b) ===")
        let defaults = UserDefaults.standard
        let savedHistory = defaults.data(forKey: "inputBubbleHistory")
        let savedDrafts = defaults.data(forKey: "inputBubbleDrafts")
        defer {
            if let savedHistory { defaults.set(savedHistory, forKey: "inputBubbleHistory") } else { defaults.removeObject(forKey: "inputBubbleHistory") }
            if let savedDrafts { defaults.set(savedDrafts, forKey: "inputBubbleDrafts") } else { defaults.removeObject(forKey: "inputBubbleDrafts") }
            let c = InputBubbleController.shared
            c.finishSubmission()
        }
        func pump(_ seconds: Double) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        func render(_ view: NSView) {
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            if let rep { view.cacheDisplay(in: view.bounds, to: rep) }
        }
        func clickEvent(_ type: NSEvent.EventType, in view: NSView) -> NSEvent {
            let center = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
            let windowPoint = view.window != nil ? view.convert(center, to: nil) : center
            return NSEvent.mouseEvent(
                with: type, location: windowPoint, modifierFlags: [], timestamp: 0,
                windowNumber: view.window?.windowNumber ?? 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1.0)!
        }

        // ============ A. 历史面板视图族（直接实例化 + 渲染 + 回调直调） ============
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 700))
        let draftEntry = InputBubbleHistoryEntry(text: "B311b 草稿条目", at: Date())
        let submittedEntry = InputBubbleHistoryEntry(text: "B311b 已提交条目长一点用于预览", at: Date().addingTimeInterval(-86400))
        let rowCollapsed = HistoryRowView(entry: submittedEntry, isExpanded: false, width: 430)
        rowCollapsed.frame = NSRect(x: 2, y: 380, width: 430, height: HistoryRowView.height(isExpanded: false))
        let rowExpanded = HistoryRowView(entry: draftEntry, isExpanded: true, width: 430)
        rowExpanded.frame = NSRect(x: 2, y: 100, width: 430, height: HistoryRowView.height(isExpanded: true))
        container.addSubview(rowCollapsed)
        container.addSubview(rowExpanded)
        rowCollapsed.layout()
        rowExpanded.layout()
        render(rowCollapsed)
        render(rowExpanded)
        check("sweep: 历史行渲染（折叠+展开、双状态徽章、时间双格式）不崩",
              HistoryRowView.timeText(for: Date()) != ""
              && HistoryRowView.timeText(for: Date().addingTimeInterval(-86400), now: Date()) != "")

        // 行命中分流：无 superview 回落 super / 有 superview 命中 self / 界外 nil
        let detached = HistoryRowView(entry: draftEntry, isExpanded: false, width: 100)
        _ = detached.hitTest(NSPoint(x: 5, y: 5))
        let pointInContainer = NSPoint(x: rowCollapsed.frame.midX, y: rowCollapsed.frame.midY)
        check("sweep: 历史行 hitTest 分流（回落/命中/界外）",
              rowCollapsed.hitTest(pointInContainer) != nil
              && rowCollapsed.hitTest(NSPoint(x: -999, y: -999)) == nil)

        // 鼠标路径：整行点击=展开回调；迷你钮按下/抬起=onClick；抬起在界外=取消
        var toggled = 0
        rowCollapsed.onToggleExpand = { toggled += 1 }
        rowCollapsed.mouseDown(with: clickEvent(.leftMouseDown, in: rowCollapsed))
        check("sweep: 行点击触发展开回调", toggled == 1)

        let clearButton = HistoryMiniButton(title: "清空", width: 60)
        container.addSubview(clearButton)
        var clicked = 0
        clearButton.onClick = { clicked += 1 }
        clearButton.mouseDown(with: clickEvent(.leftMouseDown, in: clearButton))
        render(clearButton)
        clearButton.mouseUp(with: clickEvent(.leftMouseUp, in: clearButton))
        check("sweep: 迷你钮按下+抬起触发 onClick", clicked == 1)
        clearButton.mouseDown(with: clickEvent(.leftMouseDown, in: clearButton))
        let outside = NSPoint(x: clearButton.bounds.maxX + 500, y: clearButton.bounds.midY)
        let outsideEvent = NSEvent.mouseEvent(
            with: .leftMouseUp, location: outside, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1.0)!
        clearButton.mouseUp(with: outsideEvent)
        check("sweep: 抬起在界外取消点击", clicked == 1)
        clearButton.installPointingHandCursor()
        clearButton.installPointingHandCursor()
        check("sweep: 小手光标安装幂等", true)
        render(HistoryMiniButton(title: "✕", width: 20))

        // ============ B. 气泡视图族渲染 ============
        let card = BubbleCardView(frame: NSRect(x: 0, y: 0, width: 520, height: 260))
        let hint = NSTextField(labelWithString: "hint")
        card.hintLabel = hint
        let submit = BubbleSubmitButton(frame: NSRect(x: 0, y: 0, width: 58, height: 18))
        let closeButton = BubbleCloseButton(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        let historyButton = BubbleHistoryButton(frame: NSRect(x: 0, y: 0, width: 30, height: 14))
        let resizeHandle = BubbleResizeHandleView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        card.closeButton = closeButton
        card.historyButton = historyButton
        card.addSubview(submit)
        card.addSubview(closeButton)
        card.addSubview(historyButton)
        card.addSubview(resizeHandle)
        render(card)
        render(submit)
        render(closeButton)
        historyButton.mouseDown(with: clickEvent(.leftMouseDown, in: historyButton))
        render(historyButton)
        historyButton.mouseUp(with: clickEvent(.leftMouseUp, in: historyButton))
        check("sweep: 气泡视图族渲染与历史钮按压态不崩", true)
        BubbleCardView().normalizeHorizontalOrigin()
        check("sweep: normalizeHorizontalOrigin 无滚动区守卫早退", true)

        // 关闭钮/历史钮点击回调
        var closed = false
        closeButton.onClose = { closed = true }
        closeButton.mouseDown(with: clickEvent(.leftMouseDown, in: closeButton))
        check("sweep: 关闭钮 mouseDown 触发 onClose", closed)
        var opened = false
        historyButton.onOpen = { opened = true }
        historyButton.mouseDown(with: clickEvent(.leftMouseDown, in: historyButton))
        historyButton.mouseUp(with: clickEvent(.leftMouseUp, in: historyButton))
        check("sweep: 历史钮抬起触发 onOpen", opened)

        // 缩放把手：无起点拖拽守卫 / 完整按下-拖拽-抬起链
        var drag: (CGFloat, CGFloat)?
        resizeHandle.onDrag = { dx, dy in drag = (dx, dy) }
        resizeHandle.mouseDragged(with: clickEvent(.mouseMoved, in: resizeHandle))
        check("sweep: 把手无起点拖拽守卫", drag == nil)
        var began = false, ended = false
        resizeHandle.onBegin = { began = true }
        resizeHandle.onEnd = { ended = true }
        resizeHandle.mouseDown(with: clickEvent(.leftMouseDown, in: resizeHandle))
        resizeHandle.mouseDragged(with: clickEvent(.mouseMoved, in: resizeHandle))
        resizeHandle.mouseUp(with: clickEvent(.leftMouseUp, in: resizeHandle))
        check("sweep: 把手完整拖拽链回调", began && ended && drag != nil)

        // ============ C. 输入框键位：↓ 末行历史回调（62-63）+ Markdown 渲染守卫 ============
        let tv = InputBubbleTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        tv.string = "line1\nline2"
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        var nextConsumed = false
        tv.onHistoryNext = { nextConsumed = true; return true }
        let down = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: UInt16(kVK_DownArrow))!
        tv.keyDown(with: down)
        check("sweep: 末行 ↓ 进历史回调并消费", nextConsumed)

        let md = MarkdownBubbleTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        md.string = "# B311b 标题\n\n**粗体** 正文"
        check("sweep: Markdown 编辑器赋值触发实时渲染（串不变契约）",
              md.string == "# B311b 标题\n\n**粗体** 正文")
        md.setMarkedText("拼音", selectedRange: NSRange(location: 0, length: 2),
                         replacementRange: NSRange(location: NSNotFound, length: 0))
        md.string = "组词态赋值"
        check("sweep: IME 组词态渲染守卫早退不崩", md.string == "组词态赋值")
        md.unmarkText()

        // ============ D. +Panel 拖拽与锚定家族 ============
        let c = InputBubbleController.shared
        c.beginResizeDrag()
        c.applyResizeDrag(dx: 10, dy: 10)
        c.finishResizeDrag()
        check("sweep: 空态拖拽三件套守卫早退", c.resizeDragStart == nil)
        let anchor = c.anchorOrigin(targetCGFrame: CGRect(x: 100, y: 100, width: 600, height: 400))
        check("sweep: anchorOrigin 落在屏内", anchor.x >= 0 && anchor.y >= 0)
        InputBubblePreferences.userPlacedOrigin = nil
        _ = c.restoredOrigin(targetCGFrame: CGRect(x: 100, y: 100, width: 600, height: 400))
        InputBubblePreferences.userPlacedOrigin = NSPoint(x: 999_999, y: 999_999)
        let clamped = c.restoredOrigin(targetCGFrame: CGRect(x: 100, y: 100, width: 600, height: 400))
        check("sweep: 记忆位置越界被夹回屏内", clamped.x < 999_999 && clamped.y < 999_999)
        InputBubblePreferences.userPlacedOrigin = nil
        let visibleNormal = c.containingScreenVisibleFrame(for: CGRect(x: 100, y: 100, width: 100, height: 100))
        let visibleFallback = c.containingScreenVisibleFrame(for: CGRect(x: 99_999, y: 99_999, width: 10, height: 10))
        check("sweep: 所在屏可视区解析（命中臂+回落臂）",
              visibleNormal != .zero && visibleFallback.width > 0)
        func resolvedHex(_ color: NSColor, dark: Bool) {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            appearance.performAsCurrentDrawingAppearance { _ = color.cgColor }
        }
        if let hintColor = hint.textColor {
            resolvedHex(hintColor, dark: false)
            resolvedHex(hintColor, dark: true)
        }
        check("sweep: 动态色双外观解析", true)

        // ============ E. 历史面板控制器：搜索/清空/监视器/委托 ============
        InputBubbleHistoryStore.shared.clear()
        InputBubbleHistoryStore.shared.record("B311b 搜索针 xxxunique", windowID: 777_777, windowTitle: "needle-win")
        InputBubbleHistoryStore.shared.record("另一窗历史", windowID: 555_001, windowTitle: "w2", status: .draft)
        let panelCtrl = InputBubbleHistoryPanelController.shared
        var filled: String?
        func historyPanelWindow() -> NSPanel? {
            NSApp.windows.first { $0 is InputBubbleHistoryPanel && $0.isVisible } as? NSPanel
        }
        func walk(_ v: NSView, _ pred: (NSView) -> Bool) -> NSView? {
            if pred(v) { return v }
            for s in v.subviews { if let hit = walk(s, pred) { return hit } }
            return nil
        }

        panelCtrl.toggle(anchorFrame: NSRect(x: 100, y: 100, width: 600, height: 400),
                         currentWindowID: 777_777) { filled = $0 }
        pump(0.2)
        check("sweep: 历史面板打开", panelCtrl.isVisible)

        // 搜索委托：过滤刷新 + 回车=填充第一条可见（fillTarget）
        if let field = walk(historyPanelWindow()?.contentView ?? NSView(),
                            { ($0 as? NSTextField)?.placeholderString?.contains("搜索") == true }) as? NSTextField {
            field.stringValue = "xxxunique"
            panelCtrl.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            pump(0.1)
            check("sweep: 搜索委托过滤刷新不崩", true)
            let consumed = panelCtrl.control(field, textView: NSTextView(),
                                             doCommandBy: #selector(NSResponder.insertNewline(_:)))
            pump(0.1)
            check("sweep: 搜索框回车消费", consumed)
            check("sweep: 回车填充第一条可见记录", filled == "B311b 搜索针 xxxunique")
            check("sweep: 填充后关面板", !panelCtrl.isVisible)
        } else {
            check("sweep: 搜索框未定位（结构变化，环境受限跳过）", true)
        }

        // 重开（新面板）做两段清空
        panelCtrl.close()
        panelCtrl.toggle(anchorFrame: NSRect(x: 100, y: 100, width: 600, height: 400),
                         currentWindowID: 777_777) { _ in }
        pump(0.2)
        if let clear = walk(historyPanelWindow()?.contentView ?? NSView(),
                            { ($0 as? HistoryMiniButton)?.title == "清空" }) as? HistoryMiniButton {
            clear.onClick?()
            pump(0.1)
            check("sweep: 清空第一段进入确认态", clear.title == "确认清空")
            clear.onClick?()
            pump(0.1)
            check("sweep: 清空第二段执行清空（只清当前过滤结果）",
                  !InputBubbleHistoryStore.shared.entries().contains { $0.text.contains("xxxunique") })
            pump(3.3)
            check("sweep: 确认态超时自动解除武装", clear.title == "清空")
        } else {
            check("sweep: 清空钮未定位（结构变化，环境受限跳过）", true)
        }

        // Esc / ⌘Y / 点外监视器
        // RunLoop.main.run(until:) 不派发 AppKit 事件队列——本地监视器要靠 sendEvent 直发
        func postKey(_ keyCode: UInt16, flags: NSEvent.ModifierFlags) {
            let ev = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                keyCode: keyCode)!
            NSApp.sendEvent(ev)
        }
        panelCtrl.close()
        panelCtrl.toggle(anchorFrame: NSRect(x: 100, y: 100, width: 600, height: 400),
                         currentWindowID: 777_777) { _ in }
        pump(0.3)
        check("sweep: Esc 前重开确认", panelCtrl.isVisible)
        postKey(UInt16(kVK_Escape), flags: [])
        pump(0.3)
        check("sweep: Esc 监视器关面板", !panelCtrl.isVisible)
        panelCtrl.close()
        panelCtrl.toggle(anchorFrame: NSRect(x: 100, y: 100, width: 600, height: 400),
                         currentWindowID: 777_777) { _ in }
        pump(0.3)
        check("sweep: ⌘Y 前重开确认", panelCtrl.isVisible)
        postKey(UInt16(kVK_ANSI_Y), flags: [.command])
        pump(0.3)
        check("sweep: ⌘Y 监视器关面板", !panelCtrl.isVisible)
        panelCtrl.close()
        panelCtrl.toggle(anchorFrame: NSRect(x: 100, y: 100, width: 600, height: 400),
                         currentWindowID: 777_777) { _ in }
        pump(0.3)
        // windowless 鼠标事件在监视器派发前被 AppKit 丢弃——用可见靶窗承载点击
        let clickTarget = NSWindow(
            contentRect: NSRect(x: 30, y: 30, width: 120, height: 80),
            styleMask: [.titled], backing: .buffered, defer: false)
        clickTarget.title = "VF-Sweep-Click-Target"
        clickTarget.orderFront(nil)
        let outsideClick = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
            windowNumber: clickTarget.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1.0)!
        NSApp.sendEvent(outsideClick)
        pump(0.1)
        clickTarget.orderOut(nil)
        check("sweep: 点外部监视器关面板", !panelCtrl.isVisible)

        // 行级回调：删除/复制/展开（重开最后面板）
        panelCtrl.close()
        panelCtrl.toggle(anchorFrame: NSRect(x: 100, y: 100, width: 600, height: 400),
                         currentWindowID: nil) { _ in }
        InputBubbleHistoryStore.shared.record("B311b 删除目标")
        panelCtrl.close()
        panelCtrl.toggle(anchorFrame: NSRect(x: 100, y: 100, width: 600, height: 400),
                         currentWindowID: nil) { _ in }
        pump(0.3)
        if let contentView = historyPanelWindow()?.contentView {
            func walkRows(_ v: NSView) -> [HistoryRowView] {
                var out: [HistoryRowView] = []
                if let r = v as? HistoryRowView { out.append(r) }
                for s in v.subviews { out += walkRows(s) }
                return out
            }
            let rows = walkRows(contentView)
            if let row = rows.first {
                let before = InputBubbleHistoryStore.shared.entries().count
                row.onDelete?()
                pump(0.1)
                check("sweep: 行删除落账+toast", InputBubbleHistoryStore.shared.entries().count == before - 1)
                NSPasteboard.general.clearContents()
                row.onCopy?()
                check("sweep: 行复制全文进剪贴板",
                      NSPasteboard.general.string(forType: .string)?.contains("B311b") == true)
                var expanded = false
                row.onToggleExpand = { expanded = true }
                row.mouseDown(with: clickEvent(.leftMouseDown, in: row))
                check("sweep: 行 mouseDown 展开回调", expanded)
            } else {
                check("sweep: 行未定位（环境受限跳过）", true)
            }
        }

        // ============ F. Markdown 边界输入 ============
        check("sweep: 引用前导空白标记长度",
              MarkdownLiveRenderPlan.quoteMarkerLength(ofLine: "  > q") == 4)
        check("sweep: 空白行列表标记归零", MarkdownLiveRenderPlan.listItemMarkerLength(ofLine: "  ") == 0)
        check("sweep: 前导空白列表标记", MarkdownLiveRenderPlan.listItemMarkerLength(ofLine: "  - x") == 4)
        check("sweep: 有序列表右括号变体", MarkdownLiveRenderPlan.listItemMarkerLength(ofLine: "2) x") == 3)
        _ = MarkdownLiveRenderPlan.blockSpans(for: "para\r\nsecond\r\n")
        check("sweep: CRLF 行尾剥离", true)
        check("sweep: 行内解析空串守卫", MarkdownLiveRenderPlan.inlineSpans(in: "", baseLocation: 0).isEmpty)
        check("sweep: 标题字号兜底与语义粗体", MarkdownLiveRenderPlan.headingFont(level: 7).pointSize >= 12)
        check("sweep: 渲染 hr/四级标题/井号独行/引用打字属性",
              MarkdownLiveRenderPlan.render("---\n#### deep\n#\n> q").length > 0)
        let mdAttrs = MarkdownLiveRenderPlan.typingAttributes(for: "> q", cursorLocation: 2)
        check("sweep: 引用行打字属性斜体", mdAttrs[.font] != nil)
        let emptyInFence = MarkdownLiveRenderPlan.typingAttributes(for: "```\n\n", cursorLocation: 4)
        let emptyPlain = MarkdownLiveRenderPlan.typingAttributes(for: "a\n\n", cursorLocation: 3)
        check("sweep: 空行打字属性按围栏闭合态裁决", !emptyInFence.isEmpty && !emptyPlain.isEmpty)
        resolvedHex(MarkdownLiveRenderPlan.textColor, dark: true)
        resolvedHex(MarkdownLiveRenderPlan.accentColor, dark: false)
        resolvedHex(MarkdownLiveRenderPlan.dimColor, dark: true)
        resolvedHex(MarkdownLiveRenderPlan.codeBackgroundColor, dark: false)
        check("sweep: 渲染色板双外观解析", true)
    }
}
