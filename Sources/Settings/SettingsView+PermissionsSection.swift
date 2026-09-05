import SwiftUI

// MARK: - 权限 & 安装 & 登录项
extension SettingsView {

    var permissionsSection: some View {
        SettingsCard(
            title: "权限与授权",
            subtitle: "用于确认当前实例是否已获得辅助功能权限，并提供快速跳转与修复指引。",
            icon: "lock.shield"
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
                        tint: hotKeyManager.accessibilityGranted ? VibeColors.success : VibeColors.danger
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
                    .buttonStyle(.vibeProminent)

                    Button("复制重置命令") {
                        // P-INST-243: 复制权限重置命令到剪贴板耗时（NSPasteboard.clearContents + setString；权限设置 UI 按钮触发；slow-op ≥5ms warn）。
                        #if PERF_INSTRUMENT
                        let crsStart = Date()
                        #endif
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(resetAccessCommand, forType: .string)
                        #if PERF_INSTRUMENT
                        let durMs = elapsedMilliseconds(since: crsStart)
                        if durMs >= 5 { log("[PermissionsSection] copy reset cmd slow", level: .warn, fields: ["durationMs": String(durMs)]) }
                        #endif
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
                    // P-INST-115: 用户点击「在 Finder 中显示」耗时（NSWorkspace.shared.activateFileViewerSelecting 启动 Finder 选中 app；async 返回但启动配置可阻塞）。
                    let fsStart = Date()
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: currentAppPath)])
                    log("[Settings] revealInFinder finished", level: .debug, fields: [
                        "durationMs": String(elapsedMilliseconds(since: fsStart))
                    ])
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
                                .foregroundStyle(VibeColors.warning)
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
                                .foregroundStyle(VibeColors.accent)
                                Button("删除") {
                                    moveDuplicateToTrash(path: path)
                                }
                                .buttonStyle(.borderless)
                                .font(.system(size: 11))
                                .foregroundStyle(VibeColors.danger)
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: VibeRadius.panel, style: .continuous)
                                .fill(Color.orange.opacity(0.07))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: VibeRadius.panel, style: .continuous)
                                .strokeBorder(Color.orange.opacity(0.16), lineWidth: 1)
                        )
                    }
                    HStack {
                        Spacer()
                        Button("全部删除") {
                            moveAllDuplicatesToTrash()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(VibeColors.danger)
                    }
                }
            }
        }
    }

    var loginItemSection: some View {
        SettingsCard(
            title: "开机启动",
            subtitle: "控制 VibeFocus 是否在登录后自动启动；如需确认或移除，可在系统设置中操作。",
            icon: "power"
        ) {
            SettingsRow(
                title: "登录时启动",
                detail: loginItemManager.statusDetail
            ) {
                HStack(spacing: 10) {
                    SettingsStatusPill(
                        title: loginItemManager.statusTitle,
                        tint: loginItemManager.isEnabled
                            ? VibeColors.success
                            : (loginItemManager.requiresApproval ? VibeColors.warning : VibeColors.neutral)
                    )
                    Toggle("", isOn: Binding(
                        get: { loginItemManager.isEnabled },
                        set: { loginItemManager.setEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
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
    }
}
