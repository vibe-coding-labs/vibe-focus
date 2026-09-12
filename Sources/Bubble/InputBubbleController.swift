import AppKit
import Carbon
import CoreGraphics
import Foundation

// MARK: - 输入气泡控制器（B129）
// 生命周期：快捷键唤起（默认 ⌘B，仅聚焦终端窗时）→ 本地打字 → Enter/⌘Enter 注入 → 焦点还给终端。
// 行为约束：
// - 目标在弹 UI 前捕获（TitleEditor 2026-09-07 焦点劫持教训：弹 UI 后前台已是 VibeFocus，
//   再按前台取目标必盲射）；
// - 注入前双重校验：前台 app 回到目标 pid 且 AX 窗口柄与捕获一致（防激活期间切 tab 误射，
//   B125 教训：宁可不注入，不可射进错窗）；
// - 注入 = 剪贴板快照 → 写文本 → ⌘V（bracketed paste，多行不误提交）→[可选 Return]
//   → 按纯决策恢复剪贴板；
// - 纯决策全部在 InputBubbleLogic（Runner 直测），本文件只做 IO 编排。
// B151 按域拆分（逐字搬移零行为变更）：面板构建/锚定 → +Panel，提交链机械 → +Submission，
// 剪贴板快照恢复 → +Clipboard，气泡视图族 → InputBubbleViews；本文件保留状态、生命周期与委托。
// B162：Enter/⌘Enter 改 keyDown 层拦截（doCommandBy 收不到 ⌘Enter，noop: 实锤）+
// 草稿按窗保留（InputBubbleDraftStore）+ 用户拖动位置记忆 + Stop 拉回主屏定向弹出。
// B175：气泡内提交钮（鼠标路径）+ 右下角拖拽调尺寸（量化落账广播）+
// 与设置页尺寸滑杆双向实时联动（sizeDidChangeNotification）。

@MainActor
final class InputBubbleController: NSObject {
    static let shared = InputBubbleController()

    enum Phase { case idle, open, submitting }
    var phase: Phase = .idle

    /// B160：气泡是否空闲（自动弹出观察器的冻结判据；开着/提交中均不算空闲）
    var isIdle: Bool { phase == .idle }

    var panel: InputBubblePanel?
    var textView: NSTextView?

    /// 设置窗可见性暂存（B133：气泡与设置窗都是本 app key 候选，同屏竞争时设置窗
    /// 作为 main window 会抢走 key 使气泡收不到键盘——TitleEditor 同款解法：
    /// 气泡存续期临时 orderOut 设置窗，气泡关闭后恢复可见性）
    var settingsWasVisible = false

    /// B162：程序化定位期间的 windowDidMove 抑制标记（区分程序摆放 vs 用户拖动）。
    /// setFrameOrigin 的 didMove 通知同步派发，布尔标记即足够。
    var suppressMoveTracking = false

    /// B133：尺寸/回车语义从偏好读取（设置页可调）；面板按「构建参数指纹」缓存，
    /// 指纹变化（改尺寸/改回车行为）时下次唤起重建，避免陈旧布局。
    var panelBuiltFor: (size: NSSize, submitOnEnter: Bool)?
    var bubbleSize: NSSize {
        NSSize(width: InputBubblePreferences.bubbleWidth, height: InputBubblePreferences.bubbleHeight)
    }

    /// B175：右下角拖拽调尺寸的起点快照（beginResizeDrag 置位，finish 后清空）
    var resizeDragStart: (origin: NSPoint, size: NSSize)?

    /// 热键瞬间捕获的注入目标
    struct Target {
        let pid: pid_t
        let bundleID: String?
        let windowID: UInt32
        let title: String?
    }
    var target: Target?

    /// 剪贴板快照（注入前保存；恢复决策按 changeCount 走 InputBubbleClipboardPlan）
    var clipboardItems: [[NSPasteboard.PasteboardType: Data]] = []
    var clipboardPostWriteCount = -1

