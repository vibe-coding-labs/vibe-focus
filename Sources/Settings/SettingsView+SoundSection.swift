import SwiftUI
import UniformTypeIdentifiers

// MARK: - 提示音（设置位于「Claude 集成」标签页，Stop hook 对话完成时触发）
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

                SettingsRow(
                    title: "播放节流",
                    detail: "多个会话接连完成时的最小提示音间隔（试听不受限）"
                ) {
                    Stepper(
                        value: Binding(
                            get: { soundManager.preferences.minPlayIntervalSeconds },
                            set: { soundManager.updateMinPlayInterval($0) }
                        ),
                        in: 0...30,
                        step: 1
                    ) {
                        Text(
                            soundManager.preferences.minPlayIntervalSeconds == 0
                                ? "关闭"
                                : "\(soundManager.preferences.minPlayIntervalSeconds) 秒"
                        )
                        .font(.system(size: 13, design: .monospaced))
                        .frame(width: 60, alignment: .trailing)
                    }
                }

                Divider()

                SettingsRow(
                    title: "免打扰时段",
                    detail: soundManager.preferences.quietHoursEnabled
                        ? "该时段内对话完成保持静音（不影响窗口移动）"
                        : "设定静音时间段（支持跨午夜，如 22 → 8）"
                ) {
                    VStack(alignment: .trailing, spacing: 6) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { soundManager.preferences.quietHoursEnabled },
                                set: { enabled in
                                    soundManager.updateQuietHours(
                                        enabled: enabled,
                                        startHour: soundManager.preferences.quietStartHour,
                                        endHour: soundManager.preferences.quietEndHour
                                    )
                                }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.checkbox)

                        if soundManager.preferences.quietHoursEnabled {
                            HStack(spacing: 6) {
                                Picker(
                                    "",
                                    selection: Binding(
                                        get: { soundManager.preferences.quietStartHour },
                                        set: { hour in
                                            soundManager.updateQuietHours(
                                                enabled: true,
                                                startHour: hour,
                                                endHour: soundManager.preferences.quietEndHour
                                            )
                                        }
                                    )
                                ) {
                                    ForEach(0..<24, id: \.self) { hour in
                                        Text(String(format: "%02d:00", hour)).tag(hour)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 84)
                                .labelsHidden()

                                Text("→")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)

                                Picker(
                                    "",
                                    selection: Binding(
                                        get: { soundManager.preferences.quietEndHour },
                                        set: { hour in
                                            soundManager.updateQuietHours(
                                                enabled: true,
                                                startHour: soundManager.preferences.quietStartHour,
                                                endHour: hour
                                            )
                                        }
                                    )
                                ) {
                                    ForEach(0..<24, id: \.self) { hour in
                                        Text(String(format: "%02d:00", hour)).tag(hour)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 84)
                                .labelsHidden()
                            }
                        }
                    }
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

            Divider()

            // 项目音效规则（轮次 2）：多会话并开时听到声音即知哪个项目完成。
            // 置于「类型 != 无」守卫之外——全局关闭时单项目规则仍可独立生效。
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
                                    soundManager.preferences.projectRules[index].soundType ?? .builtinComplete
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
                            let ruleType = soundManager.preferences.projectRules[index].soundType ?? .builtinComplete
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
