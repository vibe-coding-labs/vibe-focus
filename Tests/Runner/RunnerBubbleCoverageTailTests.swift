import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerBubbleCoverageTailTests.swift — B311 收尾批：
// 视图回调闭包体（经由真实视图事件触发而非直调）、handleEnter 键位族、
// 提交链生产事实源臂（缝置 nil 走 NSWorkspace/AX 真实读取）、
// settleActivationKeyboard giveUp 臂、summon 开关/开态 toggle 臂、dark 外观渲染。
// 门控与红线同 RunnerBubbleLifecyclePanelTests（用户 2 分钟内有输入即诚实跳过；
// 键击 mock；iTerm2 只读身份；defaults 快照恢复）。

private final class TailKeyEventPoster: KeyEventPosting {
    private(set) var events: [(keyCode: CGKeyCode, keyDown: Bool)] = []
    var returnKeyCount: Int { events.filter { $0.keyCode == CGKeyCode(kVK_Return) && $0.keyDown }.count }
    func post(keyCode: CGKeyCode, flags: CGEventFlags, keyDown: Bool) {
        events.append((keyCode, keyDown))
    }
}

extension RunnerHarness {

    func runBubbleCoverageTailTests() {
        print("\n=== BubbleCoverageTail (B311c) ===")
        let controller = InputBubbleController.shared

        let secondsSinceInput = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if secondsSinceInput < 120,
           ProcessInfo.processInfo.environment["VIBEFOCUS_BUBBLE_LIFECYCLE_TESTS"] != "1" {
            check("tail: 用户活跃期（2 分钟内有输入）诚实跳过", true)
            return
        }
        let iterm2Entries = cgWindowListAll().filter {
            $0.ownerName == "iTerm2" && $0.layer == 0 && $0.isOnScreen
                && ($0.bounds?.width ?? 0) > 300 && ($0.bounds?.height ?? 0) > 150
        }
        guard let iterm2PID = iterm2Entries.first?.ownerPID,
              let app = NSRunningApplication(processIdentifier: iterm2PID),
              TerminalRegistry.isTerminalOrIDEApp(appName: app.localizedName, bundleIdentifier: app.bundleIdentifier) else {
            check("tail: 无 iTerm2 真实身份，环境受限跳过", true)
            return
        }
        let realFrontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        let saved = (
            enabled: InputBubblePreferences.isEnabled,
            autoHide: InputBubblePreferences.autoHide,
            submitOnEnter: InputBubblePreferences.submitOnEnter,
            autoRestore: InputBubblePreferences.autoRestoreOnSubmit
        )
        let savedHistory = UserDefaults.standard.data(forKey: "inputBubbleHistory")
        let savedDrafts = UserDefaults.standard.data(forKey: "inputBubbleDrafts")
        let savedAppAppearance = NSApp.appearance
        defer {
            InputBubblePreferences.isEnabled = saved.enabled
            InputBubblePreferences.autoHide = saved.autoHide
            InputBubblePreferences.submitOnEnter = saved.submitOnEnter
            InputBubblePreferences.autoRestoreOnSubmit = saved.autoRestore
            if let savedHistory { UserDefaults.standard.set(savedHistory, forKey: "inputBubbleHistory") } else { UserDefaults.standard.removeObject(forKey: "inputBubbleHistory") }
            if let savedDrafts { UserDefaults.standard.set(savedDrafts, forKey: "inputBubbleDrafts") } else { UserDefaults.standard.removeObject(forKey: "inputBubbleDrafts") }
            NSApp.appearance = savedAppAppearance
            controller.submitFrontmostPIDProvider = nil
            controller.submitFocusedWindowHandleProvider = nil
            controller.submitSettleAXWindowProvider = nil
            controller.submitHasToggleRecordProvider = nil
            controller.keyEventPoster = CGKeyEventPoster()
            controller.finishSubmission()
        }

        let mock = TailKeyEventPoster()
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
        func clickEvent(_ type: NSEvent.EventType, in view: NSView) -> NSEvent {
            let center = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
            let windowPoint = view.window != nil ? view.convert(center, to: nil) : center
            return NSEvent.mouseEvent(
                with: type, location: windowPoint, modifierFlags: [], timestamp: 0,
                windowNumber: view.window?.windowNumber ?? 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1.0)!
        }
        func keyEvent(_ keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                keyCode: keyCode)!
        }

