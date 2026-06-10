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
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        } else {
            attributedTitle = NSAttributedString(
                string: displayedShortcut,
                attributes: [.font: font, .foregroundColor: NSColor.labelColor]
            )
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
        layer?.cornerRadius = 6
        frame.size.height = 28
        needsDisplay = true
    }
}

// MARK: - ShortcutRecorderView (SwiftUI wrapper)

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

struct DraggableSlider: NSViewRepresentable {
    var value: Binding<Double>
    var minValue: Double
    var maxValue: Double
    var step: Double

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value.wrappedValue,
                              minValue: minValue,
                              maxValue: maxValue,
                              target: context.coordinator,
                              action: #selector(Coordinator.valueChanged))
        slider.isContinuous = true
        slider.allowsTickMarkValuesOnly = false
        return slider
    }

    func updateNSView(_ nsView: NSSlider, context: Context) {
        nsView.doubleValue = value.wrappedValue
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator {
        var parent: DraggableSlider
        init(parent: DraggableSlider) { self.parent = parent }

        @objc func valueChanged(_ sender: NSSlider) {
            var newValue = sender.doubleValue
            if parent.step > 0 {
                newValue = round(newValue / parent.step) * parent.step
            }
            // Clamp to valid range
            newValue = max(parent.minValue, min(parent.maxValue, newValue))
            parent.value.wrappedValue = newValue
            sender.doubleValue = newValue
        }
    }
}
