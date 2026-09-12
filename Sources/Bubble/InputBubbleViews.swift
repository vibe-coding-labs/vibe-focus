import AppKit
import Carbon

// Sources/Bubble/InputBubbleViews.swift — B151 自 InputBubbleController.swift 按类型拆出
// （逐字搬移零行为变更）：气泡专属 UI 视图族，无控制器耦合。

// MARK: - 输入气泡面板
/// 无边框 key 面板：NSPanel borderless 默认不收 key，override canBecomeKey。
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
final class InputBubbleTextView: NSTextView {
    /// 非 ⇧ 的 Return/小键盘 Enter 按下回调（commandHeld = ⌘ 是否按住）
    var onEnterKey: ((Bool) -> Void)?

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
        super.keyDown(with: event)
    }
}

// MARK: - 气泡卡片视图（VibeFocus 奶油暖底 + 珊瑚描边语系）

final class BubbleCardView: NSView {
    // B175：内容子视图引用（builtPanel 建立后持有；applyLayout 按 contentFrames 统一摆放）
    var hintLabel: NSTextField?
    var scrollView: NSScrollView?
    var submitButton: BubbleSubmitButton?
    var resizeHandle: BubbleResizeHandleView?

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
        if let scrollView, let textView = scrollView.documentView as? NSTextView {
            textView.textContainer?.containerSize = NSSize(
                width: scrollView.contentSize.width,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
    }
}

// MARK: - 提交钮（B175：鼠标路径）

/// 气泡内提交钮：珊瑚→蜜桃渐变胶囊（VibeColors 品牌语的 AppKit 版）。
/// 动作语义恒为「注入并提交」（.submit），与回车键位语义互不干扰。
final class BubbleSubmitButton: NSButton {
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
