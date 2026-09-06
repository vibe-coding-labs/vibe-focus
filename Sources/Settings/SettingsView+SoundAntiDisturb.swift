import SwiftUI
import UniformTypeIdentifiers

// MARK: - 提示音 · 音量与防打扰行（2026-09-07 B9 从 SoundSection 拆分）
import SwiftUI

extension SettingsView {

    /// 音量 + 节流 + 免打扰（在 soundType != .none 守卫内展示）
    @ViewBuilder
    var antiDisturbRows: some View {
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
                Text(SoundSectionText.throttleLabel(seconds: soundManager.preferences.minPlayIntervalSeconds))
                    .font(.system(size: 13, design: .monospaced))
                    .frame(width: 60, alignment: .trailing)
            }
        }

        Divider()

        SettingsRow(
            title: "免打扰时段",
            detail: SoundSectionText.quietHoursDetail(enabled: soundManager.preferences.quietHoursEnabled)
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
    }
}
