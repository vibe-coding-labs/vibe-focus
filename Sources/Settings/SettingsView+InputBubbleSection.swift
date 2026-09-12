// SettingsView+InputBubbleSection.swift
// VibeFocus — 设置页「输入气泡」区块（B133/B162）
// 配置项：功能开关 / 唤起快捷键 / 聚焦自动弹出 / 移到主屏自动弹出 / 气泡宽度 / 高度 /
// 回车默认行为 / 默认前缀。
// 偏好存取唯一事实源在 InputBubblePreferences（clamp 归一），本视图只做镜像与写穿；
// @State 镜像驱动行内数值即时刷新（UserDefaults 非 SwiftUI 可观察，不能直绑）。

import Combine
import SwiftUI

// MARK: - 输入气泡

extension SettingsView {

    var inputBubbleSection: some View {
        InputBubbleSectionView()
    }
}

private struct InputBubbleSectionView: View {
    @EnvironmentObject private var hotKeyManager: HotKeyManager
    @State private var enabled = InputBubblePreferences.isEnabled
    @State private var width = InputBubblePreferences.bubbleWidth
    @State private var height = InputBubblePreferences.bubbleHeight
    @State private var submitOnEnter = InputBubblePreferences.submitOnEnter
    @State private var autoShowOnFocus = InputBubblePreferences.autoShowOnFocus
    @State private var autoShowOnMoveToMain = InputBubblePreferences.autoShowOnMoveToMain
    @State private var defaultPrefix = InputBubblePreferences.defaultPrefix
    @State private var bubbleHotKeyDisplay = InputBubblePreferences.hotKey.displayString
    /// 录制失败时强制 ShortcutRecorderButton 重建回显当前生效组合键（NSViewRepresentable
    /// 同值 @State 不触发 updateNSView）
    @State private var recorderSeed = UUID()

    private var isDefaultBubbleHotKey: Bool {
        InputBubblePreferences.hotKey == InputBubbleHotKeyPlan.defaultConfig
    }

    var body: some View {
        SettingsCard(
            title: "输入气泡",
            subtitle: "SSH 远程会话逐键回显卡顿的对症通道：快捷键（默认 ⌘B）唤起本地气泡打字，一次性注入终端；输入按目标窗保留，拖动位置也会记住。气泡右下角可直接拖拽调大小，与下方尺寸设置实时联动。",
            icon: "text.bubble"
        ) {
            SettingsRow(
                title: "启用输入气泡",
                detail: "关闭后唤起快捷键不再响应（功能整体停用）。"
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
                title: "唤起快捷键",
                detail: "默认 ⌘B，点击录制后按下新组合键；与主开关/摆位键冲突时气泡自动让位。"
            ) {
                HStack(spacing: 8) {
                    ShortcutRecorderView(displayedShortcut: bubbleHotKeyDisplay) { hotKey in
                        if let error = hotKeyManager.applyBubbleShortcut(hotKey) {
                            hotKeyManager.shortcutStatusMessage = error
                            hotKeyManager.shortcutStatusIsError = true
                            NSSound.beep()
                        }
                        bubbleHotKeyDisplay = InputBubblePreferences.hotKey.displayString
                        recorderSeed = UUID()
                    }
                    .frame(width: 150)
                    .id(recorderSeed)

                    if !isDefaultBubbleHotKey {
                        Button {
                            hotKeyManager.resetBubbleShortcut()
                            bubbleHotKeyDisplay = InputBubblePreferences.hotKey.displayString
                            recorderSeed = UUID()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                        .help("恢复默认 ⌘B")
                    }
                }
                .disabled(!enabled)
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
                title: "移回主屏自动弹出",
                detail: "窗口被拉回主屏（如会话结束 Stop）时气泡自动出现，方便接着输入下一条。"
            ) {
                Toggle("", isOn: $autoShowOnMoveToMain)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!enabled)
                    .onChange(of: autoShowOnMoveToMain) { newValue in
                        InputBubblePreferences.autoShowOnMoveToMain = newValue
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
        // B175：气泡拖拽落账（或他处写偏好）→ 镜像 @State 回写，滑杆实时跟随。
        // 同值回写不触发 onChange，联动回路自然收敛。
        .onReceive(
            NotificationCenter.default.publisher(for: InputBubblePreferences.sizeDidChangeNotification)
                .receive(on: RunLoop.main)
        ) { _ in
            width = InputBubblePreferences.bubbleWidth
            height = InputBubblePreferences.bubbleHeight
        }
    }
}
