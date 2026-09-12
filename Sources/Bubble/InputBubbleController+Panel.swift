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
        // B180：level 取 statusBar+1——高于本 app 菜单栏级浮件（25），低于 IME 候选条
        // （~popup 101；候选条必须浮在气泡文字上方，抬到 1001+ 会盖住候选=中文输入回归）。
        // 配合气泡存续期隐藏自家 screenSaver+1 浮层（ScreenOverlayManager 抑制），
        // 保证「气泡打开时 VibeFocus 最顶层 onscreen 窗=气泡」——LazyTyper 等按前台 app
        // 最顶层窗口推断活跃显示器落语音气泡的第三方工具，才不会把语音气泡甩到副屏。
        panel.level = .statusBar + 1
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
        hint.lineBreakMode = .byTruncatingTail
        card.hintLabel = hint
        card.addSubview(hint)

        let submitButton = BubbleSubmitButton(frame: .zero)
        submitButton.isBordered = false
        submitButton.target = self
        submitButton.action = #selector(submitButtonClicked)
        submitButton.toolTip = "注入并提交（同 ⌘Enter）"
        card.submitButton = submitButton
        card.addSubview(submitButton)

        let resizeHandle = BubbleResizeHandleView(frame: .zero)
        resizeHandle.toolTip = "拖拽调整气泡大小（与设置页尺寸实时同步）"
        resizeHandle.onBegin = { [weak self] in
            self?.beginResizeDrag()
        }
        resizeHandle.onDrag = { [weak self] dx, dy in
            self?.applyResizeDrag(dx: dx, dy: dy)
        }
        resizeHandle.onEnd = { [weak self] in
            self?.finishResizeDrag()
        }
        card.resizeHandle = resizeHandle
        card.addSubview(resizeHandle)

        // B178：滚动视图带真实初始帧创建（零帧起步会产生「容器宽 0」退化窗口：
        // 此间灌入长文本+光标跳尾 → scrollRangeToVisible 横向偏移且无人复位 →
        // 文本左缘被裁，用户截图实锤）；横向滚动条部件与横向弹性一并显式禁用——
        // 放不下就换行，永不横向滚动。
        let initialFrames = InputBubbleLayout.contentFrames(for: size)
        let scroll = NSScrollView(frame: initialFrames.scroll)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none
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
            width: initialFrames.scroll.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.delegate = self
        scroll.documentView = textView
        card.scrollView = scroll
        card.addSubview(scroll)

        panel.contentView = card
        panel.initialFirstResponder = textView
        card.applyLayout(size: size)

        self.panel = panel
        self.textView = textView
        self.panelBuiltFor = (size, submitOnEnter)
        return (panel, textView)
    }

    // MARK: 拖拽调尺寸（B175，右下角把手；几何派生在 InputBubbleLayout，Runner 直测）

    /// 拖拽起点快照（把手 mouseDown 时置位；finish/取消后清空）
    func beginResizeDrag() {
        guard let panel else { return }
        resizeDragStart = (origin: panel.frame.origin, size: panel.frame.size)
    }

    /// 拖拽中：左上角固定实时改尺寸（连续值不量化；didMove 期间照发——
    /// 拖拽同时也在搬窗，位置记忆按用户语义更新）
    func applyResizeDrag(dx: CGFloat, dy: CGFloat) {
        guard phase == .open, let panel, let start = resizeDragStart else { return }
        // dy 为屏幕 y 位移（向上为正）；把手在右下角，向下拖 = 增高 = 取负
        let newSize = InputBubbleLayout.resizedSize(startSize: start.size, widthDelta: dx, heightDelta: -dy)
        let newOrigin = InputBubbleLayout.resizedOrigin(
            startOrigin: start.origin, startSize: start.size, newSize: newSize
        )
        panel.setFrame(NSRect(origin: newOrigin, size: newSize), display: true)
    }

    /// 松手：量化到步进合法域并持久化（setter 变化时广播 → 设置页滑杆同步；
    /// 广播先于落账前面板已就位 → 联动观察者幂等跳过，回路收敛）。
    func finishResizeDrag() {
        defer { resizeDragStart = nil }
        guard phase == .open, let panel else { return }
        let width = InputBubblePreferences.clampedWidth(Double(panel.frame.width))
        let height = InputBubblePreferences.clampedHeight(Double(panel.frame.height))
        applyPanelSize(NSSize(width: width, height: height))
        InputBubblePreferences.bubbleWidth = width
        InputBubblePreferences.bubbleHeight = height
        log("[InputBubble] bubble resized by drag", fields: [
            "width": String(Int(width)), "height": String(Int(height))
        ])
    }

    /// 面板按新尺寸 relayout（左上角固定；程序化定位抑制位置记忆写入，
    /// 面板指纹同步更新防下次唤起误重建）。设置页滑杆联动与拖拽量化落账共用。
    func applyPanelSize(_ newSize: NSSize) {
        guard let panel else { return }
        let current = panel.frame
        let origin = InputBubbleLayout.resizedOrigin(
            startOrigin: current.origin, startSize: current.size, newSize: newSize
        )
        suppressMoveTracking = true
        panel.setFrame(NSRect(origin: origin, size: newSize), display: true)
        suppressMoveTracking = false
        (panel.contentView as? BubbleCardView)?.applyLayout(size: newSize)
        panelBuiltFor = (newSize, InputBubblePreferences.submitOnEnter)
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
