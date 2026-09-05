import SwiftUI
import AppKit
import UniformTypeIdentifiers

// SettingsView — see SettingsComponents.swift for UI components
// AppDelegate — see AppDelegate.swift for app lifecycle
// 计算属性与会话列表已移至 SettingsUI+Helpers.swift

public struct SettingsView: View {
    public init() {}
    @EnvironmentObject var hotKeyManager: HotKeyManager
    @StateObject var spaceController = SpaceController.shared
    @StateObject var loginItemManager = LoginItemManager.shared
    @StateObject var overlayManager = ScreenOverlayManager.shared
    @AppStorage(SpacePreferences.integrationEnabledKey) var spaceIntegrationEnabled = SpacePreferences.defaultIntegrationEnabled
    @State var duplicateAppPaths: [String] = []
    @State var isCheckingInstallations = false

    // Claude Hook 集成
    @StateObject var hookServer = ClaudeHookServer.shared
    @StateObject var sessionRegistry = SessionWindowRegistry.shared
    @AppStorage(ClaudeHookPreferences.enabledKey) var hookEnabled = ClaudeHookPreferences.defaultEnabled
    @AppStorage(ClaudeHookPreferences.portKey) var hookPort = ClaudeHookPreferences.defaultPort

    // 提示音（设置卡片见 SettingsView+SoundSection.swift）
    @StateObject var soundManager = SoundManager.shared
    @State var isPreviewPlaying = false
    @State var selectedTab: SettingsTab = .general

    // 语音播报（设置卡片见 SettingsView+VoiceAnnouncementSection.swift）
    @StateObject var voiceAnnouncementManager = VoiceAnnouncementManager.shared
    @State var isVoicePreviewPlaying = false

    // Hook token / 安装状态
    @State var hookToken = ""
    @State var hookInstallMessage: String?
    @State var hookInstallSucceeded = true

    // 摆位快捷键（卡片见 SettingsView+LayoutSection.swift）
    @State var layoutHotKeysEnabled = LayoutPreferences.isEnabled
    @State var layoutConflictSummary: String? = WindowLayoutManagerProbe.probe().conflictSummary
    @State var layoutSnapGap = Int(LayoutPreferences.snapGap)

    // 终端网格（卡片见 SettingsView+TerminalGridSection.swift）
    let terminalGridController = TerminalGridController.shared
    @State var gridRows = TerminalGridPreferences.rows
    @State var gridCols = TerminalGridPreferences.cols
    @State var gridTargetCode = TerminalGridPreferences.target
    @State var gridMinimapScreens: [ScreenLayoutMapper.InputScreen] = []
    @State var gridGap = Double(TerminalGridPreferences.gap)
    @State var gridAppPreference = TerminalGridPreferences.appPreference
    @State var gridLaunchCommand = TerminalGridPreferences.launchCommand
    @State var gridResultMessage = ""
    @State var gridResultIsError = false
    @State var gridSnapshots: [TerminalGridSnapshot] = []
    @State var gridAutoRestoreEnabled = TerminalGridPreferences.autoRestoreEnabled
    @State var gridAutoRestoreSnapshotID: String? = TerminalGridPreferences.autoRestoreSnapshotID
    @State var gridSelectionPreview: TerminalSelection?
    @State var gridFavoriteWarning: String?

    // Codex CLI Hook 安装状态
    @State var codexInstallMessage: String?
    @State var codexInstallSucceeded = true

    // Hook 触发开关
    @AppStorage(ClaudeHookPreferences.triggerOnStopKey) var triggerOnStop = ClaudeHookPreferences.defaultTriggerOnStop
    @AppStorage(ClaudeHookPreferences.triggerOnSessionEndKey) var triggerOnSessionEnd = ClaudeHookPreferences.defaultTriggerOnSessionEnd
    @AppStorage(ClaudeHookPreferences.autoRestoreOnPromptSubmitKey) var autoRestoreOnPromptSubmit = ClaudeHookPreferences.defaultAutoRestoreOnPromptSubmit

    // MARK: - Tab Navigation

    private var headerBar: some View {
        HStack(spacing: 14) {
            AppLogoBadge(size: 44)
                .shadow(color: Color.black.opacity(0.18), radius: 5, y: 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("VibeFocus")
                        .font(.system(size: 19, weight: .bold))
                        .tracking(-0.3)
                    Text(appVersionDisplay)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
                }
                Text("菜单栏里的窗口流转工具")
                    .font(.system(size: 12))
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
                VStack(alignment: .leading, spacing: 16) {
                    hotKeySection
                    layoutHotKeySection
                    permissionsSection
                    loginItemSection
                }
            }
            .scrollIndicators(.visible)

        case .workspace:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    workspaceSection
                    overlaySection
                }
            }
            .scrollIndicators(.visible)

        case .orchestration:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    terminalGridSection
                        .onAppear { refreshSelectionInfo() }
                }
            }
            .scrollIndicators(.visible)

        case .claudeIntegration:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    claudeHookSection
                    soundSection
                    voiceAnnouncementSection
                    LANSettingsView()
                }
            }
            .scrollIndicators(.visible)

        case .appearance:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    titleEditorSection
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

            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
                .padding(.top, 12)

            tabContent
                .padding(.top, 16)
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 26)
        .frame(minWidth: 780, idealWidth: 780, minHeight: 680, idealHeight: 740)
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
}
