import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerBubbleLifecyclePanelTests.swift — B311：气泡控制器生命周期编排直测
// （summonForMovedWindow→showPanel→builtPanel→跟随→历史→改绑→提交→dismiss 全链）
// 与 AutoShow tick 编排（B310 观察缝注入真实 iTerm2 身份）。
//
// 安全红线：
// - 全函数运行时门控：真实前台 app 处于 active 态（用户在用机）则诚实跳过——
//   场景里 submit 链会对 target（真实 iTerm2）发 activate，活跃期绝不执行；
// - 键击全程 mock poster（零真实 HID）；不触碰用户窗口（iTerm2 只读身份，
//   定向唤起只读其 CG 窗柄；面板是我方进程的 NSPanel）；
// - 偏好逐项快照/恢复，杜绝跨进程残留（B261 教训）。

private final class LifecycleKeyEventPoster: KeyEventPosting {
    private(set) var events: [(keyCode: CGKeyCode, keyDown: Bool)] = []
    var returnKeyCount: Int { events.filter { $0.keyCode == CGKeyCode(kVK_Return) && $0.keyDown }.count }
    func post(keyCode: CGKeyCode, flags: CGEventFlags, keyDown: Bool) {
        events.append((keyCode, keyDown))
    }
}

extension RunnerHarness {

