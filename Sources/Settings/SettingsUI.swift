import SwiftUI
import AppKit
import UniformTypeIdentifiers

// SettingsView — see SettingsComponents.swift for UI components
// AppDelegate — see AppDelegate.swift for app lifecycle
// 计算属性与会话列表已移至 SettingsUI+Helpers.swift

public struct SettingsView: View {
    public init() {}
    /// 测试缝：各分区「操作结果横幅」的初始值集合（纯 @State，无 UserDefaults 来源）。
    /// 生产走 `init()` / `init(initialTab:)`，零行为变更。
    struct ResultMessages {
        var hookInstall: String? = nil
        var hookInstallOK = true
        var codexInstall: String? = nil
        var codexInstallOK = true
        var codexTest: String? = nil
        var mcpAction: String? = nil
        var mcpActionOK = true
        var onboarding: String? = nil
        var onboardingOK = true
        var gridResult: String? = nil
        var gridResultIsError = false
        var gridFavoriteWarning: String? = nil
    }
    /// B317 测试缝：指定初始 tab（tabContent 是 switch 非惰性 TabView，渲染树只含
    /// 选中 case；@EnvironmentObject 急切访问的 section（如 layoutHotKeySection 的
    /// hotKeyManager.layoutTable）必须整树渲染，post-install 写 @State 在无窗
    /// NSHostingView 下不落 storage——初始值注入是唯一确定性通道）。生产默认
    /// .general，零行为变更（B239 init(startTimerAutomatically:) 同款家法）。
    init(initialTab: SettingsTab) {
        _selectedTab = State(initialValue: initialTab)
    }
    /// 测试缝：注入编排目标初始值（同 B317 initialTab 家法——无窗环境下
    /// post-install 写 @State 不落 storage，初始值注入是唯一确定性通道）。
    /// 生产默认走 `init()`，零行为变更。
    init(
        gridTargetCode: String,
        gridMinimapScreens: [ScreenLayoutMapper.InputScreen] = [],
        gridSpaceSwitchMessage: String? = nil,
        duplicateAppPaths: [String] = [],
        layoutHotKeysEnabled: Bool? = nil,
        layoutConflictSummary: String?? = nil,
        initialTab: SettingsTab? = nil,
        resultMessages: ResultMessages? = nil,
        gridSnapshots: [SessionRestoreSnapshot]? = nil,
        gridAutoRestoreSnapshotID: String?? = nil
    ) {
        // 快照列表行同理（纯 @State + @State 覆盖面）：列表非空时的行内多屏/多工作区
        // 计数与「已设开机恢复」pill 分支，只有初始值注入才能渲染出来。
        if let gridSnapshots {
            _gridSnapshots = State(initialValue: gridSnapshots)
        }
        if let snapshotID = gridAutoRestoreSnapshotID {
            _gridAutoRestoreSnapshotID = State(initialValue: snapshotID)
        }
        if let initialTab {
            _selectedTab = State(initialValue: initialTab)
        }
        // 各分区操作结果横幅（安装/测试/注册/接入物料）都是纯 @State，无 UserDefaults
        // 来源——post-install 写入在无窗渲染下不落 storage，横幅分支只能靠初始值。
        if let resultMessages {
            _hookInstallMessage = State(initialValue: resultMessages.hookInstall)
            _hookInstallSucceeded = State(initialValue: resultMessages.hookInstallOK)
            _codexInstallMessage = State(initialValue: resultMessages.codexInstall)
            _codexInstallSucceeded = State(initialValue: resultMessages.codexInstallOK)
            _codexTestMessage = State(initialValue: resultMessages.codexTest)
            _mcpActionMessage = State(initialValue: resultMessages.mcpAction)
            _mcpActionOK = State(initialValue: resultMessages.mcpActionOK)
            _onboardingMessage = State(initialValue: resultMessages.onboarding)
            _onboardingOK = State(initialValue: resultMessages.onboardingOK)
            _gridResultMessage = State(initialValue: resultMessages.gridResult ?? "")
            _gridResultIsError = State(initialValue: resultMessages.gridResultIsError)
            _gridFavoriteWarning = State(initialValue: resultMessages.gridFavoriteWarning)
        }
        _gridTargetCode = State(initialValue: gridTargetCode)
        _gridMinimapScreens = State(initialValue: gridMinimapScreens)
        _gridSpaceSwitchMessage = State(initialValue: gridSpaceSwitchMessage)
        // 权限分区「其它安装副本」分支随同一缝注入：post-install 写 @State 在无窗
        // 渲染下不落 storage（B317），旧测试注入了却渲染不出来。
        _duplicateAppPaths = State(initialValue: duplicateAppPaths)
        // 摆位分区两态同理：layoutHotKeysEnabled / layoutConflictSummary 没有
        // UserDefaults 来源（纯本地 @State），post-install 写入渲染不出来。
        // 双可选语义：layoutConflictSummary 传 `.some(nil)` = 显式清空冲突，
        // 传 `nil` = 保留探针默认值。
        if let enabled = layoutHotKeysEnabled {
            _layoutHotKeysEnabled = State(initialValue: enabled)
        }
        if let conflict = layoutConflictSummary {
            _layoutConflictSummary = State(initialValue: conflict)
        }
    }
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
    // Minimap 胶囊点击 live 切换的结局反馈（nil = 无进行中的反馈）
    @State var gridSpaceSwitchMessage: String?
    // minimap 心跳定时器（订阅挂在 terminalGridSection 上，只在编排页在层级时活着；
    // 周期与可见性门控契约见 MinimapRefreshPolicy）
    @State var gridMinimapHeartbeat = Timer.publish(
        every: MinimapRefreshPolicy.autoRefreshIntervalSeconds, on: .main, in: .common
    ).autoconnect()
    @State var gridGap = Double(TerminalGridPreferences.gap)
    @State var gridAppPreference = TerminalGridPreferences.appPreference
    @State var gridLaunchCommand = TerminalGridPreferences.launchCommand
    @State var gridResultMessage = ""
    @State var gridResultIsError = false
    @State var gridSnapshots: [SessionRestoreSnapshot] = []
    @State var gridAutoRestoreEnabled = TerminalGridPreferences.autoRestoreEnabled
    @State var gridAutoRestoreSnapshotID: String? = TerminalGridPreferences.autoRestoreSnapshotID
    @State var gridSelectionPreview: TerminalSelection?
    @State var gridFavoriteWarning: String?

