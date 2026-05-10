import SwiftUI

// MARK: - 快捷键 & 状态
extension SettingsView {

    @ViewBuilder
    var hotKeySection: some View {
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
    }
}
