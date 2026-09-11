import AppKit

// Sources/Bubble/InputBubbleViews.swift — B151 自 InputBubbleController.swift 按类型拆出
// （逐字搬移零行为变更）：气泡专属 UI 视图族，无控制器耦合。

// MARK: - 输入气泡面板
/// 无边框 key 面板：NSPanel borderless 默认不收 key，override canBecomeKey。
final class InputBubblePanel: NSPanel {
    override var canBecomeKey: Bool { true }
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