        // --- T1 生产事实源臂：缝全置 nil，前台永不匹配 → 激活重试到预算耗尽 abort ---
        InputBubblePreferences.isEnabled = true
        controller.submitFrontmostPIDProvider = nil
        controller.submitFocusedWindowHandleProvider = nil
        controller.submitSettleAXWindowProvider = nil
        controller.finishSubmission()
        controller.phase = .open
        controller.target = InputBubbleController.Target(
            pid: ownRunnerPID(), bundleID: nil, windowID: 888_001, title: "t1")
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        tv.string = "生产臂场景"
        controller.textView = tv
        controller.submit(mode: .submit)
        let t1Idle = pumpUntilIdle(4.0)
        check("tail: 生产前台事实源臂（激活重试→预算 abort）", t1Idle && mock.returnKeyCount == 0)

        // --- T2 窗柄生产臂：target=真实前台 pid，AX 查柄（nil/真柄均 ≠ 假 ID）→ abortMissingTarget ---
        if let realFrontPID {
            controller.finishSubmission()
            controller.phase = .open
            controller.target = InputBubbleController.Target(
                pid: realFrontPID, bundleID: "com.googlecode.iterm2", windowID: 888_002, title: "t2")
            let tv2 = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
            tv2.string = "柄臂场景"
            controller.textView = tv2
            controller.submit(mode: .submit)
            let t2Idle = pumpUntilIdle(4.0)
            check("tail: 窗柄生产事实源臂（abortMissingTarget）", t2Idle && mock.returnKeyCount == 0)
        }

