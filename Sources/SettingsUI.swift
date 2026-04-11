import SwiftUI
import AppKit
import Carbon
import ApplicationServices.HIServices
import CoreFoundation
import Foundation
import Darwin

func bundledAppIconImage() -> NSImage? {
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
        log("[Settings] shortcut recorder begin recording")
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
        log("[Settings] shortcut recorder resigned first responder")
        return result
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            log("[Settings] shortcut recorder canceled by Esc")
            return
        }

        guard let hotKey = HotKeyConfiguration.from(event: event) else {
            NSSound.beep()
            log(
                "[Settings] shortcut recorder rejected input",
                level: .warn,
                fields: [
                    "keyCode": String(event.keyCode),
                    "modifiers": String(event.modifierFlags.rawValue)
                ]
            )
            return
        }

        log(
            "[Settings] shortcut recorder captured",
            fields: [
                "key": hotKey.displayString,
                "keyCode": String(hotKey.keyCode),
                "modifiers": String(hotKey.modifiers)
            ]
        )
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

// MARK: - Draggable Slider
// 使用 NSSlider 包装器实现真正的拖动功能
struct DraggableSlider: NSViewRepresentable {
    @Binding var value: Double
    var minValue: Double
    var maxValue: Double
    var step: Double

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider()
        slider.minValue = minValue
        slider.maxValue = maxValue
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        slider.isContinuous = true  // 关键：启用连续更新

        // 使用闭包来处理值变化
        let coordinator = context.coordinator
        slider.target = coordinator
        slider.action = #selector(Coordinator.sliderValueChanged(_:))

