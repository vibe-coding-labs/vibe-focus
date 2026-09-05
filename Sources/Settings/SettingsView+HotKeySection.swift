import SwiftUI

// MARK: - 快捷键 & 状态
extension SettingsView {

    @ViewBuilder
    var hotKeySection: some View {
        SettingsCard(
            title: "快捷键",
            subtitle: "点击录制按钮后直接按下新组合键。修改后立即生效；如果命中常见系统快捷键会直接阻止。",
            icon: "keyboard"
        ) {
            SettingsRow(
                title: "当前快捷键",
                detail: "全局热键与菜单栏 Toggle 会实时切换到这个组合。"
            ) {
                Text(hotKeyManager.currentHotKey.displayString)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: VibeRadius.chip, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: VibeRadius.chip, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.05), radius: 2, y: 1)
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
            subtitle: "把当前配置结果、权限状态和交互提示整合在一起，减少来回排查的成本。",
            icon: "text.badge.checkmark"
        ) {
            SettingsRow(
                title: "当前状态",
                detail: hotKeyManager.shortcutStatusMessage
            ) {
                SettingsStatusPill(
                    title: hotKeyManager.shortcutStatusIsError ? "冲突" : "正常",
                    tint: hotKeyManager.shortcutStatusIsError ? VibeColors.danger : VibeColors.success
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
    }
}
