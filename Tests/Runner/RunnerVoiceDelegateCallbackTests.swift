import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerVoiceDelegateCallbackTests.swift — 覆盖率批次 33（B265）：
// VoiceAnnouncementManager delegate 回调入口直测（sender 身份守卫 + nonisolated→
// MainActor Task 跳转链）。
//
// speechSynthesizer(_:didFinishSpeaking:)/sound(_:didFinishPlaying:) 是 AppKit
// delegate 入口（nonisolated），内部经 Task { @MainActor } 跳回主线程访问状态。
// 测试：真实 NSSpeechSynthesizer/NSSound 实例（不发声，仅作身份 token）经入口送达，
// 非当前活跃实例的回调被 sender === 守卫丢弃（幂等）。

extension RunnerHarness {
    func runVoiceDelegateCallbackTests() {
        let voice = VoiceAnnouncementManager.shared
        voice.stopAll() // 干净起点

        // delegate 入口（nonisolated）可在任意线程调用——用旁观者身份实例：
        // 非活跃 sender → 守卫丢弃 → 不推进队列不崩。
        let strangerSynth = NSSpeechSynthesizer()
        voice.speechSynthesizer(strangerSynth, didFinishSpeaking: true)
        let strangerSound = NSSound()
        voice.sound(strangerSound, didFinishPlaying: true)
        check("voiceDelegate: 陌生 sender 回调被守卫丢弃不崩",
              !voice.isAnnouncing && voice.pendingAnnouncements.isEmpty)

        // 当前活跃实例身份对齐：speak 经 B249 注入缝创建合成器，delegate 回调
        // 送达后 isAnnouncing 复位（真实链路入口→状态机）。
        let provider = MockSynthesizerProvider()
        voice.synthesizerProvider = provider
        defer { voice.stopAll() }
        voice.speak("b265 delegate 链路")
        let activeSynth = voice.activeSynthesizer
        check("voiceDelegate: speak 后 activeSynthesizer 挂载且 isAnnouncing",
              activeSynth != nil && voice.isAnnouncing)
        // 经 nonisolated delegate 入口模拟 AppKit 完成回调（Task 跳主线程）。
        voice.speechSynthesizer(activeSynth!, didFinishSpeaking: true)
        // 回调经 Task @MainActor 异步——主线程泵等待状态复位。
        let deadline = Date().addingTimeInterval(5)
        while voice.isAnnouncing && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        check("voiceDelegate: 完成回调复位 isAnnouncing",
              !voice.isAnnouncing && voice.activeSynthesizer == nil)
    }
}
