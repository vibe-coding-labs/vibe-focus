import SwiftUI
import AppKit
import Carbon
import ApplicationServices.HIServices
import CoreFoundation
import Foundation

private final class ShortcutRecorderButton: NSButton {
    var displayedShortcut = HotKeyConfiguration.default.displayString {
        didSet { updateAppearance() }
    }
    var onShortcutCaptured: ((HotKeyConfiguration) -> Void)?
    private var isRecording = false {
        didSet { updateAppearance() }
    }

    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        controlSize = .large
        font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        target = self
        action = #selector(beginRecording)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func beginRecording() {
        isRecording = true
        NSApp.activate(ignoringOtherApps: true)
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self)
        }
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        isRecording = false
        return result
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            return
        }

        guard let hotKey = HotKeyConfiguration.from(event: event) else {
            NSSound.beep()
            return
        }

        onShortcutCaptured?(hotKey)
        isRecording = false
        window?.makeFirstResponder(nil)
    }

    private func updateAppearance() {
        title = isRecording ? "按下新的快捷键" : displayedShortcut
        contentTintColor = isRecording ? .controlAccentColor : .labelColor
    }
}

private struct ShortcutRecorderView: NSViewRepresentable {
    let displayedShortcut: String
    let onShortcutCaptured: (HotKeyConfiguration) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.displayedShortcut = displayedShortcut
        button.onShortcutCaptured = onShortcutCaptured
        return button
    }

    func updateNSView(_ nsView: ShortcutRecorderButton, context: Context) {
        nsView.displayedShortcut = displayedShortcut
        nsView.onShortcutCaptured = onShortcutCaptured
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.86))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.42), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.06), radius: 18, y: 10)
    }
}

private struct SettingsStatusPill: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.12))
            )
            .foregroundStyle(tint)
    }
}

private struct SidebarInfoCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsRow<Accessory: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            accessory
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var hotKeyManager: HotKeyManager

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .underPageBackgroundColor),
                    Color.accentColor.opacity(0.08)
                ],
                startPoint: .top,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 22) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.accentColor.opacity(0.98), Color.accentColor.opacity(0.72)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 84, height: 84)
                            .shadow(color: Color.accentColor.opacity(0.18), radius: 18, y: 8)

                        Image(systemName: "rectangle.3.group.bubble.left.fill")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("VibeFocus")
                            .font(.system(size: 30, weight: .semibold))
                        Text("菜单栏里的窗口流转工具")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("把全局快捷键、状态反馈和权限引导，收进一个更接近 macOS 原生偏好设置体验的面板里。")
                            .font(.system(size: 13))
                            .lineSpacing(3)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    SettingsStatusPill(
                        title: hotKeyManager.shortcutStatusIsError ? "需要处理" : "工作正常",
                        tint: hotKeyManager.shortcutStatusIsError ? .red : .green
                    )

                    VStack(alignment: .leading, spacing: 14) {
                        SidebarInfoCard(title: "菜单栏标题", value: "VibeFocus")
                        SidebarInfoCard(title: "当前快捷键", value: hotKeyManager.currentHotKey.displayString)
                        SidebarInfoCard(title: "辅助功能权限", value: hotKeyManager.accessibilityGranted ? "已授权" : "未授权")
                    }

                    if !hotKeyManager.accessibilityGranted {
                        Button("打开辅助功能设置") {
                            hotKeyManager.openAccessibilitySettings()
                        }
                        .buttonStyle(.link)
                    }

                    Spacer(minLength: 0)
                }
                .padding(24)
                .frame(width: 236, alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.68))
                        .overlay(
                            RoundedRectangle(cornerRadius: 26, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.45), lineWidth: 1)
                        )
                )
                .shadow(color: .black.opacity(0.05), radius: 20, y: 12)

                VStack(alignment: .leading, spacing: 20) {
                    SettingsCard(
                        title: "快捷键",
                        subtitle: "点击录制按钮后直接按下新组合键。修改后立即生效；如果命中常见系统快捷键会直接阻止。"
                    ) {
                        SettingsRow(
                            title: "当前快捷键",
                            detail: "全局热键与菜单栏 Toggle 会实时切换到这个组合。"
                        ) {
                            Text(hotKeyManager.currentHotKey.displayString)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color(nsColor: .controlBackgroundColor))
                                )
                        }

                        Divider()

                        HStack(spacing: 12) {
                            ShortcutRecorderView(displayedShortcut: hotKeyManager.currentHotKey.displayString) { hotKey in
                                hotKeyManager.applyShortcut(hotKey)
                            }
                            .frame(width: 220)

                            Button("恢复默认") {
                                hotKeyManager.resetToDefaultShortcut()
                            }
                            .buttonStyle(.bordered)

                            Spacer()
                        }

                        Text("默认快捷键：\(HotKeyConfiguration.default.displayString) · 按 Esc 可取消录制")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    SettingsCard(
                        title: "状态与提示",
                        subtitle: "把当前配置结果、权限状态和交互提示整合在一起，减少来回排查的成本。"
                    ) {
                        SettingsRow(
                            title: "当前状态",
                            detail: hotKeyManager.shortcutStatusMessage
                        ) {
                            SettingsStatusPill(
                                title: hotKeyManager.shortcutStatusIsError ? "冲突" : "正常",
                                tint: hotKeyManager.shortcutStatusIsError ? .red : .blue
                            )
                        }

                        Divider()

                        SettingsRow(
                            title: "交互说明",
                            detail: "设置窗现在会主动获取前台焦点，录制按钮被点击后会直接进入监听状态。"
                        ) {
                            Image(systemName: "keyboard")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(28)
        }
        .frame(width: 820, height: 520)
    }
}

@MainActor
private final class FocusableSettingsWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private init() {
        let hostingController = NSHostingController(
            rootView: SettingsView()
                .environmentObject(HotKeyManager.shared)
        )

        let window = FocusableSettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "VibeFocus 设置"
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace]
        window.tabbingMode = .disallowed
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.toolbarStyle = .unifiedCompact
        window.backgroundColor = .clear
        window.contentViewController = hostingController
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
            window.center()
            window.orderFrontRegardless()
            window.makeMain()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - 主程序
@main
struct VibeFocusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(HotKeyManager.shared)
        }
    }
}

// MARK: - App Delegate
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var toggleMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("applicationDidFinishLaunching bundle=\(Bundle.main.bundleIdentifier ?? "nil") path=\(Bundle.main.bundleURL.path)")
        setupMenuBar()
        HotKeyManager.shared.setup()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshMenuLabels),
            name: .hotKeyConfigurationDidChange,
            object: nil
        )
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "VibeFocus"

        let menu = NSMenu()
        let toggleItem = NSMenuItem(title: "", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        toggleMenuItem = toggleItem
        menu.addItem(toggleItem)

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        refreshMenuLabels()
    }

    @objc private func refreshMenuLabels() {
        toggleMenuItem?.title = "Toggle (\(HotKeyManager.shared.currentHotKey.displayString))"
    }

    @objc private func toggle() {
        WindowManager.shared.toggle()
    }

    @objc private func openSettings() {
        DispatchQueue.main.async {
            SettingsWindowController.shared.show()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

