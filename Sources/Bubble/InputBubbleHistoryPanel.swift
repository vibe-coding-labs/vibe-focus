import AppKit
import Carbon

// MARK: - 输入历史面板（B196）
// 气泡底栏「历史」钮的落地页：草稿/已提交全量时间线。
// 产品定案（2026-09-17）：
// - 默认按气泡当前绑定窗过滤（本窗），可一键切「全部」；
// - 单击条目展开全文（长内容可滚动、可选中复制），再点收起；
// - 每条：复制（拷全文）/ 填充（回填气泡输入框）/ ✕（删除该条）；
// - 用例：提交注入失败的 BUG 再现时，来这里把文本捞回来。
// 样式沿用气泡卡片语系（奶油暖底 + 珊瑚强调，light/dark 动态）；手工 frame 布局，
// 状态变化整表重建（条目量 ≤ 容量 200，重建开销毫秒级，不做增量 diff）。

final class InputBubbleHistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

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
    let title: String
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

// MARK: - 面板控制器

@MainActor
final class InputBubbleHistoryPanelController: NSObject {
    static let shared = InputBubbleHistoryPanelController()

    private var panel: InputBubbleHistoryPanel?
    private var scope: InputBubbleHistoryFilter.Scope = .currentWindow
    private var currentWindowID: UInt32?
    private var fillHandler: ((String) -> Void)?
    private var expandedID: Date?
    private var listScroll: NSScrollView?
    private var countLabel: NSTextField?
    private var toastLabel: NSTextField?
    private var toastWorkItem: DispatchWorkItem?
    private var monitors: [Any] = []
    private let panelWidth: CGFloat = 460

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(anchorFrame: CGRect, currentWindowID: UInt32?, fill: @escaping (String) -> Void) {
        if isVisible {
            close()
            return
        }
        open(anchorFrame: anchorFrame, currentWindowID: currentWindowID, fill: fill)
    }

    func close() {
        removeMonitors()
        panel?.orderOut(nil)
        panel = nil
        listScroll = nil
        countLabel = nil
        toastLabel = nil
        expandedID = nil
        toastWorkItem?.cancel()
    }

    private func open(anchorFrame: CGRect, currentWindowID: UInt32?, fill: @escaping (String) -> Void) {
        self.currentWindowID = currentWindowID
        self.fillHandler = fill
        // 换窗唤起后面板重开：过滤目标跟随当前绑定点
        expandedID = nil

        let visibleFrame = containingVisibleFrame(of: anchorFrame)
        let height = min(panelWidth * 1.15, max(visibleFrame.height - 40, 300))
        let panel = InputBubbleHistoryPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: panelWidth, height: height)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar + 1
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let content = HistoryPanelContentView(frame: NSRect(origin: .zero, size: panel.frame.size))
        panel.contentView = content
        buildHeader(in: content, contentHeight: height)

        let scroll = NSScrollView(frame: NSRect(x: 8, y: 30, width: panelWidth - 16, height: height - 56 - 30 - 6))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        content.addSubview(scroll)
        listScroll = scroll