    private override init() {
        super.init()
        // B175：设置页滑杆改尺寸 → 打开中的气泡面板实时联动
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(bubbleSizeDidChange(_:)),
            name: InputBubblePreferences.sizeDidChangeNotification,
            object: nil
        )
    }

    // MARK: 热键入口（CGEventTap / Carbon / fallback 三通道汇合点；TitleEditor 同款非隔离静态）

    nonisolated static func triggerFromHotKey() {
        DispatchQueue.main.async {
            InputBubbleController.shared.summon()
        }
    }

    // MARK: 唤起 / 关闭

    /// 快捷键唤起（默认 ⌘B）：开着则关（toggle）；没开则捕获聚焦终端窗并弹气泡。
    /// 前台不是可识别终端时 beep 拒绝（静默吞键会让用户以为失灵，与摆位热键同款反馈）。
    func summon() {
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        log("[InputBubble] summon called", fields: ["phase": String(describing: phase), "frontBundle": frontBundle])
        if phase == .open {
            dismiss(reactivateTarget: false)
            return
        }
        guard phase == .idle else { return }
        guard InputBubblePreferences.isEnabled else { return }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            log("[InputBubble] summon: no frontmost app")
            NSSound.beep()
            return
        }
        let bundleID = frontApp.bundleIdentifier
        guard TerminalRegistry.isTerminalOrIDEApp(
            appName: frontApp.localizedName,
            bundleIdentifier: bundleID
        ) else {
            // B164：前台是自家 app（设置窗里试键/录制）时静默退场——此刻唤起无从谈
            // 目标窗，beep 只会让用户误读为热键失灵；非终端他 app 保持 beep 拒绝反馈。
            if InputBubbleSummonGate.disposition(
                frontBundleID: bundleID,
                isTerminalApp: false
            ) == .ownApp {
                log("[InputBubble] summon: frontmost is self (settings/UI), silent skip", fields: [
                    "bundleID": bundleID ?? "nil"
                ])
                return
            }
            log("[InputBubble] summon: frontmost is not a terminal", fields: [
                "bundleID": bundleID ?? "nil"
            ])
            NSSound.beep()
            return
        }
        let pid = frontApp.processIdentifier
        guard let windowAX = WindowManager.shared.focusedWindow(for: pid),
              let windowID = WindowManager.shared.windowHandle(for: windowAX) else {
            log("[InputBubble] summon: no focused window for terminal", level: .warn, fields: [
                "pid": String(pid)
            ])
            NSSound.beep()
            return
        }
        // 锚点 frame 现查现用（CGWindowList 单窗读，非阻塞；与 AX 捕获同窗同源）
        guard let cgFrame = cgWindowBounds(for: windowID) else {
            log("[InputBubble] summon: no cg bounds for window", level: .warn, fields: [
                "windowID": String(windowID)
            ])
            NSSound.beep()
            return
        }

        let captured = Target(pid: pid, bundleID: bundleID, windowID: windowID, title: WindowManager.shared.title(of: windowAX))
        showPanel(target: captured, cgFrame: cgFrame)
        CrashContextRecorder.shared.record("input_bubble_summon windowID=\(windowID) pid=\(pid)")
    }

    /// B162：窗口被移动到主屏（Stop hook 拉回成功等）后的定向弹出。
    /// 目标窗以入参为准——此刻前台未必是该终端，不能走前台捕获路径；
    /// 身份兜底校验（终端判定/窗口还在屏上）通过后复用 showPanel。
    func summonForMovedWindow(windowID: UInt32, pid: pid_t, appName: String?) {
        guard InputBubblePreferences.isEnabled, phase == .idle else { return }
        guard let app = NSRunningApplication(processIdentifier: pid),
              TerminalRegistry.isTerminalOrIDEApp(appName: app.localizedName, bundleIdentifier: app.bundleIdentifier) else {
            log("[InputBubble] moved-window summon: app not terminal", level: .debug, fields: [
                "windowID": String(windowID), "pid": String(pid)
            ])
            return
        }
        guard let cgFrame = cgWindowBounds(for: windowID) else {
            log("[InputBubble] moved-window summon: window not onscreen", level: .debug, fields: [
                "windowID": String(windowID)
            ])
            return
        }
        let target = Target(pid: pid, bundleID: app.bundleIdentifier, windowID: windowID, title: appName)
        showPanel(target: target, cgFrame: cgFrame)
        CrashContextRecorder.shared.record("input_bubble_summon_moved windowID=\(windowID) pid=\(pid)")
    }

    private func showPanel(target: Target, cgFrame: CGRect) {
        self.target = target
        phase = .open

        // 先收起设置窗（若可见）：防止其以 main window 身份抢 key（实测存在）
        let settingsWindow = SettingsWindowController.shared.window
        settingsWasVisible = settingsWindow?.isVisible ?? false
        if settingsWasVisible { settingsWindow?.orderOut(nil) }

        let (panel, textView) = builtPanel()
        // B162：位置记忆优先——用户拖动过则出现在记忆位置（夹进目标屏可视区），
        // 从未拖过回落目标窗锚点。
        let origin = restoredOrigin(targetCGFrame: cgFrame)
        suppressMoveTracking = true
        panel.setFrameOrigin(origin)
        suppressMoveTracking = false
        // B161→B162：预填默认前缀，草稿优先——同一目标窗关了再开，打到一半的内容还在
        let savedDraft = InputBubbleDraftStore.shared.draft(for: target.windowID)
        let initial = InputBubbleKeyPlan.resolveInitialText(savedDraft: savedDraft, prefix: InputBubblePreferences.defaultPrefix)
        textView.string = initial
        textView.setSelectedRange(NSRange(location: (initial as NSString).length, length: 0))
        // B178：光标跳尾的 scrollRangeToVisible 可能带偏横向 origin（宽度暂态/滚动条
        // 出现改变可视宽），选区落定立即归零，长草稿不再左缘裁字。
        (panel.contentView as? BubbleCardView)?.normalizeHorizontalOrigin()
        panel.makeKeyAndOrderFront(nil)

        // 收键盘三件套：切 regular（accessory 不收 key）→ 激活自己 → textView 成第一响应者
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        textView.window?.makeFirstResponder(textView)
        // B180：气泡存续期隐藏自家浮层（幂等）——见 ScreenOverlayManager.setOverlaysSuppressedForInputBubble
        ScreenOverlayManager.shared.setOverlaysSuppressedForInputBubble(true)

        log("[InputBubble] bubble opened", fields: [
            "windowID": String(target.windowID),
            "pid": String(target.pid),
            "bundleID": target.bundleID ?? "nil",
            "title": truncateForLog(target.title ?? "", limit: 60),
            "origin": "\(Int(origin.x)),\(Int(origin.y))",
            "restoredDraft": String(savedDraft != nil)
        ])
    }

    /// Esc / 点外部 / toggle 关闭。reactivateTarget：Esc 关闭时把焦点还给终端
    /// （submit 路径自己已激活终端，传 false 防重复抢）。
    func dismiss(reactivateTarget: Bool) {
        guard phase == .open else { return }
        let captured = target
        panel?.orderOut(nil)
        panel = nil
        textView = nil
        target = nil
        phase = .idle
        NSApp.setActivationPolicy(.accessory)
        // B180：气泡关闭即还原自家浮层（幂等；提交路径的 finishSubmission 同款）
        ScreenOverlayManager.shared.setOverlaysSuppressedForInputBubble(false)
        restoreSettingsWindowIfNeeded()
        if reactivateTarget, let t = captured {
            _ = NSRunningApplication(processIdentifier: t.pid)?.activate(options: .activateIgnoringOtherApps)
        }
        log("[InputBubble] bubble dismissed", level: .debug)
    }

    // MARK: 提交（Enter / ⌘Enter / 提交钮）

    /// B175：气泡内提交钮（鼠标路径）——语义恒为「注入并提交」，与回车键位无关。
    @objc func submitButtonClicked() {
        submit(mode: .submit)
    }

    fileprivate func submit(mode: InputBubbleSubmitMode) {
        guard phase == .open, let target = target, let textView = textView else { return }
        let text = textView.string
        // 第一拍纯决策：空文本/cancel 只关（此时校验事实未知，传 true 只走文本/模式分支）
        if case .dismissOnly = InputBubbleSubmitGate.decide(
            text: text, mode: mode, targetStillValid: true, frontmostMatchesTarget: true
        ) {
            dismiss(reactivateTarget: true)
            return
        }

        phase = .submitting
        panel?.orderOut(nil)

        saveClipboardThenWrite(text)

        // 把焦点还给目标终端（TitleEditor 同款 activate；此时 VibeFocus 是前台 app，激活放行）
        _ = NSRunningApplication(processIdentifier: target.pid)?
            .activate(options: .activateIgnoringOtherApps)
        waitFrontmostAndInject(target: target, text: text, mode: mode, elapsedMs: 0)
    }
}

