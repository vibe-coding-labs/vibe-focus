import SwiftUI
import UniformTypeIdentifiers

// MARK: - 提示音 · 自定义音频与项目规则（2026-09-07 B9 从 SoundSection 拆分）
extension SettingsView {

    /// 自定义音频文件选择 + 缺失降级警示（soundType == .custom 守卫内展示）
    @ViewBuilder
    var customAudioFileRows: some View {
        AudioFilePickerRow(
            title: "自定义音频文件",
            detail: customSoundStatus.uiDescription,
            path: soundManager.preferences.customSoundPath,
            onPick: { path in
                log("[Settings] selected custom sound file", fields: ["path": path])
                soundManager.updateCustomSoundPath(path)
            },
            onClear: { soundManager.updateCustomSoundPath(nil) }
        )

        if customSoundStatus == .missing {
            InfoBanner(
                style: .warning,
                text: "所选文件不存在，完成音将自动降级为系统默认。请重新选择或清除该配置。"
            )
        }

        Text("支持 WAV、MP3、M4A、AIFF 格式。选择后可点击「试听」验证效果。")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 项目音效规则（轮次 2）：置于「类型 != 无」守卫之外——全局关闭时单项目规则仍可独立生效。
    var projectRulesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsRow(
                title: "项目音效规则",
                detail: "为指定项目设置专属提示音，从上到下首个命中生效，未命中回落上方全局设置"
            ) {
                Button("添加规则") {
                    soundManager.addProjectRule()
                }
                .buttonStyle(.bordered)
            }

            if !soundManager.preferences.projectRules.isEmpty {
                ForEach(soundManager.preferences.projectRules.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        TextField(
                            "项目名或路径",
                            text: Binding(
                                get: { soundManager.preferences.projectRules[index].projectName },
                                set: { soundManager.setProjectRuleName(at: index, $0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))

                        Picker(
                            "",
                            selection: Binding(
                                get: {
                                    soundManager.preferences.projectRules[index].effectiveSoundType
                                },
                                set: { soundManager.setProjectRuleSound(at: index, $0) }
                            )
                        ) {
                            ForEach(CompletionSoundType.allCases, id: \.self) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 130)
                        .labelsHidden()

                        // 迷你试听（轮次 3）：即点即听该规则音效，验证听感辨识效果
                        Button {
                            let ruleType = soundManager.preferences.projectRules[index].effectiveSoundType
                            soundManager.previewSound(
                                ruleType,
                                customPath: soundManager.preferences.customSoundPath,
                                volume: soundManager.preferences.volume
                            )
                        } label: {
                            Image(systemName: "speaker.wave.2")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                        .help("试听该规则的音效")

                        Button {
                            soundManager.removeProjectRule(at: index)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                    }
                }

                Text("匹配与项目名大小写无关，规则里也可直接粘贴项目绝对路径；规则选「自定义文件」时共用全局自定义音频。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
