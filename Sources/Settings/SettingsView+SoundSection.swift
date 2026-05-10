import SwiftUI
import UniformTypeIdentifiers

// MARK: - 提示音 & 标题编辑 & LAN
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

    var soundSection: some View {
        SettingsCard(
            title: "提示音",
            subtitle: "对话完成时播放提示音，支持内置音效或自定义音频文件。"
        ) {
            SettingsRow(
                title: "提示音类型",
                detail: "Claude 对话完成（窗口移动成功）后播放的提示音"
            ) {
                Picker("", selection: Binding(
                    get: { soundManager.preferences.soundType },
                    set: { soundManager.updateSoundType($0) }
                )) {
                    ForEach(CompletionSoundType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 160)
            }

            if soundManager.preferences.soundType != .none {
                Divider()

                SettingsRow(
                    title: "音量",
                    detail: "调整提示音的音量大小"
                ) {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11))

                        DraggableSlider(
                            value: Binding(
                                get: { Double(soundManager.preferences.volume) },
                                set: { soundManager.updateVolume(Float($0)) }
                            ),
                            minValue: 0.0,
                            maxValue: 1.0,
                            step: 0.1
                        )
                        .frame(width: 120)

                        Text("\(Int(soundManager.preferences.volume * 100))%")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 40)

                        Image(systemName: "speaker.wave.3.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11))
                    }
                }

                Divider()

                HStack(spacing: 12) {
                    Button(isPreviewPlaying ? "停止" : "试听") {
                        if isPreviewPlaying {
                            soundManager.stopPlayback()
                            isPreviewPlaying = false
                        } else {
                            soundManager.previewSound(
                                soundManager.preferences.soundType,
                                customPath: soundManager.preferences.customSoundPath,
                                volume: soundManager.preferences.volume
                            )
                            isPreviewPlaying = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                                isPreviewPlaying = false
                            }
                        }
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }

                Text("点击试听当前选择的提示音效果")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if soundManager.preferences.soundType == .custom {
                Divider()

                SettingsRow(
                    title: "自定义音频文件",
                    detail: soundManager.preferences.customSoundPath ?? "未选择文件"
                ) {
                    HStack(spacing: 10) {
                        Button("选择文件") {
                            showFileImporter = true
                        }
                        .buttonStyle(.bordered)

                        if soundManager.preferences.customSoundPath != nil {
                            Button("清除") {
                                soundManager.updateCustomSoundPath(nil)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                            .font(.system(size: 11))
                        }
                    }
                }

                Text("支持 WAV、MP3、M4A、AIFF 格式。选择后可点击「试听」验证效果。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("内置音效说明：")
                    .font(.system(size: 13, weight: .medium))

                HStack(spacing: 6) {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                    Text("Ding — 短促清脆的提示音")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                    Text("Ping — 柔和的中频提示音")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                    Text("Complete — 完成感较强的上升音")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Image(systemName: "person.wave.2")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                    Text("Are You OK — 雷军经典语音提示")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
