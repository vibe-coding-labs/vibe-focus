import SwiftUI
import AppKit
import Carbon
import ApplicationServices.HIServices
import CoreFoundation
import Foundation
import Darwin
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
        let version = (bundleVersion?.isEmpty == false) ? bundleVersion! : AppVersion.current
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
                        title: "关机快照",
                        subtitle: "关机时自动保存所有终端窗口的位置和 Claude Code 会话，下次开机时可一键恢复。"
                    ) {
                        SettingsRow(
                            title: "关机时保存终端状态",
                            detail: "关机或退出时自动保存所有终端窗口状态。"
                        ) {
                            Toggle("", isOn: Binding(
                                get: { ShutdownSnapshotManager.shared.isEnabled },
                                set: { ShutdownSnapshotManager.shared.isEnabled = $0 }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                        }

                        SettingsRow(
                            title: "开机时自动恢复",
                            detail: "检测到上次关机快照时自动恢复终端窗口和 Claude 会话。"
                        ) {
                            Toggle("", isOn: Binding(
                                get: { UserDefaults.standard.object(forKey: "autoRestoreOnBoot") as? Bool ?? false },
                                set: { UserDefaults.standard.set($0, forKey: "autoRestoreOnBoot"); PreferencesSync.persistToDisk() }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                        }

                        if ShutdownSnapshotManager.shared.hasPendingSnapshot {
                            Divider()

                            SettingsRow(
                                title: "待恢复快照",
                                detail: "检测到上次关机时保存的终端窗口状态。"
                            ) {
                                HStack(spacing: 10) {
                                    Button("立即恢复") {
                                        if let snapshot = ShutdownSnapshotManager.shared.loadSnapshot() {
                                            TerminalRestoreService.shared.performRestore(snapshot)
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)

                                    Button("清除快照") {
                                        ShutdownSnapshotManager.shared.clearSnapshot()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
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
                        subtitle: "让 VibeFocus 监听 Claude Code 的对话事件，实现对话完成后自动将终端窗口拉回主屏幕并最大化。"
                    ) {
                        // === 功能说明 ===
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "lightbulb.fill")
                                .foregroundStyle(.yellow.opacity(0.8))
                                .font(.system(size: 14))
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("工作原理")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("开启服务并安装 Hook 后，Claude Code 会在对话结束时自动将终端窗口移到主屏幕。开启「提交后自动恢复」后，在你提交新提示词时窗口会自动回到原来的位置 — 无需手动按快捷键。")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.yellow.opacity(0.06))
                        )

                        Divider()

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
                                        if newValue {
                                            ClaudeHookPreferences.ensureTokenGenerated()
                                            hookToken = ClaudeHookPreferences.authToken ?? ""
                                        }
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

                        // === 自动恢复 ===
                        SettingsRow(
                            title: "提交后自动恢复",
                            detail: "提交新提示词时，自动将窗口恢复到原来的屏幕、工作区和位置"
                        ) {
                            Toggle("", isOn: Binding(
                                get: { autoRestoreOnPromptSubmit },
                                set: { newValue in
                                    autoRestoreOnPromptSubmit = newValue
                                    ClaudeHookPreferences.autoRestoreOnPromptSubmit = newValue
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                        }

                        Text("与「对话完成移到主屏幕」配合使用，实现全自动的窗口来回切换。")
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

                        SettingsRow(title: "鉴权 Token", detail: "自动生成，Hook 安装时同步写入 Claude 配置，确保通信安全") {
                            HStack(spacing: 8) {
                                if hookToken.isEmpty {
                                    Text("未生成")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(String(hookToken.prefix(8)) + "...")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }

                                Button(hookToken.isEmpty ? "生成" : "重新生成") {
                                    hookToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32).lowercased()
                                    ClaudeHookPreferences.authToken = hookToken
                                    if hookEnabled { hookServer.applyPreferences() }
                                }
                                .buttonStyle(.borderless)
                                .font(.system(size: 11))
                            }
                        }

                        if !hookToken.isEmpty {
                            Text("Token 已自动同步到 Hook 脚本配置，无需重新安装")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
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
                        activeSessionList

                        // === 已完成会话列表 ===
                        completedSessionList

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

                    SettingsCard(
                        title: "提示音",
                        subtitle: "对话完成时播放提示音，支持内置音效或自定义音频文件。"
                    ) {
                        SettingsRow(
                            title: "提示音类型",
                            detail: "Claude 对话完成（窗口移动成功）后播放的提示音"
                        ) {
                            Picker("", selection: Binding(
                                get: { soundManager.preferences.soundType },
                                set: { soundManager.updateSoundType($0) }
                            )) {
                                ForEach(CompletionSoundType.allCases, id: \.self) { type in
                                    Text(type.displayName).tag(type)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 160)
                        }

                        if soundManager.preferences.soundType != .none {
                            Divider()

                            SettingsRow(
                                title: "音量",
                                detail: "调整提示音的音量大小"
                            ) {
                                HStack(spacing: 8) {
                                    Image(systemName: "speaker.fill")
                                        .foregroundStyle(.secondary)
                                        .font(.system(size: 11))

                                    DraggableSlider(
                                        value: Binding(
                                            get: { Double(soundManager.preferences.volume) },
                                            set: { soundManager.updateVolume(Float($0)) }
                                        ),
                                        minValue: 0.0,
                                        maxValue: 1.0,
                                        step: 0.1
                                    )
                                    .frame(width: 120)

                                    Text("\(Int(soundManager.preferences.volume * 100))%")
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 40)

                                    Image(systemName: "speaker.wave.3.fill")
                                        .foregroundStyle(.secondary)
                                        .font(.system(size: 11))
                                }
                            }

                            Divider()

                            HStack(spacing: 12) {
                                Button(isPreviewPlaying ? "停止" : "试听") {
                                    if isPreviewPlaying {
                                        soundManager.stopPlayback()
                                        isPreviewPlaying = false
                                    } else {
                                        soundManager.previewSound(
                                            soundManager.preferences.soundType,
                                            customPath: soundManager.preferences.customSoundPath,
                                            volume: soundManager.preferences.volume
                                        )
                                        isPreviewPlaying = true
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                                            isPreviewPlaying = false
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)

                                Spacer()
                            }

                            Text("点击试听当前选择的提示音效果")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }

                        if soundManager.preferences.soundType == .custom {
                            Divider()

                            SettingsRow(
                                title: "自定义音频文件",
                                detail: soundManager.preferences.customSoundPath ?? "未选择文件"
                            ) {
                                HStack(spacing: 10) {
                                    Button("选择文件") {
                                        showFileImporter = true
                                    }
                                    .buttonStyle(.bordered)

                                    if soundManager.preferences.customSoundPath != nil {
                                        Button("清除") {
                                            soundManager.updateCustomSoundPath(nil)
                                        }
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(.red)
                                        .font(.system(size: 11))
                                    }
                                }
                            }

                            Text("支持 WAV、MP3、M4A、AIFF 格式。选择后可点击「试听」验证效果。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("内置音效说明：")
                                .font(.system(size: 13, weight: .medium))

                            HStack(spacing: 6) {
                                Image(systemName: "music.note")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 11))
                                Text("Ding — 短促清脆的提示音")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 6) {
                                Image(systemName: "music.note")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 11))
                                Text("Ping — 柔和的中频提示音")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 6) {
                                Image(systemName: "music.note")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 11))
                                Text("Complete — 完成感较强的上升音")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 6) {
                                Image(systemName: "person.wave.2")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 11))
                                Text("Are You OK — 雷军经典语音提示")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 4)
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
            // 从 ClaudeHookPreferences 加载 token 到 @State
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