        return slider
    }

    func updateNSView(_ nsView: NSSlider, context: Context) {
        // 只在值显著不同时更新，避免覆盖用户拖动
        if abs(nsView.doubleValue - value) > 0.01 {
            nsView.doubleValue = value
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    class Coordinator: NSObject {
        var parent: DraggableSlider

        init(_ parent: DraggableSlider) {
            self.parent = parent
        }

        @objc func sliderValueChanged(_ sender: NSSlider) {
            let newValue = sender.doubleValue

            var finalValue = newValue
            // 应用步进
            if self.parent.step > 0 {
                finalValue = round(newValue / self.parent.step) * self.parent.step
            }
            // 限制范围
            finalValue = max(self.parent.minValue, min(self.parent.maxValue, finalValue))
            self.parent.value = finalValue
        }
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

// MARK: - Code Block View
private struct CodeBlockView: View {
    let code: String
    let language: String
    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(language)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.1))
                    )

                Spacer()

                Button(action: copyToClipboard) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        Text(isCopied ? "已复制" : "复制")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isCopied ? .green : .accentColor)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(2)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                )
        )
    }

    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)

        withAnimation {
            isCopied = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                isCopied = false
            }
        }
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
    @StateObject private var overlayManager = ScreenOverlayManager.shared
    @AppStorage(SpacePreferences.integrationEnabledKey) private var spaceIntegrationEnabled = true
    @AppStorage(SpacePreferences.restoreStrategyKey) private var restoreStrategyRaw = SpaceRestoreStrategy.switchToOriginal.rawValue
    @State private var duplicateAppPaths: [String] = []
    @State private var isCheckingInstallations = false

    // Claude Hook 集成
    @StateObject private var hookServer = ClaudeHookServer.shared
    @StateObject private var sessionRegistry = SessionWindowRegistry.shared
    @AppStorage(ClaudeHookPreferences.enabledKey) private var hookEnabled = false
    @AppStorage(ClaudeHookPreferences.portKey) private var hookPort = ClaudeHookPreferences.defaultPort
    @AppStorage(ClaudeHookPreferences.tokenKey) private var hookToken = ""
    @AppStorage(ClaudeHookPreferences.autoFocusOnSessionEndKey) private var autoFocusOnSessionEnd = true
    @AppStorage(ClaudeHookPreferences.triggerOnStopKey) private var triggerOnStop = true
    @AppStorage(ClaudeHookPreferences.triggerOnSessionEndKey) private var triggerOnSessionEnd = false
    @State private var hookInstallMessage: String?
    @State private var hookInstallSucceeded = false

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
            return "未检测到 yabai。安装后可启用跨工作区移动功能。"
        case .unavailable:
            return "yabai 已安装但未就绪（可能需要配置 SIP 或授予权限）。"
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
                        SidebarInfoCard(title: "Claude Hook", value: hookServer.isRunning ? "运行中" : (hookEnabled ? "已关闭" : "未启用"))
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
                            VStack(alignment: .leading, spacing: 12) {
                                Text("检测到其他副本（建议删除，只保留当前运行的版本）：")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(otherInstallations, id: \.self) { (path: String) in
                                    HStack(spacing: 10) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.orange)
                                            .font(.system(size: 10))
                                        Text(path)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                        Spacer()
                                        HStack(spacing: 6) {
                                            Button("Finder") {
                                                showDuplicateInFinder(path: path)
                                            }
                                            .buttonStyle(.borderless)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.blue)
                                            Button("删除") {
                                                moveDuplicateToTrash(path: path)
                                            }
                                            .buttonStyle(.borderless)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.red)
                                        }
                                    }
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.orange.opacity(0.08))
                                    )
                                }
                                HStack {
                                    Spacer()
                                    Button("全部删除") {
                                        moveAllDuplicatesToTrash()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .foregroundStyle(.red)
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

                        if spaceController.availability == .notInstalled {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("安装 yabai 可启用跨工作区移动功能：")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)

                                CodeBlockView(
                                    code: "brew install koekeishiya/formulae/yabai",
                                    language: "bash"
                                )

                                CodeBlockView(
                                    code: "brew services start yabai",
                                    language: "bash"
                                )

                                HStack(spacing: 12) {
                                    Button("查看完整指南") {
                                        if let url = URL(string: "https://github.com/CC11001100/vibe-focus/blob/main/docs/yabai-guide/README.md") {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button("验证安装") {
                                        spaceController.refreshAvailability(force: true)
                                    }
                                    .buttonStyle(.bordered)
                                }

                                Text("安装完成后点击「验证安装」按钮，或重新打开设置窗口。")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if spaceController.availability == .unavailable {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("yabai 需要系统权限才能正常工作。请确保：")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Text("1. 在「系统设置 → 隐私与安全 → 辅助功能」中允许 yabai")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Text("2. 如果启用了 SIP，需要额外配置（详见 yabai 文档）")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)

                                Button("打开 yabai 文档") {
                                    if let url = URL(string: "https://github.com/koekeishiya/yabai/wiki/Configuration#macos-version-compatibility") {
                                        NSWorkspace.shared.open(url)
                                    }
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

                            Button("加载 scripting-addition") {
                                spaceController.requestScriptingAdditionLoad()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
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

                    SettingsCard(
                        title: "Claude Code 集成",
                        subtitle: "对话完成时自动将终端窗口拉回主屏幕。安装 Hook 后，Claude Code 会直接通知 VibeFocus。"
                    ) {
                        // === 服务开关 ===
                        SettingsRow(
                            title: "Hook 服务",
                            detail: hookServer.isRunning ? hookServer.statusDescription : "未启动"
                        ) {
                            HStack(spacing: 10) {
                                SettingsStatusPill(
                                    title: hookServer.isRunning ? "运行中" : "未启动",
                                    tint: hookServer.isRunning ? .green : .gray
                                )
                                Toggle("", isOn: Binding(
                                    get: { hookEnabled },
                                    set: { newValue in
                                        hookEnabled = newValue
                                        ClaudeHookPreferences.isEnabled = newValue
                                        hookServer.applyPreferences()
                                    }
                                ))
                                .labelsHidden()
                            }
                        }

                        Divider()

                        // === Hook 安装 ===
                        SettingsRow(
                            title: "Hook 安装状态",
                            detail: ClaudeHookPreferences.isHookInstalled
                                ? "已安装到 ~/.claude/settings.json"
                                : "尚未安装"
                        ) {
                            SettingsStatusPill(
                                title: ClaudeHookPreferences.isHookInstalled ? "已安装" : "未安装",
                                tint: ClaudeHookPreferences.isHookInstalled ? .green : .orange
                            )
                        }

                        HStack(spacing: 12) {
                            Button(ClaudeHookPreferences.isHookInstalled ? "重新安装" : "一键安装 Hook") {
                                let (ok, msg) = ClaudeHookPreferences.installHookToClaudeSettings()
                                hookInstallSucceeded = ok
                                hookInstallMessage = msg
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!hookEnabled)

                            if ClaudeHookPreferences.isHookInstalled {
                                Button("卸载") {
                                    let (ok, msg) = ClaudeHookPreferences.uninstallHookFromClaudeSettings()
                                    hookInstallSucceeded = ok
                                    hookInstallMessage = msg
                                }
                                .buttonStyle(.bordered)
                                .foregroundStyle(.red)
                            }

                            Button("复制配置 JSON") {
                                let json = ClaudeHookPreferences.generateHooksJSON()
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString(json, forType: .string)
                                hookInstallMessage = "已复制到剪贴板"
                                hookInstallSucceeded = true
                            }
                            .buttonStyle(.bordered)

                            Spacer()
                        }

                        if let msg = hookInstallMessage {
                            Text(msg)
                                .font(.system(size: 12))
                                .foregroundStyle(hookInstallSucceeded ? .green : .red)
                        }

                        Divider()

                        // === 触发时机 ===
                        SettingsRow(title: "触发时机", detail: "选择何时自动将终端窗口拉回主屏幕") {
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle("对话完成（Stop 事件，推荐）", isOn: Binding(
                                    get: { triggerOnStop },
                                    set: { newValue in triggerOnStop = newValue; ClaudeHookPreferences.triggerOnStop = newValue }
                                ))
                                .toggleStyle(.checkbox)

                                Toggle("会话结束（SessionEnd 事件）", isOn: Binding(
                                    get: { triggerOnSessionEnd },
                                    set: { newValue in triggerOnSessionEnd = newValue; ClaudeHookPreferences.triggerOnSessionEnd = newValue }
                                ))
                                .toggleStyle(.checkbox)
                            }
                        }

                        Text("Stop：每次 Claude 回复完成后触发。SessionEnd：Claude 进程退出时触发。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)

                        Divider()

                        // === 端口和 Token ===
                        SettingsRow(
                            title: "监听端口",
                            detail: "默认 \(ClaudeHookPreferences.defaultPort)"
                        ) {
                            TextField("", value: Binding(
                                get: { hookPort },
                                set: { newValue in
                                    let clamped = max(1024, min(65535, newValue == 0 ? ClaudeHookPreferences.defaultPort : newValue))
                                    hookPort = clamped
                                    ClaudeHookPreferences.listenPort = clamped
                                    if hookEnabled { hookServer.applyPreferences() }
                                }
                            ), formatter: {
                                let f = NumberFormatter(); f.numberStyle = .none; f.minimum = 1024; f.maximum = 65535; return f
                            }())
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        }

                        SettingsRow(title: "鉴权 Token（可选）", detail: "启用后请求需携带 X-VibeFocus-Token 头") {
                            HStack(spacing: 8) {
                                SecureField("", text: Binding(
                                    get: { hookToken },
                                    set: { newValue in
                                        hookToken = newValue
                                        ClaudeHookPreferences.authToken = newValue.isEmpty ? nil : newValue
                                        if hookEnabled { hookServer.applyPreferences() }
                                    }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)

                                if hookToken.isEmpty {
                                    Button("随机生成") {
                                        hookToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).lowercased()
                                        ClaudeHookPreferences.authToken = hookToken
                                        if hookEnabled { hookServer.applyPreferences() }
                                    }
                                    .buttonStyle(.borderless)
                                    .font(.system(size: 11))
                                }
                            }
                        }

                        Divider()

                        // === 运行状态 ===
                        SettingsRow(title: "运行状态", detail: sessionRegistry.lastEventDescription) {
                            VStack(alignment: .trailing, spacing: 4) {
                                if let lastEvent = hookServer.lastEventAt {
                                    Text("最近事件 \(lastEvent, style: .time)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Text("已处理 \(hookServer.handledRequestCount) / 总计 \(hookServer.totalRequestCount) / 未匹配 \(hookServer.unmatchedSessionCount)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let error = hookServer.lastErrorMessage, !error.isEmpty {
                            Text("错误：\(error)")
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Divider()

                        // === 活跃会话列表 ===
                        if !sessionRegistry.activeBindingsForUI.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("活跃会话（\(sessionRegistry.activeBindingCount)）")
                                    .font(.system(size: 13, weight: .medium))

                                ForEach(sessionRegistry.activeBindingsForUI.prefix(5), id: \.sessionID) { binding in
                                    HStack(spacing: 8) {
                                        Image(systemName: "terminal")
                                            .foregroundStyle(.secondary)
                                            .font(.system(size: 11))
                                        Text(binding.windowIdentity.appName ?? "Unknown")
                                            .font(.system(size: 12, weight: .medium))
                                        Text(binding.windowIdentity.title ?? "Untitled")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        Text(binding.sessionID.prefix(8))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                }

                                if sessionRegistry.activeBindingsForUI.count > 5 {
                                    Text("还有 \(sessionRegistry.activeBindingsForUI.count - 5) 个...")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }

                        // === 已完成会话列表 ===
                        if !sessionRegistry.recentCompletedBindings.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("最近完成（\(sessionRegistry.completedBindingCount)）")
                                    .font(.system(size: 13, weight: .medium))

                                ForEach(sessionRegistry.recentCompletedBindings.prefix(3), id: \.sessionID) { binding in
                                    HStack(spacing: 8) {
                                        Image(systemName: "checkmark.circle")
                                            .foregroundStyle(.green)
                                            .font(.system(size: 11))
                                        Text(binding.windowIdentity.appName ?? "Unknown")
                                            .font(.system(size: 12, weight: .medium))
                                        if let completedAt = binding.completedAt {
                                            Text(completedAt, style: .time)
                                                .font(.system(size: 11))
                                                .foregroundStyle(.tertiary)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                }
                            }
                        }

                        Divider()

                        // === 操作按钮 ===
                        HStack(spacing: 12) {
                            Button("发送测试事件") {
                                sendTestHookEvent()
                            }
                            .buttonStyle(.bordered)
                            .disabled(!hookEnabled || !hookServer.isRunning)

                            Button("清除绑定") {
                                sessionRegistry.clearAllBindings()
                            }
                            .buttonStyle(.bordered)
                            .foregroundStyle(.red)

                            Spacer()
                        }

                        Text("测试：SessionStart 绑定当前窗口 → 1 秒后 SessionEnd 触发移动")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    SettingsCard(
                        title: "屏幕序号显示",
                        subtitle: "在每个屏幕上显示编号标签，方便识别多屏幕环境。"
                    ) {
                        SettingsRow(
                            title: "启用屏幕序号",
                            detail: "在屏幕上显示编号标签"
                        ) {
                            Toggle("", isOn: Binding(
                                get: { overlayManager.preferences.isEnabled },
                                set: { overlayManager.setEnabled($0) }
                            ))
                            .labelsHidden()
                        }

                        if overlayManager.preferences.isEnabled {
                            Divider()

                            // yabai 状态提示
                            HStack(spacing: 8) {
                                Image(systemName: spaceController.isEnabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundColor(spaceController.isEnabled ? .green : .orange)
                                    .font(.system(size: 14))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(spaceController.isEnabled ? "已检测到 yabai" : "未检测到 yabai")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(spaceController.isEnabled ? .green : .orange)

                                    Text(spaceController.isEnabled
                                        ? "将显示完整索引（如 1-0, 1-2），表示「屏幕-工作区」"
                                        : "仅显示屏幕索引（如 0, 1）。安装 yabai 后可显示工作区索引"
                                    )
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                }

                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)

                            if !spaceController.isEnabled {
                                Divider()

                                HStack(spacing: 8) {
                                    Image(systemName: "info.circle")
                                        .foregroundColor(.secondary)
                                        .font(.system(size: 12))

                                    Text("请先添加 yabai: brew tap koekeishiya/formulae && brew install yabai")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 4)
                            }

                            Divider()

                            // 工作区索引模式（固定屏幕级别）
                            SettingsRow(
                                title: "工作区编号模式",
                                detail: "固定使用屏幕级别编号：每个屏幕都从 1 开始（如 1-1, 1-2；2-1, 2-2）"
                            ) {
                                Text("屏幕级别（固定）")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.secondary.opacity(0.12))
                                    .clipShape(Capsule())
                            }

                            Divider()

                            SettingsRow(
                                title: "显示位置",
                                detail: "选择序号标签在屏幕上的显示位置"
                            ) {
                                Picker("", selection: Binding(
                                    get: { overlayManager.preferences.position },
                                    set: { overlayManager.updatePosition($0) }
                                )) {
                                    ForEach(IndexPosition.allCases, id: \.self) { position in
                                        HStack(spacing: 4) {
                                            Image(systemName: position.icon)
                                            Text(position.displayName)
                                        }
                                        .tag(position)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 140)
                            }

                            Divider()

                            SettingsRow(
                                title: "字体大小",
                                detail: "调整序号显示的大小"
                            ) {
                                HStack(spacing: 8) {
                                    DraggableSlider(
                                        value: Binding(
                                            get: { Double(overlayManager.preferences.fontSize) },
                                            set: { newValue in
                                                var prefs = overlayManager.preferences
                                                prefs.fontSize = CGFloat(newValue)
                                                overlayManager.preferences = prefs
                                            }
                                        ),
                                        minValue: 24,
                                        maxValue: 72,
                                        step: 4
                                    )
                                    .frame(width: 120)

                                    Text("\(Int(overlayManager.preferences.fontSize))")
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 30)
                                }
                            }

                            Divider()

                            SettingsRow(
                                title: "背景透明度",
                                detail: "调整序号标签背景的透明程度"
                            ) {
                                HStack(spacing: 8) {
                                    DraggableSlider(
                                        value: Binding(
                                            get: { Double(overlayManager.preferences.opacity) },
                                            set: { newValue in
                                                var prefs = overlayManager.preferences
                                                prefs.opacity = CGFloat(newValue)
                                                overlayManager.preferences = prefs
                                            }
                                        ),
                                        minValue: 0.3,
                                        maxValue: 1.0,
                                        step: 0.1
                                    )
                                    .frame(width: 120)

                                    Text("\(Int(overlayManager.preferences.opacity * 100))%")
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 40)
                                }
                            }

                            Divider()

                            SettingsRow(
                                title: "面板大小",
                                detail: "调整索引面板的整体缩放比例"
                            ) {
                                HStack(spacing: 8) {
                                    DraggableSlider(
                                        value: Binding(
                                            get: { Double(overlayManager.preferences.panelScale) },
                                            set: { newValue in
                                                var prefs = overlayManager.preferences
                                                prefs.panelScale = CGFloat(newValue)
                                                overlayManager.preferences = prefs
                                            }
                                        ),
                                        minValue: 0.5,
                                        maxValue: 2.0,
                                        step: 0.1
                                    )
                                    .frame(width: 120)

                                    Text("\(String(format: "%.1f", overlayManager.preferences.panelScale))x")
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 40)
                                }
                            }

                            Divider()

                            SettingsRow(
                                title: "面板边距",
                                detail: "调整索引面板距离屏幕边缘的间距"
                            ) {
                                HStack(spacing: 8) {
                                    DraggableSlider(
                                        value: Binding(
                                            get: { Double(overlayManager.preferences.panelMargin) },
                                            set: { newValue in
                                                var prefs = overlayManager.preferences
                                                prefs.panelMargin = CGFloat(newValue)
                                                overlayManager.preferences = prefs
                                            }
                                        ),
                                        minValue: 0,
                                        maxValue: 120,
                                        step: 2
                                    )
                                    .frame(width: 120)

                                    Text("\(Int(overlayManager.preferences.panelMargin))")
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 30)
                                }
                            }

                            Divider()

                            SettingsRow(
                                title: "文字颜色",
                                detail: "选择序号文字的颜色"
                            ) {
                                ColorPicker("",
                                    selection: Binding(
                                        get: { overlayManager.preferences.textColor.swiftUIColor },
                                        set: { newValue in
                                            var prefs = overlayManager.preferences
                                            prefs.textColor = CodableColor(newValue)
                                            overlayManager.preferences = prefs
                                        }
                                    )
                                )
                                .labelsHidden()
                                .frame(width: 60)
                            }

                            Divider()

                            SettingsRow(
                                title: "背景颜色",
                                detail: "选择索引面板的背景颜色"
                            ) {
                                ColorPicker("",
                                    selection: Binding(
                                        get: { overlayManager.preferences.backgroundColor.swiftUIColor },
                                        set: { newValue in
                                            var prefs = overlayManager.preferences
                                            prefs.backgroundColor = CodableColor(newValue)
                                            overlayManager.preferences = prefs
                                        }
                                    )
                                )
                                .labelsHidden()
                                .frame(width: 60)
                            }

                            Divider()

                            HStack(spacing: 12) {
                                Text("示例预览：")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)

                                Text(spaceController.isEnabled ? "1-1" : "1")
                                    .font(.system(size: overlayManager.preferences.fontSize * overlayManager.preferences.panelScale, weight: .bold))
                                    .foregroundColor(overlayManager.preferences.textColor.swiftUIColor)
                                    .padding(.horizontal, 16 * overlayManager.preferences.panelScale)
                                    .padding(.vertical, 8 * overlayManager.preferences.panelScale)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(overlayManager.preferences.backgroundColor.swiftUIColor.opacity(overlayManager.preferences.opacity))
                                    )

                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
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
        .frame(minWidth: 556, idealWidth: 556, minHeight: 900, idealHeight: 900)
        .onAppear {
            let startedAt = Date()
            log("[Settings] view onAppear start")
            spaceController.refreshAvailability(force: true)
            hotKeyManager.refreshAccessibilityStatus()
            loginItemManager.refresh()
            refreshInstallations()
            logOperationDuration(
                "[Settings] view onAppear finished",
                startedAt: startedAt,
                warnThresholdMs: 300,
                fields: [
                    "spaceAvailability": spaceController.availability.rawValue,
                    "axTrusted": String(hotKeyManager.accessibilityGranted),
                    "loginItemEnabled": String(loginItemManager.isEnabled)
                ]
            )
        }
        .onChange(of: spaceIntegrationEnabled) { newValue in
            log(
                "[Settings] space integration toggled",
                fields: [
                    "enabled": String(newValue),
                    "availability": spaceController.availability.rawValue
                ]
            )
        }
        .onChange(of: restoreStrategyRaw) { newValue in
            log(
                "[Settings] restore strategy changed",
                fields: [
                    "strategy": newValue
                ]
            )
        }
        .onChange(of: hookEnabled) { newValue in
            log(
                "[Settings] hook enabled toggled",
                fields: [
                    "enabled": String(newValue),
                    "isRunning": String(hookServer.isRunning)
                ]
            )
        }
        .onChange(of: hookPort) { newValue in
            log(
                "[Settings] hook port changed",
                fields: [
                    "port": String(newValue)
                ]
            )
        }
        .onChange(of: hookToken) { newValue in
            log(
                "[Settings] hook token changed",
                fields: [
                    "hasToken": String(!newValue.isEmpty)
                ]
            )
        }
    }

    private func refreshInstallations() {
        guard !isCheckingInstallations else { return }
        isCheckingInstallations = true
        let bundleID = bundleIdentifier
        let startedAt = Date()
        log(
            "[Settings] refresh installations start",
            fields: [
                "bundleID": bundleID
            ]
        )
        DispatchQueue.global(qos: .userInitiated).async {
            let paths = findAppBundlePaths(bundleIdentifier: bundleID)
            DispatchQueue.main.async {
                duplicateAppPaths = paths
                isCheckingInstallations = false
                logOperationDuration(
                    "[Settings] refresh installations finished",
                    startedAt: startedAt,
                    warnThresholdMs: 250,
                    fields: [
                        "bundleID": bundleID,
                        "foundCount": String(paths.count)
                    ]
                )
            }
        }
    }

    private func showDuplicateInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func moveDuplicateToTrash(path: String) {
        let alert = NSAlert()
        alert.messageText = "确认删除"
        alert.informativeText = "确定要将以下应用移到废纸篓吗？\n\n\(path)\n\n此操作不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            log("Moved duplicate to trash: \(path)")
            refreshInstallations()
        } catch {
            let errorAlert = NSAlert()
            errorAlert.messageText = "删除失败"
            errorAlert.informativeText = "无法移到废纸篓：\(error.localizedDescription)"
            errorAlert.alertStyle = .critical
            errorAlert.addButton(withTitle: "确定")
            errorAlert.runModal()
        }
    }

    private func moveAllDuplicatesToTrash() {
        let pathsToDelete = otherInstallations
        guard !pathsToDelete.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "确认批量删除"
        alert.informativeText = "确定要将以下 \(pathsToDelete.count) 个副本全部移到废纸篓吗？\n\n此操作不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "全部移到废纸篓")
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        var failedPaths: [String] = []
        for path in pathsToDelete {
            do {
                let url = URL(fileURLWithPath: path)
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                log("Moved duplicate to trash: \(path)")
            } catch {
                failedPaths.append(path)
            }
        }

        refreshInstallations()

        if !failedPaths.isEmpty {
            let errorAlert = NSAlert()
            errorAlert.messageText = "部分删除失败"
            errorAlert.informativeText = "以下 \(failedPaths.count) 个副本未能删除：\n\n\(failedPaths.joined(separator: "\n"))"
            errorAlert.alertStyle = .warning
            errorAlert.addButton(withTitle: "确定")
            errorAlert.runModal()
        }
    }

    // MARK: - Claude Hook Test Helpers

    private func sendTestHookEvent() {
        let port = hookPort
        let testSessionID = "test-\(UUID().uuidString.prefix(8))"
        let token = hookToken.isEmpty ? nil : hookToken

        log(
            "[Settings] sending test SessionStart event",
            fields: [
                "sessionID": testSessionID,
                "port": String(port),
                "hasToken": String(token != nil)
            ]
        )

        Self.sendHookRequest(
            port: port,
            endpoint: ClaudeHookPreferences.endpointPath,
            payload: [
                "event": "SessionStart",
                "session_id": testSessionID,
                "source": "test-ui"
            ],
            token: token
        ) { result in
            switch result {
            case .success(let data):
                log(
                    "[Settings] test SessionStart response",
                    fields: [
                        "sessionID": testSessionID,
                        "response": String(data: data, encoding: .utf8) ?? "nil"
                    ]
                )
                // 1 秒后发送 SessionEnd
                let endPort = port
                let endToken = token
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    log(
                        "[Settings] sending test SessionEnd event",
                        fields: [
                            "sessionID": testSessionID,
                            "port": String(endPort)
                        ]
                    )
                    Self.sendHookRequest(
                        port: endPort,
                        endpoint: ClaudeHookPreferences.endpointPath,
                        payload: [
                            "event": "SessionEnd",
                            "session_id": testSessionID,
                            "source": "test-ui"
                        ],
                        token: endToken
                    ) { endResult in
                        switch endResult {
                        case .success(let endData):
                            log(
                                "[Settings] test SessionEnd response",
                                fields: [
                                    "sessionID": testSessionID,
                                    "response": String(data: endData, encoding: .utf8) ?? "nil"
                                ]
                            )
                        case .failure(let endError):
                            log(
                                "[Settings] test SessionEnd failed",
                                level: .error,
                                fields: [
                                    "sessionID": testSessionID,
                                    "error": endError.localizedDescription
                                ]
                            )
                        }
                    }
                }
            case .failure(let error):
                log(
                    "[Settings] test SessionStart failed",
                    level: .error,
                    fields: [
                        "sessionID": testSessionID,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    private static func sendHookRequest(
        port: Int,
        endpoint: String,
        payload: [String: String],
        token: String?,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(endpoint)") else {
            completion(.failure(NSError(domain: "VibeFocus", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5

        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-VibeFocus-Token")
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(.failure(error))
            return
        }

        log(
            "[Settings] sending HTTP request",
            fields: [
                "url": url.absoluteString,
                "payload": String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "nil"
            ]
        )

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(NSError(domain: "VibeFocus", code: -2, userInfo: [NSLocalizedDescriptionKey: "Not HTTP response"])))
                return
            }
            log(
                "[Settings] HTTP response received",
                fields: [
                    "statusCode": String(httpResponse.statusCode),
                    "url": url.absoluteString
                ]
            )
            if httpResponse.statusCode >= 400 {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "nil"
                completion(.failure(NSError(
                    domain: "VibeFocus",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode): \(body)"]
                )))
                return
            }
            completion(.success(data ?? Data()))
        }
        task.resume()
    }
}

@MainActor
private final class FocusableSettingsWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
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

    func show(shouldFocus: Bool = true) {
        guard let window else { return }
        let startedAt = Date()
        NSApp.setActivationPolicy(.regular)
        if let icon = bundledAppIconImage() {
            NSApp.applicationIconImage = icon
            window.miniwindowImage = icon
        }
        DispatchQueue.main.async {
            window.center()
            if shouldFocus {
                window.makeMain()
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFront(nil)
            }
            logOperationDuration(
                "[SettingsWindow] show finished",
                startedAt: startedAt,
                warnThresholdMs: 180,
                fields: [
                    "shouldFocus": String(shouldFocus),
                    "frontmost": frontmostAppDescriptor()
                ]
            )
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        log(
            "[SettingsWindow] did become key",
            fields: [
                "frontmost": frontmostAppDescriptor()
            ]
        )
        ScreenOverlayManager.shared.suspendAutomaticRefreshes(reason: "settings_window_key")
    }

    func windowDidResignKey(_ notification: Notification) {
        log(
            "[SettingsWindow] did resign key",
            fields: [
                "frontmost": frontmostAppDescriptor()
            ]
        )
        ScreenOverlayManager.shared.resumeAutomaticRefreshes(reason: "settings_window_resign_key")
    }

    func windowWillClose(_ notification: Notification) {
        log("[SettingsWindow] will close")
        window?.orderOut(nil)
        ScreenOverlayManager.shared.resumeAutomaticRefreshes(reason: "settings_window_closed")
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
    private let openSettingsDistributedNotification = Notification.Name("com.openai.vibe-focus.open-settings")

    private struct ExistingInstanceInfo {
        let app: NSRunningApplication
        let version: String?
        let path: String?
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("applicationDidFinishLaunching bundle=\(Bundle.main.bundleIdentifier ?? "nil") path=\(Bundle.main.bundleURL.path)")
        logDiagnostics("launch")
        CrashContextRecorder.shared.bootstrap()
        NativeSpaceBridge.logAvailability()

        // 单实例处理：同版本复用现有进程，不强制重启。
        if let existing = findExistingInstance() {
            let currentVersion = currentAppVersion()
            let existingVersion = existing.version ?? "unknown"
            log("Found existing instance pid=\(existing.app.processIdentifier) version=\(existingVersion) path=\(existing.path ?? "nil")")
            CrashContextRecorder.shared.record("existing_instance_detected pid=\(existing.app.processIdentifier) version=\(existingVersion)")

            if existing.version == nil || existing.version == currentVersion {
                log("Reusing existing same-version instance; activating and opening settings")
                CrashContextRecorder.shared.record("reuse_existing_instance pid=\(existing.app.processIdentifier)")
                requestExistingInstanceOpenSettings()
                existing.app.activate(options: [.activateAllWindows])
                NSApp.terminate(nil)
                return
            }

            log("Existing instance version differs (current=\(currentVersion), existing=\(existingVersion)); terminating old instance")
            CrashContextRecorder.shared.record("terminate_old_instance pid=\(existing.app.processIdentifier)")
            existing.app.terminate()
            Thread.sleep(forTimeInterval: 0.3)
            if !existing.app.isTerminated {
                kill(existing.app.processIdentifier, SIGTERM)
                Thread.sleep(forTimeInterval: 0.2)
            }
        }

        // 获取锁（不同版本替换场景下应能成功）
        if !acquireExclusiveLock() {
            log("Failed to acquire lock after terminating old instance, retrying...")
            CrashContextRecorder.shared.record("lock_retry")
            Thread.sleep(forTimeInterval: 0.5)
            if !acquireExclusiveLock() {
                log("Still cannot acquire lock, terminating self")
                CrashContextRecorder.shared.record("lock_failed_terminate")
                NSApp.terminate(nil)
                return
            }
        }

        guard enforceExpectedInstallLocation() else {
            return
        }
        applyApplicationIcon()
        setupMenuBar()
        HotKeyManager.shared.setup()
        ClaudeHookServer.shared.applyPreferences()
        ScreenOverlayManager.shared.refreshOverlays()
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
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleOpenSettingsRequest(_:)),
            name: openSettingsDistributedNotification,
            object: nil
        )
        showSettingsWindowOnLaunch()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        log("applicationShouldHandleReopen hasVisibleWindows=\(flag)")
        SettingsWindowController.shared.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        ScreenOverlayManager.shared.flushPendingPreferenceSave(reason: "application_will_terminate")
        CrashContextRecorder.shared.markCleanExit()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        log("setupMenuBar called")
        if let button = statusItem?.button {
            if let image = loadStatusBarImage() {
                log("Setting image to status bar")
                button.image = image
                button.imagePosition = .imageOnly
                button.title = ""
            } else if let fallbackSymbol = fallbackStatusBarSymbolImage() {
                log("Using SF Symbol fallback for status bar")
                button.image = fallbackSymbol
                button.imagePosition = .imageOnly
                button.title = ""
            } else {
                log("Failed to load status bar image/symbol, using text fallback")
                button.image = nil
                button.title = "VF"
            }
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
        log("loadStatusBarImage: bundle path=\(Bundle.main.bundleURL.path)")

        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "StatusBarIcon", withExtension: "png") {
            candidates.append(bundled)
        }
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("StatusBarIcon.png"))
        }

        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(currentDirectory.appendingPathComponent("assets/StatusBarIcon.png"))

        if let executableURL = Bundle.main.executableURL {
            let releaseDir = executableURL.deletingLastPathComponent()
            let repoRoot = releaseDir
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            candidates.append(repoRoot.appendingPathComponent("assets/StatusBarIcon.png"))
        }

        var seenPaths: Set<String> = []
        for candidate in candidates where seenPaths.insert(candidate.path).inserted {
            if FileManager.default.fileExists(atPath: candidate.path),
               let image = NSImage(contentsOf: candidate) {
                log("loadStatusBarImage: Loaded from \(candidate.path) size=\(image.size)")
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                return image
            }
        }

        log("loadStatusBarImage: no usable icon found in candidates")
        return nil
    }

    private func fallbackStatusBarSymbolImage() -> NSImage? {
        guard let image = NSImage(
            systemSymbolName: "viewfinder.circle",
            accessibilityDescription: "VibeFocus"
        ) else {
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
        let op = makeOperationID(prefix: "menu-toggle")
        log(
            "[Menu] toggle clicked",
            fields: [
                "op": op,
                "frontmost": frontmostAppDescriptor()
            ]
        )
        WindowManager.shared.toggle(operationID: op, triggerSource: "menu")
    }

    @objc private func openSettings() {
        log("[Menu] open settings clicked")
        DispatchQueue.main.async {
            SettingsWindowController.shared.show(shouldFocus: true)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func handleAppBecameActive() {
        let startedAt = Date()
        applyApplicationIcon()
        HotKeyManager.shared.refreshAccessibilityStatus()
        logOperationDuration(
            "[AppDelegate] didBecomeActive handled",
            startedAt: startedAt,
            warnThresholdMs: 140,
            fields: [
                "frontmost": frontmostAppDescriptor(),
                "axTrusted": String(HotKeyManager.shared.accessibilityGranted)
            ]
        )
    }

    @objc private func handleOpenSettingsRequest(_ notification: Notification) {
        log(
            "Received distributed open-settings request",
            fields: [
                "frontmost": frontmostAppDescriptor()
            ]
        )
        DispatchQueue.main.async {
            SettingsWindowController.shared.show(shouldFocus: true)
        }
    }

    private func showSettingsWindowOnLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            log("Showing settings window on launch")
            SettingsWindowController.shared.show(shouldFocus: false)
        }
    }

    private func requestExistingInstanceOpenSettings() {
        DistributedNotificationCenter.default().post(
            name: openSettingsDistributedNotification,
            object: nil,
            userInfo: nil
        )
    }

    private func currentAppVersion() -> String {
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        if let bundleVersion, !bundleVersion.isEmpty {
            return bundleVersion
        }
        return AppVersion.current
    }

    private func installedVersion(for app: NSRunningApplication) -> String? {
        guard let bundleURL = app.bundleURL,
              let bundle = Bundle(url: bundleURL) else {
            return nil
        }
        let shortVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        if let shortVersion, !shortVersion.isEmpty {
            return shortVersion
        }
        let buildVersion = bundle.infoDictionary?["CFBundleVersion"] as? String
        if let buildVersion, !buildVersion.isEmpty {
            return buildVersion
        }
        return nil
    }

    // MARK: - Single Instance Check

    // 文件锁路径，用于防止竞态条件
    private let lockFilePath = "/tmp/VibeFocusHotkeys.lock"

    private func acquireExclusiveLock() -> Bool {
        let fd = open(lockFilePath, O_CREAT | O_RDWR, 0o644)
        guard fd != -1 else {
            log("Failed to open lock file")
            return false
        }

        // 尝试获取排他锁（非阻塞）
        let result = flock(fd, LOCK_EX | LOCK_NB)
        if result == -1 {
            // 锁已被占用，关闭文件描述符
            close(fd)
            return false
        }

        // 成功获取锁，保持文件描述符打开以维持锁
        // 注意：文件描述符会在进程退出时自动关闭，锁会自动释放
        log("Acquired exclusive lock, PID \(ProcessInfo.processInfo.processIdentifier)")
        return true
    }

    private func findExistingInstance() -> ExistingInstanceInfo? {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier
        let execPath = Bundle.main.executableURL?.resolvingSymlinksInPath().path

        // Get all running processes with the same name
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-eo", "pid,comm", "-c"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            let processName = execPath?.components(separatedBy: "/").last ?? "VibeFocusHotkeys"

            for line in output.components(separatedBy: .newlines) {
                let components = line.trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }

                guard components.count >= 2,
                      let pid = Int32(components[0]),
                      pid != currentPID else { continue }

                let comm = components[1]
                if comm == processName || comm == "VibeFocusHotkeys" {
                    // Found another instance with same process name
                    // Try to get NSRunningApplication for this PID
                    if let app = NSRunningApplication(processIdentifier: pid) {
                        return ExistingInstanceInfo(
                            app: app,
                            version: installedVersion(for: app),
                            path: app.bundleURL?.path
                        )
                    }
                }
            }
        } catch {
            log("Failed to check for existing instances: \(error)")
        }

        // Fallback: match by bundle ID if available
        if let bundleID = bundleID {
            let runningApps = NSWorkspace.shared.runningApplications
            for app in runningApps {
                if app.bundleIdentifier == bundleID && app.processIdentifier != currentPID {
                    return ExistingInstanceInfo(
                        app: app,
                        version: installedVersion(for: app),
                        path: app.bundleURL?.path
                    )
                }
            }
        }

        return nil
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
            (home as NSString).appendingPathComponent("Applications/VibeFocusHotkeys.app"),
            "/Applications/VibeFocus.app",
            "/Applications/VibeFocusHotkeys.app"
        ]
    }

    private func isAllowedDevelopmentBundlePath(_ path: String) -> Bool {
        path.hasSuffix("/dist/VibeFocus.app") || path.hasSuffix("/dist/VibeFocusHotkeys.app")
    }

    @discardableResult
    private func enforceExpectedInstallLocation() -> Bool {
        let actualURL = Bundle.main.bundleURL
        let actual = actualURL.path
        if actualURL.pathExtension != "app" {
            log("Skipping install-location enforcement for direct binary run: \(actual)")
            return true
        }

        if isAllowedDevelopmentBundlePath(actual) {
            log("Skipping install-location enforcement for development bundle path: \(actual)")
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

        showWrongLocationAlert(actual: actual, expectedPaths: expectedPaths)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
        return false
    }

    private func showWrongLocationAlert(actual: String, expectedPaths: [String]) {
        let alert = NSAlert()
        alert.messageText = "VibeFocus 安装位置异常"
        let home = NSHomeDirectory()
        let displayExpected = expectedPaths
            .prefix(2)
            .map { path in
                if path.hasPrefix(home) {
                    return path.replacingOccurrences(of: home, with: "~")
                }
                return path
            }
            .joined(separator: "\n")
        alert.informativeText = "当前运行位置：\n\(actual)\n\n建议位置：\n\(displayExpected)\n或\n/Applications/VibeFocus.app"
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
