import SwiftUI
import AppKit
import QuartzCore

// MARK: - Overlay Window
class OverlayWindow: NSWindow {
    private var textLayer: CATextLayer?
    private var screenIndex: Int = 0
    private var spaceIndex: Int = 0

    /// Pure layout calculation — extracted for testability.
    static func calculateOverlayOrigin(
        position: IndexPosition,
        screenFrame: CGRect,
        windowSize: CGSize,
        margin: CGFloat
    ) -> CGPoint {
        let edgeMargin = max(0, margin)
        switch position {
        case .topLeft:
            return CGPoint(x: screenFrame.minX + edgeMargin, y: screenFrame.maxY - windowSize.height - edgeMargin)
        case .topCenter:
            return CGPoint(x: screenFrame.midX - windowSize.width / 2, y: screenFrame.maxY - windowSize.height - edgeMargin)
        case .topRight:
            return CGPoint(x: screenFrame.maxX - windowSize.width - edgeMargin, y: screenFrame.maxY - windowSize.height - edgeMargin)
        case .bottomLeft:
            return CGPoint(x: screenFrame.minX + edgeMargin, y: screenFrame.minY + edgeMargin)
        case .bottomCenter:
            return CGPoint(x: screenFrame.midX - windowSize.width / 2, y: screenFrame.minY + edgeMargin)
        case .bottomRight:
            return CGPoint(x: screenFrame.maxX - windowSize.width - edgeMargin, y: screenFrame.minY + edgeMargin)
        }
    }

    /// Pure text and size calculation — extracted for testability.
    static func calculateOverlayLabel(screenIndex: Int, spaceIndex: Int) -> String {
        "\(screenIndex + 1)-\(spaceIndex)"
    }

    /// Pure dimension calculation for overlay — extracted for testability.
    static func calculateOverlaySize(
        textWidth: CGFloat,
        textHeight: CGFloat,
        scaledFontSize: CGFloat
    ) -> CGSize {
        let horizontalPadding: CGFloat = scaledFontSize * 0.8
        let verticalPadding: CGFloat = scaledFontSize * 0.5
        let minWidth: CGFloat = scaledFontSize * 3.5
        let minHeight: CGFloat = scaledFontSize * 2.0
        let width = max(textWidth + horizontalPadding * 2, minWidth)
        let height = max(textHeight + verticalPadding * 2, minHeight)
        return CGSize(width: width, height: height)
    }

    init(screen: NSScreen) {
        let initialFrame = NSRect(x: 0, y: 0, width: 200, height: 100)
        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        self.level = .screenSaver + 1
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]

        // FIX: 必须先设置 contentView，否则 setupTextLayer 无法添加子图层
        self.contentView = NSView()
        setupTextLayer()
    }

    private func setupTextLayer() {
        let layer = CATextLayer()
        layer.alignmentMode = .center
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0

        contentView?.wantsLayer = true
        contentView?.layer?.addSublayer(layer)
        self.textLayer = layer
    }

    func update(screenIndex: Int, spaceIndex: Int, preferences: ScreenIndexPreferences) {
        self.screenIndex = screenIndex
        self.spaceIndex = spaceIndex

        // 屏幕索引从1开始（对用户更友好）
        let text = Self.calculateOverlayLabel(screenIndex: screenIndex, spaceIndex: spaceIndex)

        // 计算尺寸（应用面板缩放）
        let scaledFontSize = preferences.fontSize * preferences.panelScale
        let font = NSFont.systemFont(ofSize: scaledFontSize, weight: .bold)

        // 使用配置的文字颜色
        let textColor = NSColor(preferences.textColor.swiftUIColor)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let attributedString = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributedString.size()

        let overlaySize = Self.calculateOverlaySize(
            textWidth: textSize.width,
            textHeight: textSize.height,
            scaledFontSize: scaledFontSize
        )
        let width = overlaySize.width
        let height = overlaySize.height

        // 设置窗口尺寸
        self.setContentSize(CGSize(width: width, height: height))

        // 设置背景（使用配置的颜色和透明度）
        contentView?.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let bgColor = NSColor(preferences.backgroundColor.swiftUIColor).withAlphaComponent(preferences.opacity)
        contentView?.layer?.backgroundColor = bgColor.cgColor
        contentView?.layer?.cornerRadius = 8 * preferences.panelScale
        contentView?.layer?.masksToBounds = false
        contentView?.layer?.borderWidth = 2 * preferences.panelScale
        contentView?.layer?.borderColor = NSColor.white.cgColor

        // 设置文本层
        textLayer?.string = attributedString
        let textFrame = NSRect(
            x: (width - textSize.width) / 2,
            y: (height - textSize.height) / 2 - 5, // 微调垂直居中
            width: textSize.width,
            height: textSize.height
        )
        textLayer?.frame = textFrame

        // 强制重绘
        contentView?.needsDisplay = true
        textLayer?.setNeedsDisplay()
    }

    func updatePosition(for screen: NSScreen, position: IndexPosition = .topRight, margin: CGFloat = 20) {
        let screenFrame = screen.frame
        let windowSize = self.contentView?.bounds.size ?? CGSize(width: 100, height: 60)
        let origin = Self.calculateOverlayOrigin(
            position: position,
            screenFrame: screenFrame,
            windowSize: windowSize,
            margin: margin
        )
        self.setFrameOrigin(origin)
    }

    func show() {
        self.orderFrontRegardless()
    }

    func hide() {
        self.orderOut(nil)
    }
}