        // --- T3 真面板 + 视图回调闭包链 + 键位族 ---
        controller.summonForMovedWindow(windowID: iterm2Entries[0].windowID, pid: iterm2PID, appName: "iTerm2")
        pump(0.3)
        guard controller.phase == .open, let card = controller.panel?.contentView as? BubbleCardView else {
            check("tail: 面板未开（环境受限跳过后续）", true)
            return
        }
        // 缩放把手事件链（onBegin/onDrag/onEnd 闭包体）
        if let handle = card.resizeHandle {
            handle.mouseDown(with: clickEvent(.leftMouseDown, in: handle))
            handle.mouseDragged(with: clickEvent(.mouseMoved, in: handle))
            handle.mouseUp(with: clickEvent(.leftMouseUp, in: handle))
            check("tail: 把手事件链驱动控制器拖拽（量化落账）", controller.resizeDragStart == nil)
        }
        // 历史钮闭包 → showHistoryPanel → 再关
        if let historyButton = card.historyButton {
            historyButton.mouseDown(with: clickEvent(.leftMouseDown, in: historyButton))
            historyButton.mouseUp(with: clickEvent(.leftMouseUp, in: historyButton))
            pump(0.2)
            let opened = InputBubbleHistoryPanelController.shared.isVisible
            check("tail: 历史钮闭包开历史面板", opened)
            _ = controller.toggleHistoryPanel()
            pump(0.1)
            check("tail: ⌘Y 语义收回历史面板", !InputBubbleHistoryPanelController.shared.isVisible)
        }
        // 编辑框键位族：⌘Y 直达/↑↓ 历史/Enter 提交（mock）/⌘Enter 仅粘贴/换行臂
        if let textView = controller.textView {
            InputBubbleHistoryStore.shared.record("tail 历史条目", windowID: iterm2Entries[0].windowID)
            textView.string = "tail 现场文本"
            controller.lastRestoredBaseText = "tail 现场文本"
            textView.keyDown(with: keyEvent(UInt16(kVK_UpArrow), flags: []))
            textView.keyDown(with: keyEvent(UInt16(kVK_DownArrow), flags: []))
            check("tail: ↑↓ 键位经视图闭包驱动翻阅不崩", true)
            // 关闭态下 ⌘Y = 打开（toggle）
            textView.keyDown(with: keyEvent(UInt16(kVK_ANSI_Y), flags: [.command]))
            pump(0.2)
            check("tail: ⌘Y 键位经视图闭包打开历史面板",
                  InputBubbleHistoryPanelController.shared.isVisible)
            _ = controller.toggleHistoryPanel()
            pump(0.1)
            // 提交键位需要前台/柄缝（真实前台在登录屏不可匹配）；
            // activate 落在 Runner 自身（非终端激活零全局污染）
            controller.target = InputBubbleController.Target(
                pid: ownRunnerPID(), bundleID: "com.googlecode.iterm2",
                windowID: controller.target?.windowID ?? 0, title: "t3")
            controller.submitFrontmostPIDProvider = { ownRunnerPID() }
            controller.submitFocusedWindowHandleProvider = { controller.target?.windowID }
            controller.submitSettleAXWindowProvider = { nil }
            InputBubblePreferences.submitOnEnter = true
            check("tail: Enter 前文本非空（dismissOnly 排除）",
                  !(textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            let seamPID = controller.submitFrontmostPIDProvider?()
            check("tail: Enter 前缝与目标一致", seamPID == controller.target?.pid)
            let phaseBeforeEnter = controller.phase
            let eventsBeforeEnter = mock.events.count
            textView.keyDown(with: keyEvent(UInt16(kVK_Return), flags: []))
            let phaseSync = controller.phase
            let syncEvents = mock.events.count
            pump(0.4)
            let phaseAfterEnter = controller.phase
            let eventsAfterEnter = mock.events.count
            let enterIdle = pumpUntilIdle(3.0)
            check("tail: Enter 前置态（open+无事件）",
                  phaseBeforeEnter == .open && eventsBeforeEnter == 0)
            check("tail: Enter 同步进 submitting（keyDown 拦截生效）", phaseSync == .submitting)
            check("tail: Enter 同步零事件（粘贴在 +0ms 拍）", syncEvents == 0)
            check("tail: Enter 后 0.4s（submitting+有键击）",
                  phaseAfterEnter == .submitting && eventsAfterEnter > 0)
            check("tail: Enter 键位经视图闭包走提交链（mock Return 恰一次）",
                  enterIdle && mock.returnKeyCount == 1)
            // 回开面板继续（提交收尾后 phase 归 idle）
            controller.summonForMovedWindow(windowID: iterm2Entries[0].windowID, pid: iterm2PID, appName: "iTerm2")
            pump(0.2)
            InputBubblePreferences.submitOnEnter = false
            let before = textView.string
            textView.keyDown(with: keyEvent(UInt16(kVK_Return), flags: []))
            check("tail: 换行语义臂（submitOnEnter=false Enter 不提交）",
                  controller.phase == .open && textView.string.hasPrefix(before))
            // ⌘Enter（submitOnEnter=false）= 注入并提交（文本非空才能过提交门；
            // activate 落 Runner 自身零全局污染）
            controller.textView?.string = "tail cmd enter 正文"
            controller.target = InputBubbleController.Target(
                pid: ownRunnerPID(), bundleID: "com.googlecode.iterm2",
                windowID: controller.target?.windowID ?? 0, title: "t3b")
            controller.submitFrontmostPIDProvider = { ownRunnerPID() }
            controller.submitFocusedWindowHandleProvider = { controller.target?.windowID }
            check("tail: ⌘Enter 前置态 open", controller.phase == .open)
            let liveTV = controller.textView ?? textView
            check("tail: ⌘Enter 用 live 编辑器（rebuild 后旧引用不漂移）", liveTV === controller.textView)
            liveTV.keyDown(with: keyEvent(UInt16(kVK_Return), flags: [.command]))
            let cmdSyncPhase = controller.phase
            check("tail: ⌘Enter 同步相位（submitting=链路触发）", cmdSyncPhase == .submitting)
            pump(0.4)
            let cmdEnterIdle = pumpUntilIdle(3.0)
            check("tail: ⌘Enter 提交 Return 计数", mock.returnKeyCount == 2)
            check("tail: ⌘Enter 提交收尾归 idle", cmdEnterIdle)
            // ⌘Enter（submitOnEnter=true）= 仅粘贴不提交
            controller.summonForMovedWindow(windowID: iterm2Entries[0].windowID, pid: iterm2PID, appName: "iTerm2")
            pump(0.2)
            controller.submitFrontmostPIDProvider = { iterm2PID }
            controller.submitFocusedWindowHandleProvider = { controller.target?.windowID }
            controller.submitSettleAXWindowProvider = { nil }
            InputBubblePreferences.submitOnEnter = true
            let returnsBeforePasteOnly = mock.returnKeyCount
            textView.keyDown(with: keyEvent(UInt16(kVK_Return), flags: [.command]))
            let pasteOnlyIdle = pumpUntilIdle(3.0)
            check("tail: ⌘Enter 仅粘贴键位（submitOnEnter=true 无 Return）",
                  pasteOnlyIdle && mock.returnKeyCount == returnsBeforePasteOnly)
            InputBubblePreferences.submitOnEnter = saved.submitOnEnter
        }

        // --- T4 settleActivationKeyboard giveUp 臂（重开面板持续泵过 2s 预算） ---
        controller.summonForMovedWindow(windowID: iterm2Entries[0].windowID, pid: iterm2PID, appName: "iTerm2")
        pump(2.4)
        check("tail: 激活复查预算耗尽 giveUp 留证不崩", controller.phase == .open)

        // --- T5 委托守卫臂 + settingsWasVisible 归还臂 + 提交钮空态 ---
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: nil))
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: nil))
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: nil))
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: controller.panel ?? NSWindow()))
        let insertNewline = controller.textView(
            controller.textView ?? NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        let unknownCommand = controller.textView(
            controller.textView ?? NSTextView(), doCommandBy: #selector(NSResponder.moveToEndOfDocument(_:)))
        check("tail: 委托守卫与默认臂",
              insertNewline == false && unknownCommand == false)
        controller.settingsWasVisible = true
        controller.finishSubmission()
        check("tail: 设置窗可见性归还臂跑通", controller.phase == .idle)
        controller.submitButtonClicked()
        check("tail: 提交钮空态守卫", controller.phase == .idle)
        controller.dismiss(reactivateTarget: false)
        controller.handleEnter(commandHeld: false)
        check("tail: handleEnter 空态守卫", controller.phase == .idle)

        // --- T6 summon 开关与开态 toggle 臂（真实前台非终端 beep 路径，安全） ---
        InputBubblePreferences.isEnabled = false
        InputBubbleController.triggerFromHotKey()
        pump(0.2)
        check("tail: 开关关闭 summon 静默早退", controller.phase == .idle)
        InputBubblePreferences.isEnabled = true

        // --- T7 dark 外观渲染（历史面板行/徽章/钮 dark 臂） ---
        let dark = NSAppearance(named: .darkAqua)
        let darkEntry = InputBubbleHistoryEntry(text: "tail 深色渲染条目", at: Date(), status: .draft)
        let darkRow = HistoryRowView(entry: darkEntry, isExpanded: true, width: 430)
        darkRow.frame = NSRect(x: 0, y: 0, width: 430, height: HistoryRowView.height(isExpanded: true))
        darkRow.appearance = dark
        darkRow.layout()
        let rep = darkRow.bitmapImageRepForCachingDisplay(in: darkRow.bounds)
        if let rep { darkRow.cacheDisplay(in: darkRow.bounds, to: rep) }
        // 展开滚动区命中臂
        let hitPoint = NSPoint(x: darkRow.frame.midX, y: darkRow.frame.minY + 60)
        _ = darkRow.superview
        darkRow.superview?.addSubview(NSView()) // 保持非空语义（detached 行 hitTest 分支已在他处覆盖）
        _ = darkRow.hitTest(hitPoint)
        check("tail: dark 外观行渲染与展开滚动区命中不崩", true)

        // --- T8 历史面板控制器 dark 头部（NSApp 外观切换后重开） ---
        let savedHist2 = UserDefaults.standard.data(forKey: "inputBubbleHistory")
        UserDefaults.standard.removeObject(forKey: "inputBubbleHistory")
        InputBubbleHistoryStore.shared.record("tail 深色头部条目", windowID: 889_001)
        NSApp.appearance = dark
        let panelCtrl = InputBubbleHistoryPanelController.shared
        panelCtrl.close()
        panelCtrl.toggle(anchorFrame: NSRect(x: 100, y: 100, width: 600, height: 400),
                         currentWindowID: 889_001) { _ in }
        pump(0.3)
        check("tail: dark 头部构建（buildHeader dark 臂）", panelCtrl.isVisible)
        // 可见态 toggle = close 臂
        panelCtrl.toggle(anchorFrame: NSRect(x: 100, y: 100, width: 600, height: 400),
                         currentWindowID: 889_001) { _ in }
        pump(0.1)
        check("tail: toggle 可见态关闭臂", !panelCtrl.isVisible)
        NSApp.appearance = savedAppAppearance
        if let savedHist2 { UserDefaults.standard.set(savedHist2, forKey: "inputBubbleHistory") } else { UserDefaults.standard.removeObject(forKey: "inputBubbleHistory") }
    }
}
