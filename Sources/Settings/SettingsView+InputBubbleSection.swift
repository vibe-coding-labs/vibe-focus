// SettingsView+InputBubbleSection.swift
// VibeFocus — 设置页「输入气泡」区块（B133）
// 配置项：功能开关 / 气泡宽度 / 气泡高度 / 回车默认行为。
// 偏好存取唯一事实源在 InputBubblePreferences（clamp 归一），本视图只做镜像与写穿；
// @State 镜像驱动行内数值即时刷新（UserDefaults 非 SwiftUI 可观察，不能直绑）。

import SwiftUI

// MARK: - 输入气泡

extension SettingsView {

    var inputBubbleSection: some View {
        InputBubbleSectionView()
    }
}

private struct InputBubbleSectionView: View {
    @State private var enabled = InputBubblePreferences.isEnabled
    @State private var width = InputBubblePreferences.bubbleWidth
    @State private var height = InputBubblePreferences.bubbleHeight
    @State private var submitOnEnter = InputBubblePreferences.submitOnEnter

    var body: some View {
        SettingsCard(
            title: "输入气泡",
            subtitle: "SSH 远程会话逐键回显卡顿的对症通道：⌥⌘B 唤起本地气泡打字，回车一次性注入终端。",
            icon: "text.bubble"
        ) {
            SettingsRow(
                title: "启用输入气泡",
                detail: "关闭后 ⌥⌘B 不再唤起气泡（功能整体停用）。"
            ) {
                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: enabled) { newValue in
                        InputBubblePreferences.isEnabled = newValue
                    }
            }

            Divider()

            SettingsRow(
                title: "气泡宽度",
                detail: "唤起时气泡的宽度（320–720 pt）"
            ) {
                HStack(spacing: 8) {
                    DraggableSlider(
                        value: $width,
                        minValue: InputBubblePreferences.widthRange.min,
                        maxValue: InputBubblePreferences.widthRange.max,
                        step: InputBubblePreferences.widthRange.step
                    )
                    .frame(width: 120)
                    .disabled(!enabled)
                    Text("\(Int(width))")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 34)
                }
                .onChange(of: width) { newValue in
                    InputBubblePreferences.bubbleWidth = newValue
                }
            }

            Divider()

            SettingsRow(
                title: "气泡高度",
                detail: "唤起时气泡的高度（100–300 pt）"
            ) {
                HStack(spacing: 8) {
                    DraggableSlider(
                        value: $height,
                        minValue: InputBubblePreferences.heightRange.min,
                        maxValue: InputBubblePreferences.heightRange.max,
                        step: InputBubblePreferences.heightRange.step
                    )
                    .frame(width: 120)
                    .disabled(!enabled)
                    Text("\(Int(height))")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 34)
                }
                .onChange(of: height) { newValue in
                    InputBubblePreferences.bubbleHeight = newValue
                }
            }

            Divider()

            SettingsRow(
                title: "回车即提交",
                detail: "开启后 Enter 注入并回车提交、⌘Enter 仅粘贴；关闭后 Enter 仅粘贴、⌘Enter 提交。"
            ) {
                Toggle("", isOn: $submitOnEnter)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!enabled)
                    .onChange(of: submitOnEnter) { newValue in
                        InputBubblePreferences.submitOnEnter = newValue
                    }
            }
        }
    }
}
