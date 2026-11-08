import AppKit
import Foundation

// MARK: - 输入历史面板 · 视图族（B320 拆分，行为不变）
// HistoryStatusBadge / HistoryMiniButton / HistoryRowView 三类整体逐字搬移自
// InputBubbleHistoryPanel.swift（直测见 RunnerInputBubbleHistoryPanelTests B318）。
// MARK: - 状态徽章（草稿=琥珀 / 已提交=珊瑚）

final class HistoryStatusBadge: NSView {
    var status: InputBubbleHistoryStatus

    init(status: InputBubbleHistoryStatus) {
        self.status = status
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let (label, color): (String, NSColor) = status == .draft
            ? ("草稿", NSColor(rgbHex: isDark ? 0xE8B04A : 0xC77E17))
            : ("已提交", NSColor(rgbHex: isDark ? 0xFF8266 : 0xE64A33))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: color
        ]
        let textSize = (label as NSString).size(withAttributes: attributes)
        let pill = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        color.withAlphaComponent(0.14).setFill()
        pill.fill()
        (label as NSString).draw(
            at: NSPoint(x: (bounds.width - textSize.width) / 2, y: (bounds.height - textSize.height) / 2),
            withAttributes: attributes
        )
    }
}

// MARK: - 迷你文字钮（复制 / 填充 / ✕）

final class HistoryMiniButton: NSView {
    // var：清空钮两段确认（B203）需要改标题；draw 每帧读现值
    var title: String
    var onClick: (() -> Void)?
    private var isPressed = false

    init(title: String, width: CGFloat) {
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 16))
    }

    required init?(coder: NSCoder) { nil }

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
        if wasPressed, bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let color = isPressed
            ? NSColor(rgbHex: isDark ? 0xFF8266 : 0xE64A33)
            : (isDark ? NSColor.white.withAlphaComponent(0.5) : NSColor(rgbHex: 0x8A7B68))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: color
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }
}

// MARK: - 历史行（头部徽章/时间/窗名 + 操作钮 + 预览或展开全文）

final class HistoryRowView: NSView {
    static let collapsedHeight: CGFloat = 56
    static let expandedExtraHeight: CGFloat = 230

    let entry: InputBubbleHistoryEntry
    let isExpanded: Bool
    var onToggleExpand: (() -> Void)?
    var onCopy: (() -> Void)?
    var onFill: (() -> Void)?
    var onDelete: (() -> Void)?

    private let badge = HistoryStatusBadge(status: .draft)  // frame 在 layout 里按状态定
    private let timeLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private let copyButton = HistoryMiniButton(title: "复制", width: 32)
    private let fillButton = HistoryMiniButton(title: "填充", width: 32)
    private let deleteButton = HistoryMiniButton(title: "✕", width: 16)
    private var expandedScroll: NSScrollView?

    init(entry: InputBubbleHistoryEntry, isExpanded: Bool, width: CGFloat) {
        self.entry = entry
        self.isExpanded = isExpanded
        let height = Self.height(isExpanded: isExpanded)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))

        badge.status = entry.status
        addSubview(badge)

        timeLabel.font = NSFont.systemFont(ofSize: 9.5)
        timeLabel.textColor = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgbHex: dark ? 0x8A7B68 : 0xA99A80)
        }
        timeLabel.stringValue = Self.timeText(for: entry.at)
        addSubview(timeLabel)

        titleLabel.font = NSFont.systemFont(ofSize: 9.5)
        titleLabel.textColor = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgbHex: dark ? 0x6E635A : 0xB9A98E)
        }
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.stringValue = entry.windowTitle ?? "未知窗口"
        addSubview(titleLabel)

        previewLabel.font = NSFont.systemFont(ofSize: 11.5)
        previewLabel.textColor = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgbHex: dark ? 0xF1E9DE : 0x40362B)
        }
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.stringValue = entry.text.replacingOccurrences(of: "\n", with: " ")
        addSubview(previewLabel)

        copyButton.onClick = { [weak self] in self?.onCopy?() }
        fillButton.onClick = { [weak self] in self?.onFill?() }
        deleteButton.onClick = { [weak self] in self?.onDelete?() }
        [copyButton, fillButton, deleteButton].forEach { addSubview($0) }

        if isExpanded {
            let scroll = NSScrollView(frame: .zero)
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.borderType = .lineBorder
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: width - 24, height: 100))
            text.string = entry.text
            text.font = NSFont.systemFont(ofSize: 11.5)
            text.isEditable = false
            text.drawsBackground = false
            text.textContainer?.widthTracksTextView = true
            text.textContainer?.containerSize = NSSize(width: width - 24, height: .greatestFiniteMagnitude)
            scroll.documentView = text
            expandedScroll = scroll
            addSubview(scroll)
        }
    }

    required init?(coder: NSCoder) { nil }

    static func height(isExpanded: Bool) -> CGFloat {
        collapsedHeight + (isExpanded ? expandedExtraHeight : 0)
    }

    static func timeText(for date: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if Calendar.current.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "MM-dd HH:mm"
        }
        return formatter.string(from: date)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let headerY = bounds.height - 22
        let badgeWidth: CGFloat = entry.status == .draft ? 34 : 46
        badge.frame = NSRect(x: 10, y: headerY + 1, width: badgeWidth, height: 14)
        timeLabel.frame = NSRect(x: badge.frame.maxX + 8, y: headerY + 1, width: 74, height: 14)
        deleteButton.frame = NSRect(x: w - 26, y: headerY, width: 16, height: 16)
        fillButton.frame = NSRect(x: deleteButton.frame.minX - 36, y: headerY, width: 32, height: 16)
        copyButton.frame = NSRect(x: fillButton.frame.minX - 36, y: headerY, width: 32, height: 16)
        titleLabel.frame = NSRect(
            x: timeLabel.frame.maxX + 6, y: headerY + 1,
            width: max(copyButton.frame.minX - timeLabel.frame.maxX - 12, 0), height: 14
        )
        previewLabel.frame = NSRect(x: 10, y: 8, width: w - 20, height: 15)
        expandedScroll?.frame = NSRect(x: 10, y: 28, width: w - 20, height: Self.expandedExtraHeight - 14)
    }

    // MARK: 命中分流：按钮/展开全文区各自接管，其余整行可点（展开/收起）

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for interactive in [copyButton, fillButton, deleteButton] {
            if interactive.bounds.contains(convert(local, to: interactive)) {
                return interactive
            }
        }
        if let expandedScroll, expandedScroll.bounds.contains(convert(local, to: expandedScroll)) {
            return expandedScroll
        }
        return self
    }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let background = isDark ? NSColor.white.withAlphaComponent(0.05) : NSColor.white.withAlphaComponent(0.55)
        let border = isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor(rgbHex: 0xE8DDCB).withAlphaComponent(0.7)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        background.setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        onToggleExpand?()
    }
}
