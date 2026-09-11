import AppKit

// Sources/Bubble/InputBubbleController+Panel.swift — B151 自 InputBubbleController.swift
// 按域拆出（逐字搬移零行为变更）：面板构建与锚定几何。
// 纯几何决策在 InputBubbleLayout（RunnerInputBubbleTests 直测），本文件只做 NSScreen/面板 IO。

extension InputBubbleController {
    // MARK: 面板构建（lazy 单建；锚定每次 summon 重算）

    func builtPanel() -> (InputBubblePanel, NSTextView) {
        let size = bubbleSize
        let submitOnEnter = InputBubblePreferences.submitOnEnter
        if let panel, let textView, let built = panelBuiltFor,
           built.size == size, built.submitOnEnter == submitOnEnter {
            return (panel, textView)
        }
        if let stale = panel { stale.orderOut(nil) }

        let panel = InputBubblePanel(
            contentRect: NSRect(origin: .zero, size: size),
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

        let card = BubbleCardView(frame: NSRect(origin: .zero, size: size))

        let hint = NSTextField(labelWithString: InputBubbleKeyPlan.hintText(submitOnEnter: submitOnEnter))
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = Self.dynamicColor(lightHex: 0x8A7B68, darkHex: 0xA29380)
        hint.frame = NSRect(x: 14, y: 8, width: size.width - 28, height: 14)
        hint.lineBreakMode = .byTruncatingTail
        card.addSubview(hint)

        let scroll = NSScrollView(frame: NSRect(x: 12, y: 26, width: size.width - 24, height: size.height - 40))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let textView = InputBubbleTextView(frame: scroll.bounds)
        // B162：Enter/⌘Enter 走 keyDown 层拦截回调（doCommandBy 收不到 ⌘Enter）
        textView.onEnterKey = { [weak self] commandHeld in
            self?.handleEnter(commandHeld: commandHeld)
        }
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
        self.panelBuiltFor = (size, submitOnEnter)
        return (panel, textView)
    }

    /// 锚点：目标窗（AppKit 全局坐标）左下内侧，夹进所在屏 visibleFrame。
    func anchorOrigin(targetCGFrame: CGRect) -> CGPoint {
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

    /// B162：唤起位置 = 用户拖动记忆优先（origin 夹进目标屏可视区，防跨屏/屏外悬空）；
    /// 从未拖过回落目标窗锚点。
    func restoredOrigin(targetCGFrame: CGRect) -> CGPoint {
        let fallback = anchorOrigin(targetCGFrame: targetCGFrame)
        guard let saved = InputBubblePreferences.userPlacedOrigin else { return fallback }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let appKitFrame = InputBubbleLayout.appKitFrame(
            fromCGFrame: targetCGFrame,
            primaryScreenHeight: primaryHeight
        )
        let visibleFrame = containingScreenVisibleFrame(for: appKitFrame)
        return InputBubbleLayout.clampedOrigin(
            position: saved,
            bubbleSize: bubbleSize,
            visibleFrame: visibleFrame
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
