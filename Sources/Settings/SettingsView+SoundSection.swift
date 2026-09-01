import SwiftUI
import UniformTypeIdentifiers

// MARK: - 提示音（设置位于「Claude 集成」标签页，Stop hook 对话完成时触发）
extension SettingsView {

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
                    VolumeSliderRow(
                        volume: Binding(
                            get: { Double(soundManager.preferences.volume) },
                            set: { soundManager.updateVolume(Float($0)) }
                        )
                    )
                }

                Divider()

                PreviewPlaybackButton(
                    isPlaying: $isPreviewPlaying,
                    resetAfter: 3.0,
                    onPlay: {
                        soundManager.previewSound(
                            soundManager.preferences.soundType,
                            customPath: soundManager.preferences.customSoundPath,
                            volume: soundManager.preferences.volume
                        )
                    },
                    onStop: { soundManager.stopPlayback() }
                )

                Text("点击试听当前选择的提示音效果")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if soundManager.preferences.soundType == .custom {
                Divider()

                AudioFilePickerRow(
                    title: "自定义音频文件",
                    detail: soundManager.preferences.customSoundPath ?? "未选择文件",
                    path: soundManager.preferences.customSoundPath,
                    onPick: { path in
                        log("[Settings] selected custom sound file", fields: ["path": path])
                        soundManager.updateCustomSoundPath(path)
                    },
                    onClear: { soundManager.updateCustomSoundPath(nil) }
                )

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