    // Codex CLI Hook 安装状态
    @State var codexInstallMessage: String?
    @State var codexInstallSucceeded = true
    @State var codexTestMessage: String?

    // Agent 接入（卡片见 SettingsView+AgentAccessSection.swift；API 侧同键读取于
    // AgentAccessPreferences——@AppStorage 直写 standard 域，App 内每请求实时生效）
    @AppStorage(AgentAccessPreferences.enabledKey) var agentAccessEnabled = AgentAccessPreferences.defaultEnabled
    @AppStorage(AgentAccessPreferences.allowWindowOpsKey) var agentAllowWindowOps = AgentAccessPreferences.defaultAllowWindowOps
    @AppStorage(AgentAccessPreferences.allowCreateWindowsKey) var agentAllowCreateWindows = AgentAccessPreferences.defaultAllowCreateWindows
    @AppStorage(AgentAccessPreferences.allowSettingsWriteKey) var agentAllowSettingsWrite = AgentAccessPreferences.defaultAllowSettingsWrite
    @State var mcpActionMessage: String?
    @State var mcpActionOK = true
    @State var onboardingMessage: String?
    @State var onboardingOK = true

    // Hook 触发开关
    @AppStorage(ClaudeHookPreferences.triggerOnStopKey) var triggerOnStop = ClaudeHookPreferences.defaultTriggerOnStop
    @AppStorage(ClaudeHookPreferences.triggerOnSessionEndKey) var triggerOnSessionEnd = ClaudeHookPreferences.defaultTriggerOnSessionEnd
    @AppStorage(ClaudeHookPreferences.autoRestoreOnPromptSubmitKey) var autoRestoreOnPromptSubmit = ClaudeHookPreferences.defaultAutoRestoreOnPromptSubmit
    @AppStorage(ClaudeHookPreferences.notifyOnNotificationKey) var notifyOnNotification = ClaudeHookPreferences.defaultNotifyOnNotification

    // MARK: - Tab Navigation

    private var headerBar: some View {
        HStack(spacing: 14) {
            AppLogoBadge(size: 46)
                .shadow(color: VibeColors.shadow.opacity(0.30), radius: 7, y: 3)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("VibeFocus")
                        .font(.system(size: 20, weight: .bold))
                        .tracking(-0.4)
                        .foregroundStyle(VibeColors.ink)
                    Text(appVersionDisplay)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                }
                Text("菜单栏里的窗口流转工具")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            SettingsStatusPill(
                title: hotKeyManager.shortcutStatusIsError ? "需要处理" : "工作正常",
                tint: hotKeyManager.shortcutStatusIsError ? VibeColors.danger : VibeColors.success
            )
        }
    }

    private var tabBar: some View {
        SettingsTabBar(selection: $selectedTab)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .general:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hotKeySection
                    inputBubbleSection
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
                    layoutHotKeySection
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

        case .codexIntegration:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    codexSection
                }
            }
            .scrollIndicators(.visible)

        case .agentAccess:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    agentAccessSection
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
                .padding(.top, 22)

            tabBar
                .padding(.top, 16)

            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
                .padding(.top, 14)

            tabContent
                .padding(.top, 18)
                .padding(.bottom, 22)
        }
        .padding(.horizontal, 26)
        .frame(minWidth: 780, idealWidth: 780, minHeight: 680, idealHeight: 740)
        .tint(VibeColors.accent)
        .background(alignment: .top) {
            VibeColors.headerWash
                .frame(height: 150)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .background(VibeColors.background)
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
