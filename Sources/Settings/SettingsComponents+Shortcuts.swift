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

        // B165：裸 Esc 取消录制（设置页文案「按 Esc 可取消录制」的承诺兑现——
        // 此前 Esc 落进 NSButton 默认路径，录制态永不退出）。⌘ 等修饰组合的 Esc
        // 仍是可录制组合键，走下方正常捕获。
        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            window?.makeFirstResponder(nil)
            return
        }

        // B164：组合键必须经 from(event:) 做 NSEvent→Carbon 修饰位规范转换。旧实现
        // 直接塞 NSEvent.ModifierFlags.rawValue（⌘=1<<20），而 HotKeyConfiguration 的
        // 校验/匹配/展示全是 Carbon 位语义（⌘=1<<8）——校验必败 beep 回退，主开关/
        // 摆位/气泡三处录制自诞生起就没有生效过。
        guard let config = HotKeyConfiguration.from(event: event) else {
            // 纯修饰键到不了 keyDown（走 flagsChanged）；此处兜底未命名键与零修饰 keyDown
            super.keyDown(with: event)
            return
        }
        displayedShortcut = config.displayString
        onShortcutCaptured?(config)
        isRecording = false
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // VibeColors.cardNS/hairlineNS 的 .cgColor 是按当前外观一次性解析的静态色，
        // 系统亮暗切换时不会自动重解析，必须重设 layer 颜色
        updateAppearance()
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
            layer?.backgroundColor = VibeColors.cardNS.cgColor
            layer?.cornerRadius = 6
            layer?.borderWidth = 1
            layer?.borderColor = VibeColors.hairlineNS.cgColor
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
