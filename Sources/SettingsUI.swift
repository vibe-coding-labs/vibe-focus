import SwiftUI
import AppKit
import Carbon
import ApplicationServices.HIServices
import CoreFoundation
import Foundation

private func bundledAppIconImage() -> NSImage? {
    if let icnsURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
       let image = NSImage(contentsOf: icnsURL) {
        return image
    }
    if let pngURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
       let image = NSImage(contentsOf: pngURL) {
        return image
    }
    return nil
}

private struct AppLogoBadge: View {
    var size: CGFloat = 84

    var body: some View {
        Group {
            if let image = bundledAppIconImage() {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "rectangle.3.group.bubble.left.fill")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.accentColor.opacity(0.98), Color.accentColor.opacity(0.72)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
    }
}

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
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.86))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
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
                RoundedRectangle(cornerRadius: 6, style: .continuous)
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
    @StateObject private var spaceController = SpaceController.shared
    @StateObject private var loginItemManager = LoginItemManager.shared
    @AppStorage(SpacePreferences.integrationEnabledKey) private var spaceIntegrationEnabled = true
    @AppStorage(SpacePreferences.restoreStrategyKey) private var restoreStrategyRaw = SpaceRestoreStrategy.switchToOriginal.rawValue
    @State private var duplicateAppPaths: [String] = []
    @State private var isCheckingInstallations = false

    private var appVersionDisplay: String {
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let version = (bundleVersion?.isEmpty == false) ? bundleVersion! : AppVersion.current
        return "v\(version)"
    }

    private var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.openai.vibe-focus"
    }

    private var loginItemSidebarValue: String {
        if loginItemManager.isEnabled {
            return "已启用"
        }
        if loginItemManager.requiresApproval {
            return "待确认"
        }
        return "未启用"
    }

    private var currentAppPath: String {
        Bundle.main.bundleURL.path
    }

    private var expectedAppPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Applications/VibeFocus.app")
    }

    private var otherInstallations: [String] {
        duplicateAppPaths.filter { $0 != currentAppPath }
    }

    private var resetAccessCommand: String {
        "tccutil reset Accessibility \(bundleIdentifier)"
    }

    private var spaceEffectiveEnabled: Bool {
        spaceIntegrationEnabled && spaceController.availability == .available
    }

    private var spaceStatusTitle: String {
        switch spaceController.availability {
        case .available:
            return "可用"
        case .notInstalled:
            return "未安装"
        case .unavailable:
            return "不可用"
        case .unknown:
            return "未检测"
        }
    }

    private var spaceStatusTint: Color {
        switch spaceController.availability {
        case .available:
            return .green
        case .notInstalled, .unknown:
            return .gray
        case .unavailable:
            return .orange
        }
    }

    private var spaceStatusDetail: String {
        switch spaceController.availability {
        case .available:
            return "检测到 yabai，可启用跨工作区移动。"
        case .notInstalled:
            return "未检测到 yabai，保持当前行为。"
        case .unavailable:
            return "yabai 未就绪，跨工作区不可用。"
        case .unknown:
            return "尚未检测 yabai 状态。"
        }
    }

    private var spaceSidebarValue: String {
        if spaceEffectiveEnabled {
            return "已启用"
        }
        if spaceIntegrationEnabled {
            switch spaceController.availability {
            case .notInstalled:
                return "未安装"
            case .unavailable:
                return "不可用"
            case .available:
                return "已关闭"
            case .unknown:
                return "未检测"
            }
        }
        return "已关闭"
    }

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

            GeometryReader { proxy in
                let inset: CGFloat = 28
                let contentWidth = max(0, proxy.size.width - inset * 2)
                let contentHeight = max(0, proxy.size.height - inset * 2)

                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 22) {
                    AppLogoBadge()

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
                        SidebarInfoCard(title: "版本", value: appVersionDisplay)
                        SidebarInfoCard(title: "当前快捷键", value: hotKeyManager.currentHotKey.displayString)
                        SidebarInfoCard(title: "辅助功能权限", value: hotKeyManager.accessibilityGranted ? "已授权" : "未授权")
                        SidebarInfoCard(title: "开机启动", value: loginItemSidebarValue)
                        SidebarInfoCard(title: "跨工作区", value: spaceSidebarValue)
                    }

                    if !hotKeyManager.accessibilityGranted {
                        Button("打开辅助功能设置") {
                            hotKeyManager.openAccessibilitySettings()
                        }
                        .buttonStyle(.link)
                    }
                }
                .padding(24)
                .frame(width: 236, height: contentHeight, alignment: .top)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.68))
                        .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.45), lineWidth: 1)
                            )
                    )
                    .shadow(color: .black.opacity(0.05), radius: 20, y: 12)

                    ScrollView {
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
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
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

                    SettingsCard(
                        title: "权限与授权",
                        subtitle: "用于确认当前实例是否已获得辅助功能权限，并提供快速跳转与修复指引。"
                    ) {
                        SettingsRow(
                            title: "辅助功能权限",
                            detail: hotKeyManager.accessibilityGranted
                                ? "系统已允许 VibeFocus 控制其他应用的窗口。"
                                : "未授权，快捷键会触发但窗口无法移动。"
                        ) {
                            HStack(spacing: 10) {
                                SettingsStatusPill(
                                    title: hotKeyManager.accessibilityGranted ? "已授权" : "未授权",
                                    tint: hotKeyManager.accessibilityGranted ? .green : .red
                                )

                                Button("重新检测") {
                                    hotKeyManager.refreshAccessibilityStatus()
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        Divider()

                        SettingsRow(
                            title: "快速操作",
                            detail: "如果系统显示已授权但这里仍未授权，通常是签名变化或多副本导致。"
                        ) {
                            HStack(spacing: 10) {
                                Button("打开辅助功能设置") {
                                    hotKeyManager.openAccessibilitySettings()
                                }
                                .buttonStyle(.borderedProminent)

                                Button("复制重置命令") {
                                    let pasteboard = NSPasteboard.general
                                    pasteboard.clearContents()
                                    pasteboard.setString(resetAccessCommand, forType: .string)
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        Text("重置命令需要在终端运行，执行后请重新打开 VibeFocus 再授权。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Divider()

                        SettingsRow(
                            title: "当前运行路径",
                            detail: currentAppPath
                        ) {
                            Button("在 Finder 中显示") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: currentAppPath)])
                            }
                            .buttonStyle(.bordered)
                        }

                        if currentAppPath != expectedAppPath {
                            Text("检测到非标准安装路径，建议仅保留：\(expectedAppPath)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Divider()

                        SettingsRow(
                            title: "安装位置检查",
                            detail: otherInstallations.isEmpty
                                ? "未检测到其他安装副本。"
                                : "检测到其他安装副本，建议只保留一个。"
                        ) {
                            HStack(spacing: 10) {
                                if isCheckingInstallations {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                }
                                Button("重新检测") {
                                    refreshInstallations()
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        if !otherInstallations.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("其他副本：")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(otherInstallations, id: \.self) { path in
                                    Text(path)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    SettingsCard(
                        title: "开机启动",
                        subtitle: "控制 VibeFocus 是否在登录后自动启动；如需确认或移除，可在系统设置中操作。"
                    ) {
                        SettingsRow(
                            title: "登录时启动",
                            detail: loginItemManager.statusDetail
                        ) {
                            HStack(spacing: 10) {
                                SettingsStatusPill(
                                    title: loginItemManager.statusTitle,
                                    tint: loginItemManager.isEnabled
                                        ? .green
                                        : (loginItemManager.requiresApproval ? .orange : Color.secondary)
                                )
                                Toggle("", isOn: Binding(
                                    get: { loginItemManager.isEnabled },
                                    set: { loginItemManager.setEnabled($0) }
                                ))
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                            }
                        }

                        if loginItemManager.requiresApproval {
                            Text("系统需要你在「系统设置 → 通用 → 登录项」中确认启用。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let error = loginItemManager.lastErrorMessage, !error.isEmpty {
                            Text("启用失败：\(error)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Divider()

                        SettingsRow(
                            title: "系统设置",
                            detail: "在登录项中确认或移除开机启动。"
                        ) {
                            HStack(spacing: 10) {
                                Button("打开登录项设置") {
                                    loginItemManager.openLoginItemsSettings()
                                }
                                .buttonStyle(.bordered)

                                Button("重新检测") {
                                    loginItemManager.refresh()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    SettingsCard(
                        title: "跨工作区（高级）",
                        subtitle: "检测到 yabai 后自动启用跨工作区移动；未安装或不可用时保持当前能力。"
                    ) {
                        SettingsRow(
                            title: "yabai 状态",
                            detail: spaceStatusDetail
                        ) {
                            HStack(spacing: 10) {
                                SettingsStatusPill(
                                    title: spaceStatusTitle,
                                    tint: spaceStatusTint
                                )

                                Button("重新检测") {
                                    spaceController.refreshAvailability(force: true)
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        if let error = spaceController.lastErrorMessage,
                           spaceController.availability == .unavailable,
                           !error.isEmpty {
                            Text("yabai 返回：\(error)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Divider()

                        SettingsRow(
                            title: "启用跨工作区",
                            detail: "默认开启，yabai 不可用时不会影响现有行为。"
                        ) {
                            Toggle("", isOn: $spaceIntegrationEnabled)
                                .labelsHidden()
                        }

                        Divider()

                        SettingsRow(
                            title: "恢复策略",
                            detail: "决定恢复窗口时是切回原工作区，还是把窗口拉到当前工作区。"
                        ) {
                            Picker("", selection: $restoreStrategyRaw) {
                                Text("切回原工作区").tag(SpaceRestoreStrategy.switchToOriginal.rawValue)
                                Text("拉到当前工作区").tag(SpaceRestoreStrategy.pullToCurrent.rawValue)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                        }
                    }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.visible)
                .frame(maxWidth: .infinity, maxHeight: contentHeight, alignment: .topLeading)
                }
                .frame(width: contentWidth, height: contentHeight, alignment: .top)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
        }
        .frame(minWidth: 820, idealWidth: 820, minHeight: 900, idealHeight: 900)
        .onAppear {
            spaceController.refreshAvailability(force: true)
            hotKeyManager.refreshAccessibilityStatus()
            loginItemManager.refresh()
            refreshInstallations()
        }
    }

    private func refreshInstallations() {
        guard !isCheckingInstallations else { return }
        isCheckingInstallations = true
        let bundleID = bundleIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            let paths = findAppBundlePaths(bundleIdentifier: bundleID)
            DispatchQueue.main.async {
                duplicateAppPaths = paths
                isCheckingInstallations = false
            }
        }
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
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "VibeFocus 设置"
        window.center()
        window.minSize = NSSize(width: 820, height: 900)
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
        if let icon = bundledAppIconImage() {
            NSApp.applicationIconImage = icon
            window.miniwindowImage = icon
        }
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
        logDiagnostics("launch")
        guard enforceExpectedInstallLocation() else {
            return
        }
        applyApplicationIcon()
        setupMenuBar()
        HotKeyManager.shared.setup()
        promptAccessibilityIfNeeded()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshMenuLabels),
            name: .hotKeyConfigurationDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button, let image = loadStatusBarImage() {
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
        } else {
            statusItem?.button?.title = "VibeFocus"
        }

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

    private func loadStatusBarImage() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "StatusBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
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

    @objc private func handleAppBecameActive() {
        applyApplicationIcon()
        HotKeyManager.shared.refreshAccessibilityStatus()
    }

    private func applyApplicationIcon() {
        guard let icon = bundledAppIconImage() else {
            return
        }
        NSApp.applicationIconImage = icon
    }

    private func expectedAppBundlePaths() -> [String] {
        let home = NSHomeDirectory()
        return [
            (home as NSString).appendingPathComponent("Applications/VibeFocus.app"),
            "/Applications/VibeFocus.app"
        ]
    }

    @discardableResult
    private func enforceExpectedInstallLocation() -> Bool {
        let actualURL = Bundle.main.bundleURL
        let actual = actualURL.path
        if actualURL.pathExtension != "app" {
            log("Skipping install-location enforcement for direct binary run: \(actual)")
            return true
        }

        let expectedPaths = expectedAppBundlePaths()
        guard !expectedPaths.contains(actual) else {
            return true
        }

        log("Unexpected app location. actual=\(actual) expected=\(expectedPaths)")
        logDiagnostics("unexpected_location")

        // Try to open existing copy if found
        for expected in expectedPaths {
            if FileManager.default.fileExists(atPath: expected) {
                NSWorkspace.shared.open(URL(fileURLWithPath: expected))
                break
            }
        }

        showWrongLocationAlert(actual: actual, expected: expectedPaths.first!)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
        return false
    }

    private func showWrongLocationAlert(actual: String, expected: String) {
        let alert = NSAlert()
        alert.messageText = "VibeFocus 安装位置异常"
        alert.informativeText = "当前运行位置：\n\(actual)\n\n建议位置：\n~\(expected)" +
            "\n或\n/Applications/VibeFocus.app"
        alert.addButton(withTitle: "退出")

        NSApp.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        alert.runModal()
        NSApp.setActivationPolicy(.accessory)
    }

    private func promptAccessibilityIfNeeded() {
        guard HotKeyManager.shared.accessibilityGranted == false else {
            return
        }
        log("Accessibility not granted; opening System Settings.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            HotKeyManager.shared.openAccessibilitySettings()
        }
    }
}
