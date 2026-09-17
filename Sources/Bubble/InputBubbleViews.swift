import AppKit
import Carbon

// Sources/Bubble/InputBubbleViews.swift — B151 自 InputBubbleController.swift 按类型拆出
// （逐字搬移零行为变更）：气泡专属 UI 视图族，无控制器耦合。

// MARK: - 输入气泡面板
/// 无边框 key 面板：NSPanel borderless 默认不收 key，override canBecomeKey。
/// B183 绑定跟随模式的「点气泡重新收键」走控制器本地事件监视器（面板 mouseDown
/// 对内容区点击不触发——事件派发给最深子视图），不在面板层挂钩。
final class InputBubblePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - 气泡输入框（B162）
/// Enter/⌘Enter 在 keyDown 层拦截，不走 doCommandBy 委托。
/// 依据（2026-09-11 最小复现实锤）：⌘+Return 到达文本系统时 AppKit 派发的是
/// `noop:` 而非 `insertNewline:`——B129~B161 的委托层只认 insertNewline:，
/// ⌘Enter 因此静默失效（生产日志：气泡打开后零 injecting/dismiss 记录）。
/// keyDown 事件本体始终携带 ⌘ 修饰到达（同实验验证），在此拦截最可靠；
/// ⇧Enter 不拦截（落 super → 默认换行）。
/// B195：↑↓ 历史翻阅——光标在首行按 ↑ / 末行按 ↓ 才进历史回调（多行编辑的
/// 光标移动不受干扰）；回调返回 false（无历史可翻）落 super 正常移动光标；
/// IME 组词态一律放行（B172 同款）。
final class InputBubbleTextView: NSTextView {
    /// 非 ⇧ 的 Return/小键盘 Enter 按下回调（commandHeld = ⌘ 是否按住）
    var onEnterKey: ((Bool) -> Void)?
    /// B195：↑↓ 历史翻阅回调，返回 true=已消费
    var onHistoryPrevious: (() -> Bool)?
    var onHistoryNext: (() -> Bool)?
    /// B204：⌘Y 唤出/收回历史面板回调，返回 true=已消费
    var onHistoryPanelToggle: (() -> Bool)?

    private static let enterKeyCodes: Set<UInt16> = [UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter)]

    override func keyDown(with event: NSEvent) {
        // B172：IME 组词态放行——中文/日文等输入法组词时按 Enter 是「确认候选词」，
        // 必须交给输入法（super → inputContext），拦截会把确认组词误当提交注入，
        // 把带标记文本的半截拼音直接射进终端（CJK 用户主路径）。
        if Self.enterKeyCodes.contains(event.keyCode),
           !event.modifierFlags.contains(.shift),
           !hasMarkedText() {
            onEnterKey?(event.modifierFlags.contains(.command))
            return
        }
        // B204：⌘Y 直达历史面板（与光标位置无关；IME 组词态照旧放行）
        if !hasMarkedText(),
           InputBubbleHistoryPanelKeyPlan.isHistoryPanelToggle(keyCode: event.keyCode, flags: event.modifierFlags),
           onHistoryPanelToggle?() == true {
            return
        }
        if !hasMarkedText(),
           event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty {
            if event.keyCode == UInt16(kVK_UpArrow), isSelectionOnFirstLine,
               onHistoryPrevious?() == true {
                return
            }
            if event.keyCode == UInt16(kVK_DownArrow), isSelectionOnLastLine,
               onHistoryNext?() == true {
                return
            }
        }
        super.keyDown(with: event)
    }

    /// 光标（选区起点）所在行是否为文本首行（历史 ↑ 的准入条件）
    var isSelectionOnFirstLine: Bool {
        (string as NSString).lineRange(for: NSRange(location: selectedRange().location, length: 0)).location == 0
    }

    /// 光标（选区起点）所在行是否为文本末行（历史 ↓ 的准入条件）
    var isSelectionOnLastLine: Bool {
        let line = (string as NSString).lineRange(for: NSRange(location: selectedRange().location, length: 0))
        return NSMaxRange(line) >= (string as NSString).length
    }
}

