import AppKit
import Carbon
import CoreGraphics
import Foundation

// MARK: - 输入气泡控制器（B129）
// 生命周期：⌥⌘B 唤起（仅聚焦终端窗时）→ 本地打字 → Enter/⌘Enter 注入 → 焦点还给终端。
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

    /// B133：尺寸/回车语义从偏好读取（设置页可调）；面板按「构建参数指纹」缓存，
    /// 指纹变化（改尺寸/改回车行为）时下次唤起重建，避免陈旧布局。
    var panelBuiltFor: (size: NSSize, submitOnEnter: Bool)?
    var bubbleSize: NSSize {
        NSSize(width: InputBubblePreferences.bubbleWidth, height: InputBubblePreferences.bubbleHeight)
    }

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
    }

    // MARK: 热键入口（CGEventTap / Carbon / fallback 三通道汇合点；TitleEditor 同款非隔离静态）

    nonisolated static func triggerFromHotKey() {
        DispatchQueue.main.async {
            InputBubbleController.shared.summon()
        }
    }

    // MARK: 唤起 / 关闭

    /// ⌥⌘B：开着则关（toggle）；没开则捕获聚焦终端窗并弹气泡。
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

    private func showPanel(target: Target, cgFrame: CGRect) {
        self.target = target
        phase = .open

        // 先收起设置窗（若可见）：防止其以 main window 身份抢 key（实测存在）
        let settingsWindow = SettingsWindowController.shared.window
        settingsWasVisible = settingsWindow?.isVisible ?? false
        if settingsWasVisible { settingsWindow?.orderOut(nil) }

        let (panel, textView) = builtPanel()
        let origin = anchorOrigin(targetCGFrame: cgFrame)
        panel.setFrameOrigin(origin)
        // B161：预填默认前缀（如 "/goal "），光标落到末尾待续写
        let prefix = InputBubblePreferences.defaultPrefix
        textView.string = prefix
        textView.setSelectedRange(NSRange(location: (prefix as NSString).length, length: 0))
        panel.makeKeyAndOrderFront(nil)

        // 收键盘三件套：切 regular（accessory 不收 key）→ 激活自己 → textView 成第一响应者
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        textView.window?.makeFirstResponder(textView)

        log("[InputBubble] bubble opened", fields: [
            "windowID": String(target.windowID),
            "pid": String(target.pid),
            "bundleID": target.bundleID ?? "nil",
            "title": truncateForLog(target.title ?? "", limit: 60)
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
        restoreSettingsWindowIfNeeded()
        if reactivateTarget, let t = captured {
            _ = NSRunningApplication(processIdentifier: t.pid)?.activate(options: .activateIgnoringOtherApps)
        }
        log("[InputBubble] bubble dismissed", level: .debug)
    }

    // MARK: 提交（Enter / ⌘Enter）

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

// MARK: - 文本事件（Enter/⌘Enter/Shift+Enter/Esc）

extension InputBubbleController: NSTextViewDelegate {
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let mods = NSApp.currentEvent?.modifierFlags.intersection([.shift, .command]) ?? []
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            // B161：解析 nil = 插入字面换行（默认交互）；⇧ 恒为换行
            if mods.contains(.shift) { return false }
            guard let mode = InputBubbleKeyPlan.resolveEnterAction(
                commandHeld: mods.contains(.command),
                submitOnEnter: InputBubblePreferences.submitOnEnter
            ) else {
                return false
            }
            submit(mode: mode)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss(reactivateTarget: true)
            return true
        default:
            return false
        }
    }
}

// MARK: - 面板失焦即关（用户点了终端 = 放弃气泡，不注入）

extension InputBubbleController: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        guard phase == .open else { return }  // submitting 路径自己管理面板，不在此关
        dismiss(reactivateTarget: false)
    }
}
