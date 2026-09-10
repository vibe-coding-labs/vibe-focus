import AppKit
import Carbon
import CoreGraphics
import Foundation

// MARK: - 输入气泡面板
/// 无边框 key 面板：NSPanel borderless 默认不收 key，override canBecomeKey。
final class InputBubblePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

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

@MainActor
final class InputBubbleController: NSObject {
    static let shared = InputBubbleController()

    private enum Phase { case idle, open, submitting }
    private var phase: Phase = .idle

    private var panel: InputBubblePanel?
    private var textView: NSTextView?

    private let bubbleSize = NSSize(width: 480, height: 150)

    /// 热键瞬间捕获的注入目标
    private struct Target {
        let pid: pid_t
        let bundleID: String?
        let windowID: UInt32
        let title: String?
    }
    private var target: Target?

    /// 剪贴板快照（注入前保存；恢复决策按 changeCount 走 InputBubbleClipboardPlan）
    private var clipboardItems: [[NSPasteboard.PasteboardType: Data]] = []
    private var clipboardPostWriteCount = -1

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

        let (panel, textView) = builtPanel()
        let origin = anchorOrigin(targetCGFrame: cgFrame)
        panel.setFrameOrigin(origin)
        textView.string = ""
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

    /// 激活后等前台/窗口柄到位再注入（非阻塞轮询；超时宁可不注入）。
    private func waitFrontmostAndInject(target: Target, text: String, mode: InputBubbleSubmitMode, elapsedMs: Int) {
        let frontmostMatches = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
        if frontmostMatches {
            // 前台已到位：再验窗口柄（防激活期间切 tab / 关窗）
            let handle = WindowManager.shared.focusedWindow(for: target.pid)
                .flatMap { WindowManager.shared.windowHandle(for: $0) }
            let gate = InputBubbleSubmitGate.decide(
                text: text,
                mode: mode,
                targetStillValid: handle == target.windowID,
                frontmostMatchesTarget: true
            )
            switch gate {
            case .proceed(let steps):
                inject(steps: steps, target: target)
            case .dismissOnly:
                finishSubmission()
            case .abortMissingTarget:
                abortSubmission(reason: "target window gone", target: target)
            case .abortFrontmostMismatch:
                abortSubmission(reason: "frontmost mismatch (unreachable)", target: target)
            }
            return
        }
        if elapsedMs >= InputBubbleTiming.frontmostPollBudgetMs {
            abortSubmission(reason: "frontmost activate timeout", target: target)
            return
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(InputBubbleTiming.frontmostPollIntervalMs)
        ) { [weak self] in
            self?.waitFrontmostAndInject(
                target: target, text: text, mode: mode,
                elapsedMs: elapsedMs + InputBubbleTiming.frontmostPollIntervalMs
            )
        }
    }

