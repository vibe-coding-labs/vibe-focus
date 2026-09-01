// SettingsView+TitleEditorSection.swift
// VibeFocus — 设置页「窗口标题编辑」区块
// 从 SettingsView+SoundSection.swift 中归位（该文件原以"提示音 & 标题编辑 & LAN"混装，
// 提示音设置移交 Claude 集成标签页后，标题编辑按文件名-内容一致原则独立成文件）。

import SwiftUI

// MARK: - 窗口标题编辑
extension SettingsView {

    var titleEditorSection: some View {
        SettingsCard(
            title: "窗口标题编辑",
            subtitle: "通过快捷键编辑当前终端窗口标题，方便识别多个终端。"
        ) {
            Toggle("启用标题编辑", isOn: Binding(
                get: { TitleEditorPreferences.isEnabled },
                set: { TitleEditorPreferences.isEnabled = $0 }
            ))
            .font(.system(size: 13))

            Toggle("快捷键 ⌃T", isOn: Binding(
                get: { TitleEditorPreferences.isHotKeyEnabled },
                set: { TitleEditorPreferences.isHotKeyEnabled = $0 }
            ))
            .font(.system(size: 13))
            .disabled(!TitleEditorPreferences.isEnabled)

            HStack(spacing: 4) {
                Text("按下")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("⌃T")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .cornerRadius(3)
                Text("编辑当前终端窗口标题")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
