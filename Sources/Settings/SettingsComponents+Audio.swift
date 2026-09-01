// SettingsComponents+Audio.swift
// VibeFocus — 设置页音频类共享组件（提示音 / 语音播报两区块共用）
// 从 SettingsView+SoundSection.swift 与 SettingsView+VoiceAnnouncementSection.swift
// 的三处成对重复中提取：音量滑杆行、试听按钮、音频文件选择行。
// 文件导入器（fileImporter）内聚在 AudioFilePickerRow 内，
// SettingsView 不再为各区块持有独立的 importer 状态。

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Volume Slider Row

/// 音量滑杆行：speaker 小图标 + 可拖拽滑杆（0~1，步长 0.1）+ 百分比 + speaker 大图标。
/// 提示音与语音播报的「音量」SettingsRow accessory 共用。
struct VolumeSliderRow: View {
    @Binding var volume: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))

            DraggableSlider(
                value: $volume,
                minValue: 0.0,
                maxValue: 1.0,
                step: 0.1
            )
            .frame(width: 120)

            Text("\(Int(volume * 100))%")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40)

            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
        }
    }
}

// MARK: - Preview Playback Button

/// 试听按钮行：试听/停止二态切换 + 底部弹簧占位。
/// isPlaying 的复位沿用历史行为：播放后固定 `resetAfter` 秒自动复位按钮文案
/// （与真实播放时长无关——NSSound/NSSpeechSynthesizer 无轻量完成回调，保持原语义）。
struct PreviewPlaybackButton: View {
    @Binding var isPlaying: Bool
    /// 播放态自动复位秒数（提示音 3s / 语音播报 5s，沿用各区块历史值）
    var resetAfter: TimeInterval
    var onPlay: () -> Void
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(isPlaying ? "停止" : "试听") {
                if isPlaying {
                    onStop()
                    isPlaying = false
                } else {
                    onPlay()
                    isPlaying = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + resetAfter) {
                        isPlaying = false
                    }
                }
            }
            .buttonStyle(.bordered)

            Spacer()
        }
    }
}

// MARK: - Audio File Picker Row

/// 音频文件选择行：路径展示 + 选择文件/清除按钮，fileImporter 内聚。
/// 提示音自定义音频与语音播报音频文件两处共用（同一 allowedContentTypes）。
struct AudioFilePickerRow: View {
    let title: String
    /// SettingsRow detail 文案（调用方传「路径或未选择文件」）
    let detail: String
    /// 当前已选路径（nil 时隐藏「清除」按钮）
    let path: String?
    /// 选中文件回调（绝对路径）；导入失败在组件内记日志
    var onPick: (String) -> Void
    var onClear: () -> Void

    @State private var isImporting = false

    var body: some View {
        SettingsRow(title: title, detail: detail) {
            HStack(spacing: 10) {
                Button("选择文件") {
                    isImporting = true
                }
                .buttonStyle(.bordered)

                if path != nil {
                    Button("清除") {
                        onClear()
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .font(.system(size: 11))
                }
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.audio, .wav, .mp3, .aiff],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    onPick(url.path)
                }
            case .failure(let error):
                log("[AudioFilePickerRow] file importer failed", level: .error, fields: [
                    "title": title,
                    "error": error.localizedDescription
                ])
            }
        }
    }
}
