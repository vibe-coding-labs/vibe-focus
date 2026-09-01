import SwiftUI
import UniformTypeIdentifiers

// MARK: - 语音播报
extension SettingsView {

    var voiceAnnouncementSection: some View {
        SettingsCard(
            title: "语音播报",
            subtitle: "会话完成时语音播报，支持固定文案、本地音频或 LLM 一句话总结。兼容 Claude Code 与 Codex CLI。"
        ) {
            SettingsRow(
                title: "播报模式",
                detail: "对话完成（Stop hook 触发）后播报，与窗口移动解耦"
            ) {
                Picker("", selection: Binding(
                    get: { voiceAnnouncementManager.preferences.mode },
                    set: { voiceAnnouncementManager.updateMode($0) }
                )) {
                    ForEach(VoiceAnnouncementMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 160)
            }

            if voiceAnnouncementManager.preferences.mode != .none {
                Divider()

                SettingsRow(
                    title: "音量",
                    detail: "TTS 与音频文件的播放音量"
                ) {
                    VolumeSliderRow(
                        volume: Binding(
                            get: { Double(voiceAnnouncementManager.preferences.volume) },
                            set: { voiceAnnouncementManager.updateVolume(Float($0)) }
                        )
                    )
                }

                Divider()

                SettingsRow(
                    title: "语速",
                    detail: "TTS 朗读语速（仅固定文案与 LLM 总结模式）"
                ) {
                    HStack(spacing: 8) {
                        Image(systemName: "tortoise.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11))

                        DraggableSlider(
                            value: Binding(
                                get: { Double(voiceAnnouncementManager.preferences.speechRate) },
                                set: { voiceAnnouncementManager.updateSpeechRate(Float($0)) }
                            ),
                            minValue: 100,
                            maxValue: 300,
                            step: 10
                        )
                        .frame(width: 120)

                        Text("\(Int(voiceAnnouncementManager.preferences.speechRate))")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 40)

                        Image(systemName: "hare.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11))
                    }
                }
                .disabled(voiceAnnouncementManager.preferences.mode == .audioFile)

                Divider()

                PreviewPlaybackButton(
                    isPlaying: $isVoicePreviewPlaying,
                    resetAfter: 5.0,
                    onPlay: { voiceAnnouncementManager.preview() },
                    onStop: { voiceAnnouncementManager.stopAll() }
                )

                Text("点击试听当前播报效果")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            // 模式特定控件
            if voiceAnnouncementManager.preferences.mode == .template {
                Divider()

                SettingsRow(
                    title: "文案模板",
                    detail: "支持变量：{project_name} {model} {cwd} {session_id}"
                ) {
                    TextEditor(text: Binding(
                        get: { voiceAnnouncementManager.preferences.templateText },
                        set: { voiceAnnouncementManager.updateTemplateText($0) }
                    ))
                    .font(.system(size: 13))
                    .frame(minHeight: 60, maxHeight: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                }

                Text("模板为空时播报「对话完成」。变量无值时使用默认（如「未知项目」）。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if voiceAnnouncementManager.preferences.mode == .audioFile {
                Divider()

                AudioFilePickerRow(
                    title: "音频文件",
                    detail: voiceAnnouncementManager.preferences.audioFilePath ?? "未选择文件",
                    path: voiceAnnouncementManager.preferences.audioFilePath,
                    onPick: { path in
                        log("[Settings] selected voice announcement audio file", fields: ["path": path])
                        voiceAnnouncementManager.updateAudioFilePath(path)
                    },
                    onClear: { voiceAnnouncementManager.updateAudioFilePath(nil) }
                )

                Text("支持 WAV、MP3、M4A、AIFF 格式。文件缺失时自动 fallback 到「对话完成」。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if voiceAnnouncementManager.preferences.mode == .llmSummary {
                Divider()

                SettingsRow(
                    title: "API Base URL",
                    detail: "OpenAI 兼容端点，如 https://api.openai.com/v1"
                ) {
                    TextField("https://api.openai.com/v1", text: Binding(
                        get: { voiceAnnouncementManager.preferences.llmApiBase },
                        set: { voiceAnnouncementManager.updateLLMApiBase($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                }

                Divider()

                SettingsRow(
                    title: "API Key",
                    detail: "请求失败时自动 fallback 到截断原文播报"
                ) {
                    SecureField("sk-...", text: Binding(
                        get: { voiceAnnouncementManager.preferences.llmApiKey },
                        set: { voiceAnnouncementManager.updateLLMApiKey($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                }

                Divider()

                SettingsRow(
                    title: "模型",
                    detail: "用于总结的 LLM 模型名"
                ) {
                    TextField("gpt-4o-mini", text: Binding(
                        get: { voiceAnnouncementManager.preferences.llmModel },
                        set: { voiceAnnouncementManager.updateLLMModel($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                }

                Divider()

                SettingsRow(
                    title: "最大字数",
                    detail: "总结与 fallback 截断的字数上限"
                ) {
                    Stepper(
                        value: Binding(
                            get: { voiceAnnouncementManager.preferences.llmMaxChars },
                            set: { voiceAnnouncementManager.updateLLMMaxChars($0) }
                        ),
                        in: 10...100,
                        step: 5
                    ) {
                        Text("\(voiceAnnouncementManager.preferences.llmMaxChars) 字")
                            .font(.system(size: 13, design: .monospaced))
                    }
                }

                Text("未配置 API Key 或请求失败时，截断 AI 最后回复的前 \(voiceAnnouncementManager.preferences.llmMaxChars) 字播报；回复为空则播报文案模板。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
