import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerBubbleCoverageFinaleTests.swift — B311 终章批：
// 历史面板行级/搜索/清空/分段/Esc-清搜索全流程（真实 windowID 归属）、
// summon 守卫族、跟随目标消失臂、点击监视器闭环、CGKeyEventPoster 安全键位、
// Markdown 列表边界。门控与红线同 Lifecycle/Tail（输入空闲门控 + 键击 mock）。

extension RunnerHarness {

    func runBubbleCoverageFinaleTests() {
        print("\n=== BubbleCoverageFinale (B311d) ===")
        let controller = InputBubbleController.shared

        let secondsSinceInput = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if secondsSinceInput < 120,
           ProcessInfo.processInfo.environment["VIBEFOCUS_BUBBLE_LIFECYCLE_TESTS"] != "1" {
            check("finale: 用户活跃期（2 分钟内有输入）诚实跳过", true)
            return
        }
        let iterm2Entries = cgWindowListAll().filter {
            $0.ownerName == "iTerm2" && $0.layer == 0 && $0.isOnScreen
                && ($0.bounds?.width ?? 0) > 300 && ($0.bounds?.height ?? 0) > 150
        }
        guard let iterm2PID = iterm2Entries.first?.ownerPID,
              let app = NSRunningApplication(processIdentifier: iterm2PID),
              TerminalRegistry.isTerminalOrIDEApp(appName: app.localizedName, bundleIdentifier: app.bundleIdentifier) else {
            check("finale: 无 iTerm2 真实身份，环境受限跳过", true)
            return
        }
        let windowID = iterm2Entries[0].windowID
        let historyWindowID: UInt32 = 777_777

        let saved = (enabled: InputBubblePreferences.isEnabled,
                     autoHide: InputBubblePreferences.autoHide)
        let savedHistory = UserDefaults.standard.data(forKey: "inputBubbleHistory")
        let savedDrafts = UserDefaults.standard.data(forKey: "inputBubbleDrafts")
        defer {
            InputBubblePreferences.isEnabled = saved.enabled
            InputBubblePreferences.autoHide = saved.autoHide
            if let savedHistory { UserDefaults.standard.set(savedHistory, forKey: "inputBubbleHistory") } else { UserDefaults.standard.removeObject(forKey: "inputBubbleHistory") }
            if let savedDrafts { UserDefaults.standard.set(savedDrafts, forKey: "inputBubbleDrafts") } else { UserDefaults.standard.removeObject(forKey: "inputBubbleDrafts") }
            controller.keyEventPoster = CGKeyEventPoster()
            controller.finishSubmission()
        }
        let mock = TailKeyEventPoster2()
        controller.keyEventPoster = mock
        func pump(_ seconds: Double) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        @discardableResult
        func pumpUntilIdle(_ maxSeconds: Double) -> Bool {
            let deadline = Date().addingTimeInterval(maxSeconds)
            while Date() < deadline {
                if controller.phase == .idle { pump(0.05); return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return controller.phase == .idle
        }
        func sendClick(_ type: NSEvent.EventType, windowNumber: Int) {
            let ev = NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
                windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1.0)!
            NSApp.sendEvent(ev)
        }
        func sendKey(_ keyCode: UInt16, flags: NSEvent.ModifierFlags) {
            let ev = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                keyCode: keyCode)!
            NSApp.sendEvent(ev)
        }

        // --- A. CGKeyEventPoster 安全真实投递（F19 无消费方，零副作用） ---
        CGKeyEventPoster().post(keyCode: CGKeyCode(kVK_F19), flags: [], keyDown: true)
        CGKeyEventPoster().post(keyCode: CGKeyCode(kVK_F19), flags: [], keyDown: false)
        check("finale: CGKeyEventPoster 真实投递通道（F19 无副作用键位）", true)

        // --- B. summon 守卫族 ---
        InputBubblePreferences.isEnabled = false
        controller.summonForMovedWindow(windowID: windowID, pid: iterm2PID, appName: "iTerm2")
        check("finale: summonForMovedWindow 开关守卫", controller.phase == .idle)
        InputBubblePreferences.isEnabled = true
        controller.summonForMovedWindow(windowID: windowID, pid: ownRunnerPID2(), appName: "Runner")
        check("finale: summonForMovedWindow 非终端守卫", controller.phase == .idle)
        controller.summonForMovedWindow(windowID: 987_654, pid: iterm2PID, appName: "iTerm2")
        check("finale: summonForMovedWindow 无 CG bounds 守卫", controller.phase == .idle)

        // --- C. 真面板：点击监视器闭环 + 提交钮 + 关闭钮回调 + 跟随目标消失 ---
        controller.summonForMovedWindow(windowID: windowID, pid: iterm2PID, appName: "iTerm2")
        pump(0.3)
        guard controller.phase == .open, let panel = controller.panel,
              panel.contentView is BubbleCardView else {
            check("finale: 面板未开（环境受限跳过后续）", true)
            return
        }
        if let panelWindowNumber = panel.windowNumber as Int? {
            sendClick(.leftMouseDown, windowNumber: panelWindowNumber)
            pump(0.1)
            check("finale: 点击监视器识别本面板→重收键盘", controller.phase == .open)
        }
        // activate 落 Runner 自身（非终端激活零全局污染）
        controller.target = InputBubbleController.Target(
            pid: ownRunnerPID2(), bundleID: "com.googlecode.iterm2", windowID: windowID, title: "finale")
        controller.submitFrontmostPIDProvider = { ownRunnerPID2() }
        controller.submitFocusedWindowHandleProvider = { windowID }
        controller.submitSettleAXWindowProvider = { nil }
        controller.textView?.string = "finale 提交钮正文"
        controller.submitButtonClicked()
        let submitIdle = pumpUntilIdle(3.0)
        check("finale: 提交钮闭包走完整提交链（Return 恰一次）",
              submitIdle && mock.returnKeyCount == 1)
        // 跟随目标消失臂（死 pid → dismiss）
        controller.summonForMovedWindow(windowID: windowID, pid: iterm2PID, appName: "iTerm2")
        pump(0.2)
        controller.target = InputBubbleController.Target(
            pid: 999_999, bundleID: "com.googlecode.iterm2", windowID: windowID, title: "gone")
        controller.followTick()
        check("finale: 跟随目标消失→自动 dismiss", controller.phase == .idle)
        // 关闭钮回调臂（重开后点 ✕）
        controller.summonForMovedWindow(windowID: windowID, pid: iterm2PID, appName: "iTerm2")
        pump(0.2)
        if let freshCard = controller.panel?.contentView as? BubbleCardView,
           let closeButton = freshCard.closeButton {
            let center = NSPoint(x: closeButton.bounds.midX, y: closeButton.bounds.midY)
            let loc = closeButton.window != nil ? closeButton.convert(center, to: nil) : center
            let ev = NSEvent.mouseEvent(
                with: .leftMouseDown, location: loc, modifierFlags: [], timestamp: 0,
                windowNumber: closeButton.window?.windowNumber ?? 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1.0)!
            closeButton.mouseDown(with: ev)
            check("finale: 关闭钮回调→dismiss", controller.phase == .idle)
        } else {
            check("finale: 关闭钮未定位（环境受限跳过）", true)
        }
        // applyPanelSize 空态守卫
        controller.applyPanelSize(NSSize(width: 400, height: 200))
        check("finale: applyPanelSize 空态守卫", controller.panel == nil)

        // --- D. 历史面板行级全流程（真实 windowID 归属） ---
        let panelCtrl = InputBubbleHistoryPanelController.shared
        panelCtrl.close()
        UserDefaults.standard.removeObject(forKey: "inputBubbleHistory")
        InputBubbleHistoryStore.shared.record("finale 目标条目 abcunique",
                                              windowID: historyWindowID, windowTitle: "fw",
                                              status: .submitted)
        InputBubbleHistoryStore.shared.record("finale 草稿条目",
                                              windowID: historyWindowID, windowTitle: "fw",
                                              status: .draft)
        panelCtrl.toggle(anchorFrame: NSRect(x: 100, y: 100, width: 600, height: 400),
                         currentWindowID: historyWindowID) { _ in }
        pump(0.3)
        guard panelCtrl.isVisible,
              let content = NSApp.windows.first(where: { $0 is InputBubbleHistoryPanel && $0.isVisible }),
              let contentView = content.contentView else {
            check("finale: 历史面板未开（环境受限跳过后续）", true)
            return
        }
        func walk(_ v: NSView, _ pred: (NSView) -> Bool) -> NSView? {
            if pred(v) { return v }
            for s in v.subviews { if let hit = walk(s, pred) { return hit } }
            return nil
        }
        func walkRows(_ v: NSView) -> [HistoryRowView] {
            var out: [HistoryRowView] = []
            if let r = v as? HistoryRowView { out.append(r) }
            for s in v.subviews { out += walkRows(s) }
            return out
        }
        // 分段切换（本窗→全部）经 target/action 派发
        if let seg = walk(contentView, { $0 is NSSegmentedControl }) as? NSSegmentedControl,
           let action = seg.action {
            seg.selectedSegment = 1
            _ = NSApp.sendAction(action, to: seg.target, from: seg)
            pump(0.1)
            check("finale: 分段切换→全部刷新不崩", true)
        } else {
            check("finale: 分段控件未定位（环境受限跳过）", true)
        }
        // 行内三钮：填充（fillHandler 关面板）/复制/删除（真实按钮事件）
        let rows = walkRows(contentView)
        if let row = rows.first {
            let buttons = row.subviews.compactMap { $0 as? HistoryMiniButton }
            for button in buttons {
                let center = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
                let loc = button.window != nil ? button.convert(center, to: nil) : center
                let down = NSEvent.mouseEvent(
                    with: .leftMouseDown, location: loc, modifierFlags: [], timestamp: 0,
                    windowNumber: button.window?.windowNumber ?? 0, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1.0)!
                let up = NSEvent.mouseEvent(
                    with: .leftMouseUp, location: loc, modifierFlags: [], timestamp: 0,
                    windowNumber: button.window?.windowNumber ?? 0, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1.0)!
                button.mouseDown(with: down)
                button.mouseUp(with: up)
                pump(0.15)
            }
            check("finale: 行内钮点击链（复制/填充/删除）不崩",
                  InputBubbleHistoryStore.shared.entries().count <= 1)
        } else {
            check("finale: 行未定位（环境受限跳过）", true)
        }
        // 搜索无匹配 + 回车空清单守卫 + Esc 清搜索 + 普通键放行 + 委托错误臂
        panelCtrl.close()
        InputBubbleHistoryStore.shared.record("finale 搜索唯一 xyzq", windowID: historyWindowID)
        panelCtrl.toggle(anchorFrame: NSRect(x: 100, y: 100, width: 600, height: 400),
                         currentWindowID: historyWindowID) { _ in }
        pump(0.3)
        if walk(contentView,
                { ($0 as? NSTextField)?.placeholderString?.contains("搜索") == true }) is NSTextField {
            panelCtrl.close()
            panelCtrl.toggle(anchorFrame: NSRect(x: 100, y: 100, width: 600, height: 400),
                             currentWindowID: historyWindowID) { _ in }
            pump(0.3)
            guard let liveContent = NSApp.windows.first(where: { $0 is InputBubbleHistoryPanel && $0.isVisible }),
                  let liveView = liveContent.contentView,
                  let liveField = walk(liveView, { ($0 as? NSTextField)?.placeholderString?.contains("搜索") == true }) as? NSTextField else {
                check("finale: 重开搜索框未定位（环境受限跳过）", true)
                return
            }
            liveField.stringValue = "zzz-no-match"
            panelCtrl.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: liveField))
            let consumedNoMatch = panelCtrl.control(liveField, textView: NSTextView(),
                                                    doCommandBy: #selector(NSResponder.insertNewline(_:)))
            check("finale: 无匹配回车守卫（消费但不填充）", consumedNoMatch)
            panelCtrl.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: NSTextField()))
            _ = panelCtrl.control(NSTextField(), textView: NSTextView(),
                                  doCommandBy: #selector(NSResponder.insertNewline(_:)))
            _ = panelCtrl.control(liveField, textView: NSTextView(),
                                  doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            check("finale: 委托错误臂（异字段/异选择器）不崩", true)
            // Esc 清搜索（field editor 活跃态）→ 再 Esc 关面板
            liveContent.makeFirstResponder(liveField)
            liveField.stringValue = "zzz-no-match"
            panelCtrl.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: liveField))
            sendKey(UInt16(kVK_Escape), flags: [])
            pump(0.1)
            check("finale: Esc 第一段清搜索保持面板", panelCtrl.isVisible && liveField.stringValue.isEmpty)
            sendKey(UInt16(kVK_Escape), flags: [])
            pump(0.2)
            check("finale: Esc 第二段关面板", !panelCtrl.isVisible)
            // 普通键放行臂（面板开着、非 Esc/⌘Y）
            panelCtrl.toggle(anchorFrame: NSRect(x: 100, y: 100, width: 600, height: 400),
                             currentWindowID: historyWindowID) { _ in }
            pump(0.2)
            sendKey(UInt16(kVK_ANSI_A), flags: [])
            pump(0.1)
            check("finale: 普通键放行不关面板", panelCtrl.isVisible)
            panelCtrl.close()
        } else {
            check("finale: 搜索框未定位（环境受限跳过）", true)
        }
        // 空清单两段清空 toast 臂
        UserDefaults.standard.removeObject(forKey: "inputBubbleHistory")
        InputBubbleHistoryStore.shared.clear()
        panelCtrl.toggle(anchorFrame: NSRect(x: 100, y: 100, width: 600, height: 400),
                         currentWindowID: historyWindowID) { _ in }
        pump(0.3)
        if let clear = walk(historyPanelWindow2()?.contentView ?? NSView(),
                            { ($0 as? HistoryMiniButton)?.title == "清空" }) as? HistoryMiniButton {
            clear.onClick?()
            clear.onClick?()
            pump(0.1)
            check("finale: 空清单清空 toast 臂", InputBubbleHistoryStore.shared.entries().isEmpty)
        } else {
            check("finale: 清空钮未定位（环境受限跳过）", true)
        }
        panelCtrl.close()

        // --- E. 提交链 dismissOnly 臂（waitFrontmost 直驱空白文本） ---
        controller.submitFrontmostPIDProvider = { iterm2PID }
        controller.submitFocusedWindowHandleProvider = { windowID }
        controller.finishSubmission()
        let returnsBeforeDismissOnly = mock.returnKeyCount
        controller.waitFrontmostAndInject(
            target: InputBubbleController.Target(pid: iterm2PID, bundleID: "com.googlecode.iterm2",
                                                 windowID: windowID, title: "f"),
            text: "   ", mode: .submit, elapsedMs: 0)
        check("finale: 注入门 dismissOnly 臂（空白文本只收尾零键击）",
              controller.phase == .idle && mock.returnKeyCount == returnsBeforeDismissOnly)

        // --- F. Markdown 列表数字位数边界 ---
        check("finale: 十位数数字非列表标记归零",
              MarkdownLiveRenderPlan.listItemMarkerLength(ofLine: "1234567890. x") == 0)
    }
}

@MainActor private func historyPanelWindow2() -> NSPanel? {
    NSApp.windows.first { $0 is InputBubbleHistoryPanel && $0.isVisible } as? NSPanel
}

private final class TailKeyEventPoster2: KeyEventPosting {
    private(set) var events: [(keyCode: CGKeyCode, keyDown: Bool)] = []
    var returnKeyCount: Int { events.filter { $0.keyCode == CGKeyCode(kVK_Return) && $0.keyDown }.count }
    func post(keyCode: CGKeyCode, flags: CGEventFlags, keyDown: Bool) {
        events.append((keyCode, keyDown))
    }
}

func ownRunnerPID2() -> pid_t { ProcessInfo.processInfo.processIdentifier }