    func runBubbleLifecyclePanelTests() {
        print("\n=== BubbleLifecyclePanel (B311) ===")
        let controller = InputBubbleController.shared

        // 运行时门控：本场景会对真实 iTerm2 发 activate 并弹出我方面板——
        // 用户在场（2 分钟内有真实输入事件）时诚实跳过；VIBEFOCUS_BUBBLE_LIFECYCLE_TESTS=1 可显式放行。
        let secondsSinceInput = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if secondsSinceInput < 120,
           ProcessInfo.processInfo.environment["VIBEFOCUS_BUBBLE_LIFECYCLE_TESTS"] != "1" {
            check("lifecycle: 用户活跃期（2 分钟内有输入）诚实跳过真面板场景", true)
            return
        }

        // 定位真实 iTerm2 身份（只读）：pid + 两个有真实尺寸的窗柄（排除无 bounds 的辅助条目）
        let iterm2Entries = cgWindowListAll().filter {
            $0.ownerName == "iTerm2" && $0.layer == 0 && $0.isOnScreen
                && ($0.bounds?.width ?? 0) > 300 && ($0.bounds?.height ?? 0) > 150
        }
        guard let iterm2PID = iterm2Entries.first?.ownerPID, iterm2Entries.count >= 1,
              let app = NSRunningApplication(processIdentifier: iterm2PID),
              TerminalRegistry.isTerminalOrIDEApp(appName: app.localizedName, bundleIdentifier: app.bundleIdentifier) else {
            check("lifecycle: 无 iTerm2 真实身份，环境受限跳过", true)
            return
        }
        let windowA = iterm2Entries[0].windowID
        let windowB = iterm2Entries.count > 1 ? iterm2Entries[1].windowID : windowA

        // 偏好逐项快照/恢复
        let saved = (
            enabled: InputBubblePreferences.isEnabled,
            autoHide: InputBubblePreferences.autoHide,
            editorKind: InputBubblePreferences.editorKind,
            width: InputBubblePreferences.bubbleWidth,
            height: InputBubblePreferences.bubbleHeight,
            autoRestore: InputBubblePreferences.autoRestoreOnSubmit
        )
        var savedUserPlacedOrigin = InputBubblePreferences.userPlacedOrigin
        defer {
            InputBubblePreferences.isEnabled = saved.enabled
            InputBubblePreferences.autoHide = saved.autoHide
            InputBubblePreferences.editorKind = saved.editorKind
            InputBubblePreferences.bubbleWidth = saved.width
            InputBubblePreferences.bubbleHeight = saved.height
            InputBubblePreferences.autoRestoreOnSubmit = saved.autoRestore
            InputBubblePreferences.userPlacedOrigin = savedUserPlacedOrigin
            controller.submitFrontmostPIDProvider = nil
            controller.submitFocusedWindowHandleProvider = nil
            controller.submitSettleAXWindowProvider = nil
            controller.submitHasToggleRecordProvider = nil
            InputBubbleAutoShow.shared.frontmostAppProvider = nil
            controller.keyEventPoster = CGKeyEventPoster()
            controller.finishSubmission()
        }
        let savedHistoryDomain = UserDefaults.standard.data(forKey: "inputBubbleHistory")
        let savedDrafts = UserDefaults.standard.data(forKey: "inputBubbleDrafts")
        defer {
            if let savedHistoryDomain { UserDefaults.standard.set(savedHistoryDomain, forKey: "inputBubbleHistory") } else { UserDefaults.standard.removeObject(forKey: "inputBubbleHistory") }
            if let savedDrafts { UserDefaults.standard.set(savedDrafts, forKey: "inputBubbleDrafts") } else { UserDefaults.standard.removeObject(forKey: "inputBubbleDrafts") }
        }

        let mock = LifecycleKeyEventPoster()
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

        // --- S1 定向唤起打开真面板（CG 通道，零 AX） ---
        InputBubblePreferences.isEnabled = true
        InputBubblePreferences.autoHide = false
        InputBubblePreferences.userPlacedOrigin = nil
        controller.summonForMovedWindow(windowID: windowA, pid: iterm2PID, appName: "iTerm2")
        pump(0.3)
        check("lifecycle: 定向唤起 phase=open 且目标捕获正确",
              controller.phase == .open && controller.panel != nil && controller.target?.windowID == windowA)
        check("lifecycle: 跟随引擎已启动（基线+定时器）",
              controller.followWindowOrigin != nil && controller.followBubbleOrigin != nil && controller.followTimer != nil)

        // --- S2 builtPanel 缓存命中：同一面板实例不重建 ---
        let panelBefore = controller.panel
        let (again, tvAgain) = controller.builtPanel()
        check("lifecycle: builtPanel 指纹命中返回同实例",
              again === panelBefore && tvAgain === controller.textView)

        // --- S3 尺寸联动：偏好广播 → 面板 relayout；显式 applyPanelSize ---
        InputBubblePreferences.bubbleWidth = saved.width + 40
        InputBubblePreferences.bubbleHeight = saved.height + 30
        controller.bubbleSizeDidChange(Notification(name: Notification.Name("vf-b311-size")))
        check("lifecycle: 尺寸联动广播驱动面板 relayout",
              abs(controller.panel!.frame.width - (saved.width + 40)) < 0.5)
        controller.applyPanelSize(NSSize(width: saved.width, height: saved.height))
        check("lifecycle: applyPanelSize 收回且指纹推进",
              abs(controller.panel!.frame.width - saved.width) < 0.5
              && controller.panelBuiltFor?.size == NSSize(width: saved.width, height: saved.height))

        // --- S4 编辑器形态热重建（markdown 分支）+ stale 指纹 orderOut 重建 ---
        InputBubblePreferences.editorKind = .markdown
        controller.panelBuiltFor = nil
        _ = controller.builtPanel()
        check("lifecycle: 编辑器热重建为 Markdown 编辑器",
              controller.textView is MarkdownBubbleTextView)
        InputBubblePreferences.editorKind = .plain
        controller.panelBuiltFor = nil
        _ = controller.builtPanel()
        // 宽度偏好 setter 会广播联动自愈指纹，制造 stale 用 submitOnEnter 翻转（无广播）
        InputBubblePreferences.submitOnEnter = !InputBubblePreferences.submitOnEnter
        let stalePanel = controller.panel
        _ = controller.builtPanel()
        check("lifecycle: stale 指纹重建 orderOut 旧面板换新",
              stalePanel != nil && controller.panel !== stalePanel)
        InputBubblePreferences.submitOnEnter = !InputBubblePreferences.submitOnEnter

        // --- S5 委托族：didMove 记忆/抑制、textDidChange 草稿、resignKey stay---
        if let panel = controller.panel {
            controller.suppressMoveTracking = false
            controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))
            check("lifecycle: windowDidMove 记忆用户位置", InputBubblePreferences.userPlacedOrigin != nil)
            savedUserPlacedOrigin = InputBubblePreferences.userPlacedOrigin
            let before = InputBubblePreferences.userPlacedOrigin
            controller.suppressMoveTracking = true
            controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))
            check("lifecycle: 程序化搬窗抑制不写记忆",
                  InputBubblePreferences.userPlacedOrigin == before)
        }
        controller.textView?.string = "用户输入中的草稿"
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: controller.textView))
        check("lifecycle: textDidChange 草稿落盘", InputBubbleDraftStore.shared.draft(for: windowA) != nil)
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: nil))
        check("lifecycle: 绑定跟随模式失焦 stay 不关", controller.phase == .open)

        // --- S6 历史翻阅 + 回填 + ⌘Y 历史面板开关 ---
        InputBubbleHistoryStore.shared.record("B311 历史一")
        InputBubbleHistoryStore.shared.record("B311 历史二")
        check("lifecycle: ↑ 进入历史翻阅消费按键", controller.historyPrevious())
        check("lifecycle: ↓ 回编辑现场消费按键", controller.historyNext())
        controller.textView?.string = "现场改动待回填"
        controller.lastRestoredBaseText = ""
        InputBubbleHistoryPanelController.shared.toggle(
            anchorFrame: controller.panel?.frame ?? .zero, currentWindowID: windowA) { _ in }
        pump(0.2)
        check("lifecycle: ⌘Y 历史面板打开", InputBubbleHistoryPanelController.shared.isVisible)
        InputBubbleHistoryPanelController.shared.close()
        pump(0.1)
        controller.fillFromHistory("B311 回填文本")
        check("lifecycle: fillFromHistory 回填且基线推进",
              controller.textView?.string == "B311 回填文本" && controller.lastRestoredBaseText == "B311 回填文本")

        // --- S7 跟随拍：基线漂移→面板平移+基线推进；语音让位按真实在场双向验证 ---
        controller.followWindowOrigin = NSPoint(x: controller.followWindowOrigin!.x + 120, y: controller.followWindowOrigin!.y + 40)
        let originBefore = controller.panel?.frame.origin
        let baselineBefore = controller.followWindowOrigin
        controller.followTick()
        check("lifecycle: followTick 保偏移平移且基线推进",
              (controller.panel?.frame.origin != originBefore || controller.followWindowOrigin != baselineBefore)
              && controller.followWindowOrigin != nil)
        controller.updateVoiceYield()
        let lazyTyperPresent = cgWindowListAll().contains { entry in
            entry.isOnScreen && InputBubbleLayout.isVoiceBubbleWindow(
                ownerName: entry.ownerName,
                width: entry.bounds?.width ?? 0,
                height: entry.bounds?.height ?? 0)
        }
        if lazyTyperPresent {
            check("lifecycle: 语音气泡在场 → yield 臂（降层+置位）",
                  controller.voiceYielded && controller.panel?.level == .floating)
            // 消失臂归豁免台账（LazyTyper 气泡关闭时机不可注入）
        } else {
            check("lifecycle: 语音让位巡检（无录音气泡幂等）", controller.voiceYielded == false)
        }

        // --- S8 提交链全真面板（mock 键击 + 前台/柄/AX 缝） ---
        // 提交会对 target 发 activate——pid 换成 Runner 自身（非终端激活，
        // 不污染全局 didActivate 通知流，bstate 等后续测试零互扰）
        controller.target = InputBubbleController.Target(
            pid: ownRunnerPID(), bundleID: "com.googlecode.iterm2", windowID: windowA, title: "s8")
        controller.submitFrontmostPIDProvider = { ownRunnerPID() }
        controller.submitFocusedWindowHandleProvider = { windowA }
        controller.submitSettleAXWindowProvider = { nil }  // 登录屏 AX 封锁 → verifyNoAXWindow 兜底
        controller.submit(mode: .submit)
        let submitIdle = pumpUntilIdle(3.0)
        check("lifecycle: 真面板提交链闭环（兜底路 Return 恰一次）",
              submitIdle && mock.returnKeyCount == 1 && controller.phase == .idle)
        check("lifecycle: 提交后历史落账", InputBubbleHistoryStore.shared.entries().first?.status == .submitted)

        // --- S9 改绑门：同窗早退 / 脏稿让位 / 干净改绑（关旧开新） ---
        controller.summonForMovedWindow(windowID: windowA, pid: iterm2PID, appName: "iTerm2")
        pump(0.2)
        controller.retargetForMovedWindow(windowID: windowA, pid: iterm2PID, appName: "iTerm2")
        check("lifecycle: 改绑同窗早退不动作", controller.phase == .open && controller.target?.windowID == windowA)
        controller.textView?.string = "脏稿让位"
        controller.lastRestoredBaseText = ""
        controller.retargetForMovedWindow(windowID: windowB, pid: iterm2PID, appName: "iTerm2")
        check("lifecycle: 输入中不改绑", controller.target?.windowID == windowA)
        controller.lastRestoredBaseText = controller.textView?.string ?? ""
        controller.retargetForMovedWindow(windowID: windowB, pid: iterm2PID, appName: "iTerm2")
        pump(0.2)
        check("lifecycle: 干净改绑换绑新窗", controller.target?.windowID == windowB)

        // --- S10 收尾族：SIGTERM 草稿落盘 / autoHide 失焦即关 / Esc 还焦 ---
        controller.textView?.string = "SIGTERM 前的草稿"
        controller.lastRestoredBaseText = ""
        controller.flushDraftForTermination()
        check("lifecycle: flushDraftForTermination 落草稿",
              InputBubbleDraftStore.shared.draft(for: windowB) != nil)
        InputBubblePreferences.autoHide = true
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: nil))
        check("lifecycle: autoHide 失焦即关（dismiss 臂）", controller.phase == .idle)
        controller.summonForMovedWindow(windowID: windowB, pid: iterm2PID, appName: "iTerm2")
        pump(0.2)
        let escConsumed = controller.textView(
            controller.textView ?? NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        check("lifecycle: Esc 消费且关闭还焦", escConsumed && controller.phase == .idle)

        // --- S11 summon 直接驱动（真实前台非终端 → beep 拒绝路径；热键触发通道） ---
        InputBubbleController.triggerFromHotKey()
        pump(0.2)
        check("lifecycle: 热键触发通道跑通（前台非终端 beep 拒绝）", controller.phase == .idle)

        // --- S12 AutoShow tick 编排（前台观察缝注入真实 iTerm2 身份） ---
        let autoshow = InputBubbleAutoShow.shared
        autoshow.seedBaselines()
        autoshow.frontmostAppProvider = { NSRunningApplication(processIdentifier: iterm2PID) }
        autoshow.tick()
        autoshow.tick()
        autoshow.tick()
        autoshow.frontmostAppProvider = { NSRunningApplication(processIdentifier: ownRunnerPID()) }
        autoshow.tick()
        autoshow.frontmostAppProvider = { nil }
        autoshow.tick()
        check("lifecycle: AutoShow tick 四态编排（readFresh/实例命中/非终端/无前台）不崩", true)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        pump(0.1)
        check("lifecycle: 屏幕重排通知→基线重播种", true)
        autoshow.frontmostAppProvider = nil
    }
}

/// B311：Runner 自身 pid
func ownRunnerPID() -> pid_t { ProcessInfo.processInfo.processIdentifier }
