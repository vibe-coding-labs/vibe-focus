import SwiftUI

// MARK: - 摆位快捷键设置（Rectangle 式）
extension SettingsView {

    @ViewBuilder
    var layoutHotKeySection: some View {
        SettingsCard(
            title: "摆位快捷键",
            subtitle: "Rectangle 式窗口摆位：把当前焦点窗口摆到半屏 / 四分 / 最大化 / 居中 / 下一屏。点击录制按钮后直接按下新组合键。"
        ) {
            if let conflictSummary = layoutConflictSummary {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("检测到同类窗口管理器正在运行：\(conflictSummary)。摆位热键已自动停用，避免双方抢键；如仍要启用请打开下方开关。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.12)))

                Divider()
            }

            SettingsRow(
                title: "摆位热键总开关",
                detail: layoutHotKeysEnabled
                    ? "全局热键已注册；菜单栏「摆位」始终可用。"
                    : "热键未注册（不影响主开关 ⌃Q 与菜单操作）。"
            ) {
                Toggle("", isOn: Binding(
                    get: { layoutHotKeysEnabled },
                    set: { newValue in
                        hotKeyManager.setLayoutActionsEnabled(newValue)
                        if newValue {
                            LayoutPreferences.coexistenceChoice = .enableAnyway
                        } else {
                            LayoutPreferences.coexistenceChoice = .keepDisabled
                        }
                        layoutHotKeysEnabled = newValue
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            Divider()

            ForEach(LayoutAction.allCases, id: \.rawValue) { action in
                layoutActionRow(action)
                if action != LayoutAction.allCases.last {
                    Divider()
                }
            }

            Divider()

            SettingsRow(
                title: "摆位留白",
                detail: "窗口与屏幕边缘、半屏接缝之间的间隙（像素，0 = 无缝铺满）。"
            ) {
                Picker("", selection: Binding(
                    get: { Int(LayoutPreferences.snapGap) },
                    set: { newValue in
                        LayoutPreferences.snapGap = CGFloat(newValue)
                        layoutSnapGap = newValue
                    }
                )) {
                    Text("0").tag(0)
                    Text("4").tag(4)
                    Text("8").tag(8)
                    Text("12").tag(12)
                }
                .frame(width: 90)
                .labelsHidden()
            }
        }
    }

    @ViewBuilder
    private func layoutActionRow(_ action: LayoutAction) -> some View {
        let current = hotKeyManager.layoutTable.hotKey(for: action)
        SettingsRow(
            title: action.displayName,
            detail: "默认 \(LayoutAction.defaultBindings[action]?.displayString ?? "未设置")"
        ) {
            HStack(spacing: 8) {
                ShortcutRecorderView(displayedShortcut: current?.displayString ?? "未设置") { hotKey in
                    if let error = hotKeyManager.applyLayoutShortcut(hotKey, for: action) {
                        hotKeyManager.shortcutStatusMessage = error
                        hotKeyManager.shortcutStatusIsError = true
                        NSSound.beep()
                    }
                }
                .frame(width: 150)

                if current != LayoutAction.defaultBindings[action] {
                    Button {
                        hotKeyManager.resetLayoutShortcut(for: action)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .help("恢复默认")
                }
            }
        }
    }
}
