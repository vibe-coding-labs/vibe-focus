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
            subtitle: "通过快捷键编辑当前终端窗口标题，方便识别多个终端。",
            icon: "character.cursor.ibeam"
        ) {
            SettingsRow(
                title: "启用标题编辑",
                detail: "关闭后标题编辑功能整体停用。"
            ) {
                Toggle("", isOn: Binding(
                    get: { TitleEditorPreferences.isEnabled },
                    set: { TitleEditorPreferences.isEnabled = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            Divider()

            SettingsRow(
                title: "快捷键 ⌃T",
                detail: "按下 ⌃T 编辑当前终端窗口标题。"
            ) {
                Toggle("", isOn: Binding(
                    get: { TitleEditorPreferences.isHotKeyEnabled },
                    set: { TitleEditorPreferences.isHotKeyEnabled = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!TitleEditorPreferences.isEnabled)
            }
        }
    }
}
