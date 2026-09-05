// SettingsComponents+Shortcuts.swift
// VibeFocus — 快捷键录制和拖动滑块交互组件
// 从 SettingsComponents.swift 中提取

import AppKit
import Carbon
import SwiftUI

// MARK: - Shortcut Recorder Button

final class ShortcutRecorderButton: NSButton {
    var displayedShortcut = HotKeyConfiguration.default.displayString {
        didSet { updateAppearance() }
    }
    var onShortcutCaptured: ((HotKeyConfiguration) -> Void)?
    private var isRecording = false {
        didSet { updateAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupButton()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupButton()
    }

    private func setupButton() {
        wantsLayer = true
        isBordered = false
        updateAppearance()
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        let keyCode = event.keyCode
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Ignore lone modifier presses
        if modifiers.isDisjoint(with: [.shift, .control, .option, .command]) {
            super.keyDown(with: event)
            return
        }

        let config = HotKeyConfiguration(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers.rawValue))
        displayedShortcut = config.displayString
        onShortcutCaptured?(config)
        isRecording = false
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    private func updateAppearance() {
        let fontSize: CGFloat = 13
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)

        if isRecording {
            attributedTitle = NSAttributedString(
                string: "录制快捷键…",
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            )
            layer?.backgroundColor = VibeColors.accentNS.withAlphaComponent(0.12).cgColor
            layer?.cornerRadius = 6
        } else {
            attributedTitle = NSAttributedString(
                string: displayedShortcut,
                attributes: [.font: font, .foregroundColor: NSColor.labelColor]
            )
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.cornerRadius = 6
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
        }
        frame.size.height = 28
        needsDisplay = true
    }
}

// MARK: - ShortcutRecorderView (SwiftUI wrapper)

/// NSViewRepresentable wrapper for recording global keyboard shortcuts.
struct ShortcutRecorderView: NSViewRepresentable {
    var displayedShortcut: String
    var onShortcutCaptured: ((HotKeyConfiguration) -> Void)?

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.displayedShortcut = displayedShortcut
        button.onShortcutCaptured = onShortcutCaptured
        return button
    }

    func updateNSView(_ nsView: ShortcutRecorderButton, context: Context) {
        nsView.displayedShortcut = displayedShortcut
    }
}

// MARK: - Draggable Slider

/// 数值滑杆：SwiftUI Slider（跟随根视图品牌 tint），保留原 NSSlider 版的
/// 步进取整 + 范围钳制语义，调用方 API 不变。
struct DraggableSlider: View {
    var value: Binding<Double>
    var minValue: Double
    var maxValue: Double
    var step: Double

    var body: some View {
        Slider(
            value: Binding(
                get: { value.wrappedValue },
                set: { rawValue in
                    var newValue = rawValue
                    if step > 0 {
                        newValue = (newValue / step).rounded() * step
                    }
                    value.wrappedValue = max(minValue, min(maxValue, newValue))
                }
            ),
            in: minValue...maxValue
        )
    }
}
