import SwiftUI
import AppKit
import UniformTypeIdentifiers

// SettingsView — see SettingsComponents.swift for UI components
// AppDelegate — see AppDelegate.swift for app lifecycle

struct SettingsView: View {
    @EnvironmentObject var hotKeyManager: HotKeyManager
    @StateObject var spaceController = SpaceController.shared
    @StateObject var loginItemManager = LoginItemManager.shared
    @StateObject var overlayManager = ScreenOverlayManager.shared
    @AppStorage(SpacePreferences.integrationEnabledKey) var spaceIntegrationEnabled = true
    @AppStorage(SpacePreferences.restoreStrategyKey) var restoreStrategyRaw = SpaceRestoreStrategy.switchToOriginal.rawValue
    @State var duplicateAppPaths: [String] = []
    @State var isCheckingInstallations = false

    // Claude Hook 集成
    @StateObject var hookServer = ClaudeHookServer.shared
    @StateObject var sessionRegistry = SessionWindowRegistry.shared
    @AppStorage(ClaudeHookPreferences.enabledKey) var hookEnabled = false
    @AppStorage(ClaudeHookPreferences.portKey) var hookPort = ClaudeHookPreferences.defaultPort

    var activeSessionList: some View {
        let bindings = sessionRegistry.activeBindingsForUI
        if bindings.isEmpty { return AnyView(EmptyView()) }
        return AnyView(VStack(alignment: .leading, spacing: 8) {
            Text("活跃会话（\(sessionRegistry.activeBindingCount)）")
                .font(.system(size: 13, weight: .medium))
            ForEach(Array(bindings.prefix(5).enumerated()), id: \.offset) { _, binding in
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                    Text(binding.appName ?? "Unknown")
                        .font(.system(size: 12, weight: .medium))
                    Text(binding.title ?? "Untitled")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text((binding.sessionID ?? "").prefix(8))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            if bindings.count > 5 {
                Text("还有 \(bindings.count - 5) 个...")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        })
    }

    var completedSessionList: some View {
        let bindings = sessionRegistry.recentCompletedBindings
        if bindings.isEmpty { return AnyView(EmptyView()) }
        return AnyView(VStack(alignment: .leading, spacing: 8) {
            Text("最近完成（\(sessionRegistry.completedBindingCount)）")
                .font(.system(size: 13, weight: .medium))
            ForEach(Array(bindings.prefix(3).enumerated()), id: \.offset) { _, binding in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                        .font(.system(size: 11))
                    Text(binding.appName ?? "Unknown")
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
        })
    }
    @State var hookToken: String = ""
    @AppStorage(ClaudeHookPreferences.autoFocusOnSessionEndKey) var autoFocusOnSessionEnd = true
    @AppStorage(ClaudeHookPreferences.triggerOnStopKey) var triggerOnStop = true
    @AppStorage(ClaudeHookPreferences.triggerOnSessionEndKey) var triggerOnSessionEnd = false
    @AppStorage(ClaudeHookPreferences.autoRestoreOnPromptSubmitKey) var autoRestoreOnPromptSubmit = true
    @State var hookInstallMessage: String?
    @State var hookInstallSucceeded = false

    // 提示音设置
    @StateObject var soundManager = SoundManager.shared
    @State var isPreviewPlaying = false
    @State var showFileImporter = false

    var appVersionDisplay: String {
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let version = (bundleVersion?.isEmpty == false) ? bundleVersion ?? AppVersion.current : AppVersion.current
        return "v\(version)"
    }

    var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.vibefocus.app"
    }

    var loginItemSidebarValue: String {
        if loginItemManager.isEnabled {
            return "已启用"
        }
        if loginItemManager.requiresApproval {
            return "待确认"
        }
        return "未启用"
    }

    var currentAppPath: String {
        Bundle.main.bundleURL.path
    }

    var expectedAppPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Applications/VibeFocus.app")
    }

    var otherInstallations: [String] {
        duplicateAppPaths.filter { $0 != currentAppPath }
    }

    var resetAccessCommand: String {
        "tccutil reset Accessibility \(bundleIdentifier)"
    }

    var spaceEffectiveEnabled: Bool {
        spaceIntegrationEnabled && spaceController.availability == .available
    }

    var spaceStatusTitle: String {
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

    var spaceStatusTint: Color {
        switch spaceController.availability {
        case .available:
            return .green
        case .notInstalled, .unknown:
            return .gray
        case .unavailable:
            return .orange
        }
    }

    var spaceStatusDetail: String {
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

    var spaceSidebarValue: String {
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
                    // MARK: Sidebar
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
                        SidebarInfoCard(title: "提示音", value: soundManager.preferences.soundType == .none ? "未启用" : soundManager.preferences.soundType.displayName)
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

                    // MARK: Content
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                    hotKeySection
                    permissionsSection
                    loginItemSection
                    shutdownSnapshotSection
                    workspaceSection
                    claudeHookSection
                    LANSettingsView()
                    titleEditorSection
                    overlaySection
                    soundSection
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
            hookToken = ClaudeHookPreferences.authToken ?? ""
            logOperationDuration(
                "[Settings] view onAppear finished",
                startedAt: startedAt,
                warnThresholdMs: 300,
                fields: [
                    "spaceAvailability": spaceController.availability.rawValue,
                    "axTrusted": String(hotKeyManager.accessibilityGranted),
                    "loginItemEnabled": String(loginItemManager.isEnabled),
                    "hookTokenLoaded": String(!hookToken.isEmpty)
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
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.audio, .wav, .mp3, .aiff],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    let path = url.path
                    log("[Settings] selected custom sound file", fields: ["path": path])
                    soundManager.updateCustomSoundPath(path)
                }
            case .failure(let error):
                log("[Settings] file importer failed", level: .error, fields: [
                    "error": error.localizedDescription
                ])
            }
        }
    }
}