// MARK: - 文本事件（Enter/⌘Enter 在 keyDown 层拦截[B162]，Esc 走 doCommandBy，编辑实时存草稿）

extension InputBubbleController: NSTextViewDelegate {
    /// B162：InputBubbleTextView.keyDown 的 Enter/⌘Enter 拦截回调。
    /// 解析 nil = 不注入、插字面换行（默认交互 Enter 换行；⇧Enter 不会到达此处）。
    func handleEnter(commandHeld: Bool) {
        guard phase == .open else { return }
        if let mode = InputBubbleKeyPlan.resolveEnterAction(
            commandHeld: commandHeld,
            submitOnEnter: InputBubblePreferences.submitOnEnter
        ) {
            submit(mode: mode)
        } else {
            textView?.insertNewline(nil)
        }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // 到此的 insertNewline 只有 ⇧Enter / IME 路径（⌘Enter 在文本系统派发 noop:，
        // 从未到过这层——B129~B161 静默失效根因），一律默认行为：插入字面换行。
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            return false
        }
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            // Esc：关闭不注入，草稿保留（输入跟窗绑定，回来接着打）
            dismiss(reactivateTarget: true)
            return true
        default:
            return false
        }
    }

    /// B162：编辑实时落草稿（按目标窗绑定；提交成功由 inject 清除）
    func textDidChange(_ notification: Notification) {
        guard phase == .open, let target = target, let textView else { return }
        InputBubbleDraftStore.shared.save(textView.string, for: target.windowID)
    }
}

