import SwiftUI
import AppKit
import QuartzCore

// MARK: - Overlay Window
class OverlayWindow: NSWindow {
    private var textLayer: CATextLayer?
    private var screenIndex: Int = 0
    private var spaceIndex: Int = 0

    init(screen: NSScreen) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
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

        setupTextLayer()
    }

    private func setupTextLayer() {
        let layer = CATextLayer()
        layer.alignmentMode = .center
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0

        contentView?.wantsLayer = true
        contentView?.layer?.addSublayer(layer)
        self.textLayer = layer

        log("OverlayWindow: CATextLayer added")
    }

    func update(screenIndex: Int, spaceIndex: Int, preferences: ScreenIndexPreferences) {
        self.screenIndex = screenIndex
        self.spaceIndex = spaceIndex

        log("OverlayWindow update: screenIndex=\(screenIndex), spaceIndex=\(spaceIndex)")

        // 屏幕索引从1开始（对用户更友好）
        let displayScreenIndex = screenIndex + 1
        let text = "\(displayScreenIndex)-\(spaceIndex)"
        log("OverlayWindow text: '\(text)'")

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

        // 基础尺寸（应用缩放）
        let horizontalPadding: CGFloat = scaledFontSize * 0.8
        let verticalPadding: CGFloat = scaledFontSize * 0.5
        let minWidth: CGFloat = scaledFontSize * 3.5
        let minHeight: CGFloat = scaledFontSize * 2.0

        let width = max(textSize.width + horizontalPadding * 2, minWidth)
        let height = max(textSize.height + verticalPadding * 2, minHeight)

        log("OverlayWindow size: \(width)x\(height), textSize: \(textSize)")

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
        textLayer?.frame = NSRect(
            x: (width - textSize.width) / 2,
            y: (height - textSize.height) / 2 - 5, // 微调垂直居中
            width: textSize.width,
            height: textSize.height
        )
        log("OverlayWindow textLayer frame: \(textLayer?.frame ?? .zero)")

        // 强制重绘
        contentView?.needsDisplay = true
        textLayer?.setNeedsDisplay()
    }

    func updatePosition(for screen: NSScreen, position: IndexPosition = .topRight) {
        let screenFrame = screen.frame
        let windowSize = self.contentView?.bounds.size ?? CGSize(width: 100, height: 60)
        let margin: CGFloat = 20

        log("OverlayWindow updatePosition: screenFrame=\(screenFrame), windowSize=\(windowSize)")

        var origin: CGPoint
        switch position {
        case .topLeft:
            origin = CGPoint(x: screenFrame.minX + margin, y: screenFrame.maxY - windowSize.height - margin)
        case .topCenter:
            origin = CGPoint(x: screenFrame.midX - windowSize.width / 2, y: screenFrame.maxY - windowSize.height - margin)
        case .topRight:
            origin = CGPoint(x: screenFrame.maxX - windowSize.width - margin, y: screenFrame.maxY - windowSize.height - margin)
        case .bottomLeft:
            origin = CGPoint(x: screenFrame.minX + margin, y: screenFrame.minY + margin)
        case .bottomCenter:
            origin = CGPoint(x: screenFrame.midX - windowSize.width / 2, y: screenFrame.minY + margin)
        case .bottomRight:
            origin = CGPoint(x: screenFrame.maxX - windowSize.width - margin, y: screenFrame.minY + margin)
        }

        log("OverlayWindow setting origin: \(origin)")
        self.setFrameOrigin(origin)
    }

    func show() {
        log("OverlayWindow show() called")
        self.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        self.orderOut(nil)
    }
}
