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
    @State private var autoShowOnFocus = InputBubblePreferences.autoShowOnFocus
    @State private var defaultPrefix = InputBubblePreferences.defaultPrefix

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
                title: "聚焦会话自动弹出",
                detail: "焦点落到正在运行 Claude 的终端窗时，气泡自动出现（无需按快捷键）。"
            ) {
                Toggle("", isOn: $autoShowOnFocus)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!enabled)
                    .onChange(of: autoShowOnFocus) { newValue in
                        InputBubblePreferences.autoShowOnFocus = newValue
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
                detail: "默认关闭：Enter 换行、⌘Enter 注入并提交；开启后 Enter 注入并提交、⌘Enter 仅粘贴。"
            ) {
                Toggle("", isOn: $submitOnEnter)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!enabled)
                    .onChange(of: submitOnEnter) { newValue in
                        InputBubblePreferences.submitOnEnter = newValue
                    }
            }

            Divider()

            SettingsRow(
                title: "默认前缀",
                detail: "气泡打开时预填的文本（如「/goal 」），适合重复性输入；可随时清空或修改。"
            ) {
                TextField("例如：/goal ", text: $defaultPrefix)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .font(.system(size: 12, design: .monospaced))
                    .disabled(!enabled)
                    .onChange(of: defaultPrefix) { newValue in
                        InputBubblePreferences.defaultPrefix = newValue
                    }
            }
        }
    }
}
