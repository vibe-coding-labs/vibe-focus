import SwiftUI

// MARK: - 屏幕序号显示
extension SettingsView {

    var overlaySection: some View {
        SettingsCard(
            title: "屏幕序号显示",
            subtitle: "在每个屏幕上显示编号标签，方便识别多屏幕环境。"
        ) {
            SettingsRow(
                title: "启用屏幕序号",
                detail: "在屏幕上显示编号标签"
            ) {
                Toggle("", isOn: Binding(
                    get: { overlayManager.preferences.isEnabled },
                    set: { overlayManager.setEnabled($0) }
                ))
                .labelsHidden()
            }

            if overlayManager.preferences.isEnabled {
                Divider()

                HStack(spacing: 8) {
                    Image(systemName: spaceController.isEnabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(spaceController.isEnabled ? .green : .orange)
                        .font(.system(size: 14))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(spaceController.isEnabled ? "已检测到 yabai" : "未检测到 yabai")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(spaceController.isEnabled ? .green : .orange)

                        Text(spaceController.isEnabled
                            ? "将显示完整索引（如 1-0, 1-2），表示「屏幕-工作区」"
                            : "仅显示屏幕索引（如 0, 1）。安装 yabai 后可显示工作区索引"
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                if !spaceController.isEnabled {
                    Divider()

                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))

                        Text("请先添加 yabai: brew tap koekeishiya/formulae && brew install yabai")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }

                Divider()

                SettingsRow(
                    title: "工作区编号模式",
                    detail: "固定使用屏幕级别编号：每个屏幕都从 1 开始（如 1-1, 1-2；2-1, 2-2）"
                ) {
                    Text("屏幕级别（固定）")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                }

                Divider()

                SettingsRow(
                    title: "显示位置",
                    detail: "选择序号标签在屏幕上的显示位置"
                ) {
                    Picker("", selection: Binding(
                        get: { overlayManager.preferences.position },
                        set: { overlayManager.updatePosition($0) }
                    )) {
                        ForEach(IndexPosition.allCases, id: \.self) { position in
                            HStack(spacing: 4) {
                                Image(systemName: position.icon)
                                Text(position.displayName)
                            }
                            .tag(position)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }

                Divider()

                SettingsRow(
                    title: "字体大小",
                    detail: "调整序号显示的大小"
                ) {
                    HStack(spacing: 8) {
                        DraggableSlider(
                            value: Binding(
                                get: { Double(overlayManager.preferences.fontSize) },
                                set: { newValue in
                                    var prefs = overlayManager.preferences
                                    prefs.fontSize = CGFloat(newValue)
                                    overlayManager.preferences = prefs
                                }
                            ),
                            minValue: 24,
                            maxValue: 72,
                            step: 4
                        )
                        .frame(width: 120)

                        Text("\(Int(overlayManager.preferences.fontSize))")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 30)
                    }
                }

                Divider()

                SettingsRow(
                    title: "背景透明度",
                    detail: "调整序号标签背景的透明程度"
                ) {
                    HStack(spacing: 8) {
                        DraggableSlider(
                            value: Binding(
                                get: { Double(overlayManager.preferences.opacity) },
                                set: { newValue in
                                    var prefs = overlayManager.preferences
                                    prefs.opacity = CGFloat(newValue)
                                    overlayManager.preferences = prefs
                                }
                            ),
                            minValue: 0.3,
                            maxValue: 1.0,
                            step: 0.1
                        )
                        .frame(width: 120)

                        Text("\(Int(overlayManager.preferences.opacity * 100))%")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 40)
                    }
                }

                Divider()

                SettingsRow(
                    title: "面板大小",
                    detail: "调整索引面板的整体缩放比例"
                ) {
                    HStack(spacing: 8) {
                        DraggableSlider(
                            value: Binding(
                                get: { Double(overlayManager.preferences.panelScale) },
                                set: { newValue in
                                    var prefs = overlayManager.preferences
                                    prefs.panelScale = CGFloat(newValue)
                                    overlayManager.preferences = prefs
                                }
                            ),
                            minValue: 0.5,
                            maxValue: 2.0,
                            step: 0.1
                        )
                        .frame(width: 120)

                        Text("\(String(format: "%.1f", overlayManager.preferences.panelScale))x")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 40)
                    }
                }

                Divider()

                SettingsRow(
                    title: "面板边距",
                    detail: "调整索引面板距离屏幕边缘的间距"
                ) {
                    HStack(spacing: 8) {
                        DraggableSlider(
                            value: Binding(
                                get: { Double(overlayManager.preferences.panelMargin) },
                                set: { newValue in
                                    var prefs = overlayManager.preferences
                                    prefs.panelMargin = CGFloat(newValue)
                                    overlayManager.preferences = prefs
                                }
                            ),
                            minValue: 0,
                            maxValue: 120,
                            step: 2
                        )
                        .frame(width: 120)

                        Text("\(Int(overlayManager.preferences.panelMargin))")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 30)
                    }
                }

                Divider()

                SettingsRow(
                    title: "文字颜色",
                    detail: "选择序号文字的颜色"
                ) {
                    ColorPicker("",
                        selection: Binding(
                            get: { overlayManager.preferences.textColor.swiftUIColor },
                            set: { newValue in
                                var prefs = overlayManager.preferences
                                prefs.textColor = CodableColor(newValue)
                                overlayManager.preferences = prefs
                            }
                        )
                    )
                    .labelsHidden()
                    .frame(width: 60)
                }

                Divider()

                SettingsRow(
                    title: "背景颜色",
                    detail: "选择索引面板的背景颜色"
                ) {
                    ColorPicker("",
                        selection: Binding(
                            get: { overlayManager.preferences.backgroundColor.swiftUIColor },
                            set: { newValue in
                                var prefs = overlayManager.preferences
                                prefs.backgroundColor = CodableColor(newValue)
                                overlayManager.preferences = prefs
                            }
                        )
                    )
                    .labelsHidden()
                    .frame(width: 60)
                }

                Divider()

                HStack(spacing: 12) {
                    Text("示例预览：")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                    Text(spaceController.isEnabled ? "1-1" : "1")
                        .font(.system(size: overlayManager.preferences.fontSize * overlayManager.preferences.panelScale, weight: .bold))
                        .foregroundColor(overlayManager.preferences.textColor.swiftUIColor)
                        .padding(.horizontal, 16 * overlayManager.preferences.panelScale)
                        .padding(.vertical, 8 * overlayManager.preferences.panelScale)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(overlayManager.preferences.backgroundColor.swiftUIColor.opacity(overlayManager.preferences.opacity))
                        )

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }
}