    private func inject(steps: [InputBubbleKeyPlan.Step], target: Target) {
        log("[InputBubble] injecting", fields: [
            "steps": steps.map { $0 == .paste ? "paste" : "return" }.joined(separator: ","),
            "windowID": String(target.windowID),
            "pid": String(target.pid)
        ])
        CrashContextRecorder.shared.record("input_bubble_inject windowID=\(target.windowID) steps=\(steps.count)")

        for (index, step) in steps.enumerated() {
            let delayMs = index * InputBubbleTiming.pasteToReturnDelayMs
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
                switch step {
                case .paste:
                    self?.postKeyCombo(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
                case .returnKey:
                    self?.postKeyCombo(keyCode: CGKeyCode(kVK_Return), flags: [])
                }
            }
        }

        let totalMs = max(steps.count - 1, 0) * InputBubbleTiming.pasteToReturnDelayMs
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(totalMs + InputBubbleTiming.clipboardRestoreDelayMs)) { [weak self] in
            self?.restoreClipboardIfSafe()
            self?.finishSubmission()
        }
    }

    private func abortSubmission(reason: String, target: Target) {
        NSSound.beep()
        log("[InputBubble] inject aborted", level: .warn, fields: [
            "reason": reason,
            "windowID": String(target.windowID)
        ])
        CrashContextRecorder.shared.record("input_bubble_abort reason=\(reason) windowID=\(target.windowID)")
        restoreClipboardIfSafe()
        finishSubmission()
    }

    /// 收尾：回归 accessory 政策 + 状态复位（面板已在 submit 时 orderOut）。
    private func finishSubmission() {
        phase = .idle
        panel = nil
        textView = nil
        target = nil
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: 键击投递（NativeSpaceBridge Escape 同款 .cghidEventTap 语义）

    private func postKeyCombo(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return }
        down.flags = flags
        down.post(tap: .cghidEventTap)
        guard let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
        up.flags = flags
        up.post(tap: .cghidEventTap)
    }

    // MARK: 剪贴板快照 / 恢复

    private func saveClipboardThenWrite(_ text: String) {
        let pb = NSPasteboard.general
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        if let pbi = pb.pasteboardItems {
            for item in pbi.prefix(5) {
                var dict: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types.prefix(10) {
                    if type.rawValue.hasPrefix("dyn.") { continue }
                    if let data = item.data(forType: type) { dict[type] = data }
                }
                if !dict.isEmpty { items.append(dict) }
            }
        }
        clipboardItems = items
        pb.clearContents()
        pb.setString(text, forType: .string)
        clipboardPostWriteCount = pb.changeCount
    }

    private func restoreClipboardIfSafe() {
        guard clipboardPostWriteCount >= 0 else { return }
        let pb = NSPasteboard.general
        let shouldRestore = InputBubbleClipboardPlan.shouldRestore(
            postWriteCount: clipboardPostWriteCount,
            currentCount: pb.changeCount
        )
        clipboardPostWriteCount = -1
        guard shouldRestore else {
            log("[InputBubble] clipboard changed during injection, skip restore", level: .debug)
            clipboardItems = []
            return
        }
        pb.clearContents()
        for dict in clipboardItems {
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            pb.writeObjects([item])
        }
        clipboardItems = []
        log("[InputBubble] clipboard restored", level: .debug)
    }

    // MARK: 面板构建（lazy 单建；锚定每次 summon 重算）

    private func builtPanel() -> (InputBubblePanel, NSTextView) {
        if let panel, let textView { return (panel, textView) }

        let panel = InputBubblePanel(
            contentRect: NSRect(origin: .zero, size: bubbleSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self

        let card = BubbleCardView(frame: NSRect(origin: .zero, size: bubbleSize))

        let hint = NSTextField(labelWithString: "Enter 注入终端 · Shift+Enter 换行 · ⌘Enter 仅粘贴 · Esc 关闭")
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = Self.dynamicColor(lightHex: 0x8A7B68, darkHex: 0xA29380)
        hint.frame = NSRect(x: 14, y: 8, width: bubbleSize.width - 28, height: 14)
        card.addSubview(hint)

        let scroll = NSScrollView(frame: NSRect(x: 12, y: 26, width: bubbleSize.width - 24, height: bubbleSize.height - 40))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let textView = NSTextView(frame: scroll.bounds)
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = Self.dynamicColor(lightHex: 0x40362B, darkHex: 0xF1E9DE)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.delegate = self
        scroll.documentView = textView
        card.addSubview(scroll)

        panel.contentView = card
        panel.initialFirstResponder = textView

        self.panel = panel
        self.textView = textView
        return (panel, textView)
    }

    /// 锚点：目标窗（AppKit 全局坐标）左下内侧，夹进所在屏 visibleFrame。
    private func anchorOrigin(targetCGFrame: CGRect) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let appKitFrame = InputBubbleLayout.appKitFrame(
            fromCGFrame: targetCGFrame,
            primaryScreenHeight: primaryHeight
        )
        let visibleFrame = containingScreenVisibleFrame(for: appKitFrame)
        return InputBubbleLayout.anchorOrigin(
            targetAppKitFrame: appKitFrame,
            bubbleSize: bubbleSize,
            visibleFrame: visibleFrame,
            margin: 16
        )
    }

    /// 目标窗中心点所在屏的 visibleFrame（找不到回落主屏）。
    private func containingScreenVisibleFrame(for appKitFrame: CGRect) -> CGRect {
        let center = CGPoint(x: appKitFrame.midX, y: appKitFrame.midY)
        let screen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
            ?? NSScreen.main
        return screen?.visibleFrame ?? appKitFrame
    }

    private static func dynamicColor(lightHex: UInt32, darkHex: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgbHex: isDark ? darkHex : lightHex)
        }
    }
}

// MARK: - 气泡卡片视图（VibeFocus 奶油暖底 + 珊瑚描边语系）

final class BubbleCardView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = false
    }

    override func draw(_ dirtyRect: NSRect) {
        // 动态色在 draw 里解析（appearance 变化会触发重绘）
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let background = (isDark ? NSColor(rgbHex: 0x211C18) : NSColor(rgbHex: 0xF6F1E7)).withAlphaComponent(0.97)
        let border = isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor(rgbHex: 0xE8DDCB)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
        background.setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

// MARK: - 文本事件（Enter/⌘Enter/Shift+Enter/Esc）

extension InputBubbleController: NSTextViewDelegate {
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let mods = NSApp.currentEvent?.modifierFlags.intersection([.shift, .command]) ?? []
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if mods.contains(.shift) { return false }  // 默认行为：插入换行
            submit(mode: mods.contains(.command) ? .pasteOnly : .submit)
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