// MARK: - 气泡卡片视图（VibeFocus 奶油暖底 + 珊瑚描边语系）

final class BubbleCardView: NSView {
    // B175：内容子视图引用（builtPanel 建立后持有；applyLayout 按 contentFrames 统一摆放）
    var hintLabel: NSTextField?
    var scrollView: NSScrollView?
    var submitButton: BubbleSubmitButton?
    var resizeHandle: BubbleResizeHandleView?
    var closeButton: BubbleCloseButton?
    /// B196：底栏最左的历史入口钮
    var historyButton: BubbleHistoryButton?

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

    /// B175：按面板尺寸统一摆放内容（初建 / 拖拽 relayout / 设置页联动 relayout 共用）。
    /// 输入区宽度变化后同步 textContainer（与 builtPanel 初建同式）。
    func applyLayout(size: NSSize) {
        frame = NSRect(origin: .zero, size: size)
        let frames = InputBubbleLayout.contentFrames(for: size)
        hintLabel?.frame = frames.hint
        scrollView?.frame = frames.scroll
        submitButton?.frame = frames.button
        resizeHandle?.frame = frames.grip
        closeButton?.frame = frames.close
        historyButton?.frame = frames.history
        if let scrollView, let textView = scrollView.documentView as? NSTextView {
            // B178：显式 tile 同步 clip/滚动条与 documentView 宽度（不依赖活窗口布局时机，
            // legacy 滚动条槽出现/消失的可视宽变化也在这一步收敛）
            scrollView.tile()
            // B178：钉死「文档宽 = 可视宽」不变量——isHorizontallyResizable=false 是
            // 产品语义（放不下就换行），宽度同步不delegate给 autoresizing 的隐式时机
            //（跨滚动条风格/暂态窗口下 AppKit 可能残留 ±滚动条槽宽的错位）
            let visibleWidth = scrollView.contentView.bounds.width
            if abs(textView.frame.width - visibleWidth) > 0.5 {
                textView.setFrameSize(NSSize(width: visibleWidth, height: textView.frame.height))
            }
            textView.textContainer?.containerSize = NSSize(
                width: scrollView.contentSize.width,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        normalizeHorizontalOrigin()
    }

    /// B178：横向漂移归零——宽度暂态期间（建框/联动 relayout/竖向滚动条出现改变可视宽），
    /// 光标跳尾的 scrollRangeToVisible 会把 clip/textView 的 origin.x 带偏且无人复位，
    /// 表现为文本左缘被裁（用户截图实锤「/goal」只剩「oal」，体感即「水平滚动条」）。
    /// 每次布局与选区落定后强制回零；横向滚动已被策略禁用，这里只清残局。
    func normalizeHorizontalOrigin() {
        guard let scrollView, let textView = scrollView.documentView as? NSTextView else { return }
        let clip = scrollView.contentView
        if clip.bounds.origin.x != 0 {
            clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y))
            scrollView.reflectScrolledClipView(clip)
        }
        if textView.bounds.origin.x != 0 {
            textView.setBoundsOrigin(NSPoint(x: 0, y: textView.bounds.origin.y))
        }
    }
}

// MARK: - 悬停小手光标（B187：✕ / 提交两处可点区给 pointingHand 可点性暗示）

extension NSView {
    /// 鼠标悬停显示小手。幂等（userInfo 打标防重复添加）；activeAlways 使
    /// 跟随模式下气泡非 key 时也生效；移出区域由 AppKit cursor 机制自动复位。
    func installPointingHandCursor() {
        guard !trackingAreas.contains(where: { $0.userInfo?["pointingHand"] != nil }) else { return }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: ["pointingHand": true]
        ))
    }
}

// MARK: - 提交钮（B175：鼠标路径）