        panel.setFrameOrigin(origin(anchorFrame: anchorFrame, panelSize: panel.frame.size, visibleFrame: visibleFrame))
        self.panel = panel
        refresh()
        panel.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        installMonitors()
        log("[InputBubble] history panel opened", fields: [
            "scope": String(describing: scope),
            "currentWindowID": currentWindowID.map(String.init) ?? "nil"
        ])
    }

    // MARK: 头部（标题 + 提示 toast + ✕ + 过滤段 + 计数）

    private func buildHeader(in content: NSView, contentHeight: CGFloat) {
        let w = panelWidth
        let isDark = content.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let titleColor = NSColor(rgbHex: isDark ? 0xF1E9DE : 0x40362B)

        let title = NSTextField(labelWithString: "输入历史")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = titleColor
        title.frame = NSRect(x: 14, y: contentHeight - 28, width: 90, height: 18)
        content.addSubview(title)

        let toast = NSTextField(labelWithString: "")
        toast.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        toast.textColor = NSColor(rgbHex: isDark ? 0xFF8266 : 0xE64A33)
        toast.frame = NSRect(x: 108, y: contentHeight - 26, width: 160, height: 14)
        content.addSubview(toast)
        toastLabel = toast

        let closeButton = HistoryMiniButton(title: "✕", width: 20)
        closeButton.frame = NSRect(x: w - 32, y: contentHeight - 28, width: 20, height: 18)
        closeButton.onClick = { [weak self] in self?.close() }
        content.addSubview(closeButton)

        let segmented = NSSegmentedControl(
            labels: ["本窗", "全部"], trackingMode: .selectOne, target: self, action: #selector(scopeDidChange(_:))
        )
        segmented.selectedSegment = scope == .currentWindow ? 0 : 1
        segmented.frame = NSRect(x: 14, y: contentHeight - 54, width: 130, height: 22)
        content.addSubview(segmented)

        let count = NSTextField(labelWithString: "")
        count.font = NSFont.systemFont(ofSize: 10)
        count.textColor = NSColor(rgbHex: isDark ? 0x8A7B68 : 0xA99A80)
        count.frame = NSRect(x: 152, y: contentHeight - 50, width: w - 190, height: 14)
        content.addSubview(count)
        countLabel = count
    }

    @objc private func scopeDidChange(_ sender: NSSegmentedControl) {
        scope = sender.selectedSegment == 0 ? .currentWindow : .all
        expandedID = nil
        refresh()
    }

    // MARK: 列表整表重建

    private func refresh() {
        guard let listScroll else { return }
        let all = InputBubbleHistoryStore.shared.entries()
        let visible = InputBubbleHistoryFilter.select(all, scope: scope, currentWindowID: currentWindowID)
        countLabel?.stringValue = visible.isEmpty
            ? "暂无记录"
            : "\(visible.count) 条 · \(scope == .currentWindow ? "本窗" : "全部")"

        let contentWidth = listScroll.frame.width
        let rowWidth = contentWidth - 4
        let totalHeight = visible.reduce(0) { $0 + HistoryRowView.height(isExpanded: $1.at == expandedID) + 6 }
        let document = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: max(totalHeight + 4, listScroll.frame.height)))
        document.wantsLayer = true

        var y = document.frame.height
        for entry in visible {
            let expanded = entry.at == expandedID
            let rowHeight = HistoryRowView.height(isExpanded: expanded)
            y -= rowHeight + 6
            let row = HistoryRowView(entry: entry, isExpanded: expanded, width: rowWidth)
            row.frame.origin = NSPoint(x: 2, y: y + 3)
            row.onToggleExpand = { [weak self] in
                guard let self else { return }
                self.expandedID = self.expandedID == entry.at ? nil : entry.at
                self.refresh()
            }
            row.onCopy = { [weak self] in
                self?.copyToPasteboard(entry.text)
            }
            row.onFill = { [weak self] in
                self?.fill(entry.text)
            }
            row.onDelete = { [weak self] in
                InputBubbleHistoryStore.shared.remove(at: entry.at)
                if self?.expandedID == entry.at { self?.expandedID = nil }
                self?.refresh()
            }
            document.addSubview(row)
        }
        listScroll.documentView = document
        listScroll.reflectScrolledClipView(listScroll.contentView)
    }

    // MARK: 动作

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showToast("已复制全文 ✓")
        log("[InputBubble] history copied", fields: ["length": String(text.count)])
    }

    private func fill(_ text: String) {
        guard let fillHandler else {
            showToast("气泡已关闭，无法填充")
            return
        }
        fillHandler(text)
        close()
    }

    private func showToast(_ message: String) {
        toastLabel?.stringValue = message
        toastWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.toastLabel?.stringValue = ""
        }
        toastWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: item)
    }

    // MARK: 事件监视（Esc 关 / 点面板与气泡之外关）

    private func installMonitors() {
        removeMonitors()
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, event.keyCode == UInt16(kVK_Escape) else { return event }
            self.close()
            return nil
        }
        if let keyMonitor { monitors.append(keyMonitor) }
        let clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isVisible else { return event }
            // 点面板自身与气泡（含其历史钮）不关——气泡历史钮自持 toggle 语义
            if event.window !== self.panel, event.window !== InputBubbleController.shared.panel {
                self.close()
            }
            return event
        }
        if let clickMonitor { monitors.append(clickMonitor) }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    // MARK: 定位（锚气泡：先右后左，双轴夹进所在屏可视区）

    private func origin(anchorFrame: CGRect, panelSize: NSSize, visibleFrame: CGRect) -> NSPoint {
        let rightX = anchorFrame.maxX + 8
        let leftX = anchorFrame.minX - 8 - panelSize.width
        let x = rightX + panelSize.width <= visibleFrame.maxX
            ? rightX
            : max(min(leftX, visibleFrame.maxX - panelSize.width), visibleFrame.minX)
        let topY = anchorFrame.maxY - panelSize.height
        let y = min(max(topY, visibleFrame.minY + 8), visibleFrame.maxY - panelSize.height - 8)
        return NSPoint(x: x, y: y)
    }

    private func containingVisibleFrame(of anchorFrame: CGRect) -> CGRect {
        let center = CGPoint(x: anchorFrame.midX, y: anchorFrame.midY)
        let screen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? NSScreen.main
        return screen?.visibleFrame ?? anchorFrame
    }
}

// MARK: - 面板内容底（奶油暖底 + 圆角 + 描边，气泡卡片同款语系）

final class HistoryPanelContentView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = false
    }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let background = (isDark ? NSColor(rgbHex: 0x211C18) : NSColor(rgbHex: 0xF6F1E7)).withAlphaComponent(0.98)
        let border = isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor(rgbHex: 0xE8DDCB)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
        background.setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
