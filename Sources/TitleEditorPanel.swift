import AppKit

// MARK: - Title Editor Panel
// 浮动无边框输入框，定位在目标终端窗口标题栏下方
@MainActor
class TitleEditorPanel: NSPanel {
    private let onSubmit: (String) -> Void
    private let onCancel: () -> Void
    private var textField: NSTextField!

    init(
        currentTitle: String,
        windowFrame: CGRect?,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSubmit = onSubmit
        self.onCancel = onCancel

        let panelWidth: CGFloat = 420
        let panelHeight: CGFloat = 40
        var origin: CGPoint
        if let frame = windowFrame {
            let titleBarHeight: CGFloat = 28
            origin = CGPoint(
                x: frame.midX - panelWidth / 2,
                y: frame.maxY - titleBarHeight - panelHeight - 4
            )
        } else if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            origin = CGPoint(
                x: screenFrame.midX - panelWidth / 2,
                y: screenFrame.maxY - 100
            )
        } else {
            origin = CGPoint(x: 100, y: 100)
        }

        let rect = NSRect(x: origin.x, y: origin.y, width: panelWidth, height: panelHeight)
        super.init(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.ignoresMouseEvents = false
        self.isReleasedWhenClosed = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        setupContent(currentTitle: currentTitle, panelWidth: panelWidth, panelHeight: panelHeight)
    }

    private func setupContent(currentTitle: String, panelWidth: CGFloat, panelHeight: CGFloat) {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        containerView.layer?.cornerRadius = 8
        containerView.layer?.borderWidth = 1.5
        containerView.layer?.borderColor = NSColor.selectedControlColor.cgColor

        textField = NSTextField(frame: NSRect(x: 10, y: 5, width: panelWidth - 20, height: panelHeight - 10))
        textField.stringValue = currentTitle
        textField.font = NSFont.systemFont(ofSize: 14)
        textField.drawsBackground = false
        textField.isBordered = false
        textField.focusRingType = .none
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.cell?.sendsActionOnEndEditing = false
        textField.delegate = self

        containerView.addSubview(textField)
        self.contentView = containerView
    }

    func show() {
        self.orderFrontRegardless()
        self.makeFirstResponder(textField)
        DispatchQueue.main.async { [weak self] in
            self?.textField.selectText(nil)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { // Return
            onSubmit(textField.stringValue)
            close()
        } else if event.keyCode == 53 { // Escape
            onCancel()
            close()
        } else {
            super.keyDown(with: event)
        }
    }
}

extension TitleEditorPanel: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onSubmit(textField.stringValue)
            close()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel()
            close()
            return true
        }
        return false
    }
}
