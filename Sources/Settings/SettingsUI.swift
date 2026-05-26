import SwiftUI
import AppKit
import UniformTypeIdentifiers

// SettingsView — see SettingsComponents.swift for UI components
// AppDelegate — see AppDelegate.swift for app lifecycle

public struct SettingsView: View {
    public init() {}
    @EnvironmentObject var hotKeyManager: HotKeyManager
    @StateObject var spaceController = SpaceController.shared
    @StateObject var loginItemManager = LoginItemManager.shared
    @StateObject var overlayManager = ScreenOverlayManager.shared
    @AppStorage(SpacePreferences.integrationEnabledKey) var spaceIntegrationEnabled = SpacePreferences.defaultIntegrationEnabled
    @AppStorage(SpacePreferences.restoreStrategyKey) var restoreStrategyRaw = SpacePreferences.defaultRestoreStrategy.rawValue
    @State var duplicateAppPaths: [String] = []
    @State var isCheckingInstallations = false

    // Claude Hook 集成
    @StateObject var hookServer = ClaudeHookServer.shared
    @StateObject var sessionRegistry = SessionWindowRegistry.shared
    @AppStorage(ClaudeHookPreferences.enabledKey) var hookEnabled = ClaudeHookPreferences.defaultEnabled
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
    @AppStorage(ClaudeHookPreferences.autoFocusOnSessionEndKey) var autoFocusOnSessionEnd = ClaudeHookPreferences.defaultAutoFocusOnSessionEnd
    @AppStorage(ClaudeHookPreferences.triggerOnStopKey) var triggerOnStop = ClaudeHookPreferences.defaultTriggerOnStop
    @AppStorage(ClaudeHookPreferences.triggerOnSessionEndKey) var triggerOnSessionEnd = ClaudeHookPreferences.defaultTriggerOnSessionEnd
    @AppStorage(ClaudeHookPreferences.autoRestoreOnPromptSubmitKey) var autoRestoreOnPromptSubmit = ClaudeHookPreferences.defaultAutoRestoreOnPromptSubmit
    @State var hookInstallMessage: String?
    @State var hookInstallSucceeded = false

    // 提示音设置
    @StateObject var soundManager = SoundManager.shared
    @State var isPreviewPlaying = false
    @State var showFileImporter = false
    @State var selectedTab: SettingsTab = .general

    var appVersionDisplay: String {
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let version = (bundleVersion?.isEmpty == false) ? bundleVersion ?? AppVersion.current : AppVersion.current
        return "v\(version)"
    }

    var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.vibefocus.app"
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

    // MARK: - Tab Navigation

    private var headerBar: some View {
        HStack(spacing: 16) {
            AppLogoBadge(size: 52)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("VibeFocus")
                        .font(.system(size: 20, weight: .semibold))
                    Text(appVersionDisplay)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text("菜单栏里的窗口流转工具")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            SettingsStatusPill(
                title: hotKeyManager.shortcutStatusIsError ? "需要处理" : "工作正常",
                tint: hotKeyManager.shortcutStatusIsError ? .red : .green
            )
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                SettingsTabButton(
                    tab: tab,
                    isSelected: selectedTab == tab
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedTab = tab
                    }
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .general:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hotKeySection
                    permissionsSection
                    loginItemSection
                }
            }
            .scrollIndicators(.visible)

        case .workspace:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    workspaceSection
                    overlaySection
                }
            }
            .scrollIndicators(.visible)

        case .claudeIntegration:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    claudeHookSection
                    LANSettingsView()
                }
            }
            .scrollIndicators(.visible)

        case .appearance:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    titleEditorSection
                    soundSection
                }
            }
            .scrollIndicators(.visible)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
                .padding(.top, 20)

            tabBar
                .padding(.top, 14)

            Divider()
                .padding(.top, 10)

            tabContent
                .padding(.top, 16)
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 28)
        .frame(minWidth: 720, idealWidth: 720, minHeight: 680, idealHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
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
