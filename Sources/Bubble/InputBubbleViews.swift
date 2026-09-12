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