// MARK: - 面板失焦即关（用户点了终端 = 放弃气泡，不注入）；拖动位置记忆

extension InputBubbleController: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        guard phase == .open else { return }  // submitting 路径自己管理面板，不在此关
        dismiss(reactivateTarget: false)
    }

    /// B162：用户拖动气泡 → 记忆位置（下次唤起优先用）。程序化定位被
    /// suppressMoveTracking 抑制；非当前面板的 didMove 忽略。
    func windowDidMove(_ notification: Notification) {
        guard phase == .open, !suppressMoveTracking else { return }
        guard let moved = notification.object as? NSWindow, moved === panel else { return }
        InputBubblePreferences.userPlacedOrigin = moved.frame.origin
    }

    // MARK: B175 尺寸联动（设置页滑杆 ↔ 打开中的气泡面板）

    /// 偏好尺寸变化（拖拽落账 / 设置页写穿广播）→ 打开中的面板实时 relayout。
    /// 面板已等于目标尺寸时跳过（拖拽落账路径先 applyPanelSize 再写偏好，
    /// 广播到达时幂等收敛，不二次 setFrame）。
    @objc func bubbleSizeDidChange(_ notification: Notification) {
        guard phase == .open, panel != nil else { return }
        let newSize = NSSize(
            width: InputBubblePreferences.bubbleWidth,
            height: InputBubblePreferences.bubbleHeight
        )
        guard let current = panel?.frame,
              abs(current.width - newSize.width) > 0.5 || abs(current.height - newSize.height) > 0.5
        else { return }
        applyPanelSize(newSize)
    }
}