/// 气泡内提交钮：珊瑚→蜜桃渐变胶囊（VibeColors 品牌语的 AppKit 版）。
/// 动作语义恒为「注入并提交」（.submit），与回车键位语义互不干扰。
final class BubbleSubmitButton: NSButton {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installPointingHandCursor()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let start = NSColor(rgbHex: isDark ? 0xFF8266 : 0xE64A33)
        let end = NSColor(rgbHex: isDark ? 0xFFB07A : 0xF49A4A)
        let path = NSBezierPath(
            roundedRect: bounds,
            xRadius: bounds.height / 2,
            yRadius: bounds.height / 2
        )
        NSGradient(starting: start, ending: end)?.draw(in: path, angle: -90)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let label = "⏎ 提交" as NSString
        let labelSize = label.size(withAttributes: attributes)
        label.draw(
            at: NSPoint(x: (bounds.width - labelSize.width) / 2, y: (bounds.height - labelSize.height) / 2),
            withAttributes: attributes
        )
    }
}

// MARK: - 关闭钮（B183：绑定跟随模式的手动关闭入口）

/// 右上角 ✕：细线叉，悬停感用描边色；点击只发回调（控制器 dismiss），不抢键。
final class BubbleCloseButton: NSView {
    var onClose: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installPointingHandCursor()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        onClose?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let color = (isDark ? NSColor.white.withAlphaComponent(0.45) : NSColor(rgbHex: 0xA08D6E)).withAlphaComponent(0.9)
        color.setStroke()
        let b = bounds
        let inset: CGFloat = 4.5
        let path = NSBezierPath()
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: b.minX + inset, y: b.minY + inset))
        path.line(to: NSPoint(x: b.maxX - inset, y: b.maxY - inset))
        path.move(to: NSPoint(x: b.maxX - inset, y: b.minY + inset))
        path.line(to: NSPoint(x: b.minX + inset, y: b.maxY - inset))
        path.stroke()
    }
}

// MARK: - 历史入口钮（B196：底栏最左「历史」，单击开历史面板）

/// 文字小钮：底栏同色系（米棕），悬停小手；点击只发回调（控制器开面板），不抢键。
final class BubbleHistoryButton: NSView {
    var onOpen: (() -> Void)?
    private var isPressed = false

    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installPointingHandCursor()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        needsDisplay = true
        // 按下与抬起都在钮内才算点击（拖出去取消，标准按钮语义）
        if wasPressed, bounds.contains(convert(event.locationInWindow, from: nil)) {
            onOpen?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let base = isDark ? NSColor.white.withAlphaComponent(0.45) : NSColor(rgbHex: 0xA08D6E)
        let color = isPressed ? NSColor(rgbHex: isDark ? 0xFF8266 : 0xE64A33) : base
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: color
        ]
        let label = "历史" as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }
}

// MARK: - 缩放把手（B175：右下角拖拽调尺寸）

/// 右下角对角线握把：按住拖拽实时改尺寸（回调原始屏幕位移），松手由控制器
/// 量化 + 持久化。mouseDownCanMoveWindow=false 与「背景拖动移窗」解耦。
final class BubbleResizeHandleView: NSView {
    /// 拖拽回调：dx/dy 为 AppKit 全局屏幕坐标的原始位移（y 向上为正）
    var onBegin: (() -> Void)?
    var onDrag: ((_ dx: CGFloat, _ dy: CGFloat) -> Void)?
    var onEnd: (() -> Void)?

    private var dragStartMouse: NSPoint?

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        onBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartMouse else { return }
        let now = NSEvent.mouseLocation
        onDrag?(now.x - start.x, now.y - start.y)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartMouse != nil else { return }
        dragStartMouse = nil
        onEnd?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let color = isDark ? NSColor.white.withAlphaComponent(0.30) : NSColor(rgbHex: 0xB9A98E)
        color.setStroke()
        let bounds = self.bounds
        let path = NSBezierPath()
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        // 三道 45° 斜线贴右下角（x−y=常数的平行线族，k 越大越靠角）
        for offset in [CGFloat(2), 6, 10] {
            let constant = (bounds.maxX - bounds.minY) - offset
            path.move(to: NSPoint(x: constant + bounds.minY, y: bounds.minY))
            path.line(to: NSPoint(x: bounds.maxX, y: bounds.maxX - constant))
        }
        path.stroke()
    }
}
