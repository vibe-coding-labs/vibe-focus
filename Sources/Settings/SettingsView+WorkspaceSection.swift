import SwiftUI

// MARK: - 跨工作区设置
extension SettingsView {

    var workspaceSection: some View {
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
    }
}
