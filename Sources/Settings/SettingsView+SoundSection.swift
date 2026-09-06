import SwiftUI
import UniformTypeIdentifiers

// MARK: - 提示音（设置位于「Claude 集成」标签页，Stop hook 对话完成时触发）
// 2026-09-07 B9 拆分：防打扰/自定义文件 → +SoundAntiDisturb，项目规则/音效说明 → +SoundProjectRules。
extension SettingsView {

    /// 自定义音频文件有效性状态（轮次 3：detail 文案 + 缺失警示共用）
    var customSoundStatus: CustomSoundStatus {
        CustomSoundStatus.evaluate(path: soundManager.preferences.customSoundPath)
    }

    var soundSection: some View {
        SettingsCard(
            title: "提示音",
            subtitle: "对话完成时播放提示音，支持内置音效或自定义音频文件；可设节流间隔与免打扰时段防打扰。",
            icon: "speaker.wave.2"
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

                antiDisturbRows

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

                customAudioFileRows
            }

            Divider()

            projectRulesSection
        }
    }
}

/// 提示音设置页的展示文案（纯函数，Runner 直测穷尽锁定）
enum SoundSectionText {
    /// 节流步进器的值标签：0 = 关闭，其余 = N 秒
    static func throttleLabel(seconds: Int) -> String {
        seconds == 0 ? "关闭" : "\(seconds) 秒"
    }

    /// 免打扰时段行的说明文案
    static func quietHoursDetail(enabled: Bool) -> String {
        enabled ? "该时段内对话完成保持静音（不影响窗口移动）"
                : "设定静音时间段（支持跨午夜，如 22 → 8）"
    }
}
