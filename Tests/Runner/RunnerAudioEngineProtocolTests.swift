import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerAudioEngineProtocolTests.swift — 覆盖率批次 18（B249）：
// 发声口协议抽象直测——SoundPlaying / SpeechSynthesizerProviding 注入缝。
//
// mock 走两条路：①SoundPlaying 协议的 MockSoundPlayer（记录 play/stop 调用与音量）；
// ②NSSpeechSynthesizer 子类 override startSpeaking/stopSpeaking（记录文本不发声），
// 由 MockSynthesizerProvider 注入。至此 previewSound/stopPlayback/announceCompletion
// template 链/speak 全编排可在零发声下直测——C4 发声通道豁免收窄到「引擎真实实现」。

/// 播放口 mock：记录 play/stop 次数与最近音量。
final class MockSoundPlayer: SoundPlaying {
    private(set) var playCount = 0
    private(set) var stopCount = 0
    private(set) var lastVolume: Float = -1
    func play(_ sound: NSSound, volume: Float) { playCount += 1; lastVolume = volume }
    func stop(_ sound: NSSound) { stopCount += 1 }
}

/// 合成器 mock：startSpeaking 只记录不发声。
final class MockSpeechSynthesizer: NSSpeechSynthesizer {
    private(set) var startedText: String?
    private(set) var startCalled = false
    private(set) var stopCalled = false
    override func startSpeaking(_ text: String) -> Bool { startedText = text; startCalled = true; return true }
    override func stopSpeaking() { stopCalled = true }
    /// 测试缝：清空「本次开口」记录（同一 mock 跨多次播报断言用；生产路径无此调用）。
    func resetRecording() {
        startedText = nil
        startCalled = false
        stopCalled = false
    }
}

final class MockSynthesizerProvider: SpeechSynthesizerProviding {
    let synthesizer = MockSpeechSynthesizer()
    var lastRate: Float = -1
    var lastVolume: Float = -1
    func makeSynthesizer(rate: Float, volume: Float, delegate: NSSpeechSynthesizerDelegate?) -> NSSpeechSynthesizer {
        lastRate = rate
        lastVolume = volume
        synthesizer.delegate = delegate
        return synthesizer
    }
}

extension RunnerHarness {
    func runAudioEngineProtocolTests() {
        // MARK: A. SoundManager：mock 播放口下的完整播放编排
        let sound = SoundManager.shared
        let savedType = sound.preferences.soundType
        let savedVolume = sound.preferences.volume
        let savedInterval = sound.preferences.minPlayIntervalSeconds
        defer {
            sound.updateSoundType(savedType)
            sound.updateVolume(savedVolume)
            sound.updateMinPlayInterval(savedInterval)
        }

        let mockPlayer = MockSoundPlayer()
        sound.soundPlayer = mockPlayer
        defer { sound.stopPlayback() }

        sound.updateSoundType(.systemDefault)
        sound.updateVolume(0.6)
        sound.updateMinPlayInterval(0)
        sound.playCompletionSound(projectName: nil)
        check("soundEngine: 完成音经注入口播放恰一次且音量透传",
              mockPlayer.playCount == 1 && abs(mockPlayer.lastVolume - 0.6) < 1e-6)
        sound.playFailureSound()
        check("soundEngine: 失败音非 .none 时同样经注入口（累计两次）",
              mockPlayer.playCount == 2)

        sound.stopPlayback()
        check("soundEngine: stopPlayback 经注入口停机", mockPlayer.stopCount >= 1)

        // previewSound：用户显式试听不经过防打扰门（历史语义），直达注入口。
        // 用 systemDefault（Runner bundle 无 Sounds 资源，builtin 资源缺失走 nil 早退）。
        sound.previewSound(.systemDefault, volume: 0.8)
        check("soundEngine: previewSound 免门直达注入口且音量透传",
              mockPlayer.playCount == 3 && abs(mockPlayer.lastVolume - 0.8) < 1e-6)

        // MARK: B. VoiceAnnouncementManager：mock 合成器下的 speak/stopAll 编排
        let voice = VoiceAnnouncementManager.shared
        let savedRate = voice.preferences.speechRate
        let savedVoiceVolume = voice.preferences.volume
        defer {
            voice.updateSpeechRate(savedRate)
            voice.updateVolume(savedVoiceVolume)
            voice.stopAll()
        }

        let provider = MockSynthesizerProvider()
        voice.synthesizerProvider = provider
        voice.updateSpeechRate(200)
        voice.updateVolume(0.9)

        voice.speak("B249 朗读文本")
        check("voiceEngine: speak 送达 mock 合成器且 rate/volume 透传",
              provider.synthesizer.startedText == "B249 朗读文本"
              && provider.synthesizer.startCalled
              && abs(provider.lastRate - 200) < 1e-6
              && abs(provider.lastVolume - 0.9) < 1e-6
              && voice.isAnnouncing)
        voice.speak("")
        check("voiceEngine: 空文本静默跳过（不触合成器）",
              provider.synthesizer.startedText == "B249 朗读文本")

        voice.stopAll()
        check("voiceEngine: stopAll 经合成器 stopSpeaking 并清 announcing 态",
              provider.synthesizer.stopCalled && !voice.isAnnouncing)
    }

    // MARK: - announceRestoreOutcome 接线（2026-11-23 补口）
    //
    // plan 纯映射已由 RunnerDecisionPrefSweep 穷举，但**接线**（107-133：mode=none
    // 静默断言、语音入队、三路音效分流）零覆盖——写错通道不会有任何断言红。
    // 用 mock 合成器 + mock 播放器观察，零真实发声。
    func runRestoreOutcomeAnnouncementTests() {
        let voice = VoiceAnnouncementManager.shared
        let sound = SoundManager.shared
        let savedMode = voice.preferences.mode
        let savedType = sound.preferences.soundType
        let savedInterval = sound.preferences.minPlayIntervalSeconds
        defer {
            voice.updateMode(savedMode)
            sound.updateSoundType(savedType)
            sound.updateMinPlayInterval(savedInterval)
            voice.stopAll()
            sound.stopPlayback()
        }

        let mockProvider = MockSynthesizerProvider()
        voice.synthesizerProvider = mockProvider
        let mockPlayer = MockSoundPlayer()
        sound.soundPlayer = mockPlayer
        sound.updateMinPlayInterval(0)
        sound.updateQuietHours(enabled: false, startHour: sound.preferences.quietStartHour,
                               endHour: sound.preferences.quietEndHour)

        // A. aborted → silent：语音零开口、音效零播放
        voice.updateMode(.template)
        voice.updateTemplateText("{project_name} 完成")
        sound.updateSoundType(.systemDefault)
        mockProvider.synthesizer.resetRecording()
        voice.announceRestoreOutcome(.aborted(reason: "no_record"), windowID: 7001)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check("restoreOutcome A1: aborted → 双通道静默",
              mockProvider.synthesizer.startedText == nil && mockPlayer.playCount == 0)

        // B. restored(spaceExact: true) + 手动恢复（playsSuccessSound=false）
        //    → 语音播「窗口已恢复」，但成功音被扣住（ding 只留给 agent 完成语义）
        mockProvider.synthesizer.resetRecording()
        let beforeB = mockPlayer.playCount
        voice.announceRestoreOutcome(.restored(spaceExact: true), windowID: 7002,
                                     playsSuccessSound: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check("restoreOutcome B1: 手动恢复 → 语音播「窗口已恢复」",
              mockProvider.synthesizer.startedText == "窗口已恢复")
        check("restoreOutcome B2: 手动恢复 → 成功音被扣住",
              mockPlayer.playCount == beforeB)

        // C. restored + agent 路径（playsSuccessSound=true）→ 语音 + 成功音
        voice.stopAll()
        mockProvider.synthesizer.resetRecording()
        let beforeC = mockPlayer.playCount
        voice.announceRestoreOutcome(.restored(spaceExact: true), windowID: 7003,
                                     playsSuccessSound: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check("restoreOutcome C1: agent 恢复 → 语音 + 成功音各一次",
              mockProvider.synthesizer.startedText == "窗口已恢复"
              && mockPlayer.playCount == beforeC + 1)

        // D. moveFailedRetryable → 失败音（Basso 通道），语音播失败文案
        voice.stopAll()
        mockProvider.synthesizer.resetRecording()
        let beforeD = mockPlayer.playCount
        voice.announceRestoreOutcome(.moveFailedRetryable, windowID: 7004)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check("restoreOutcome D1: 可重试失败 → 失败音一次",
              mockPlayer.playCount == beforeD + 1)
        check("restoreOutcome D2: 可重试失败 → 语音文案非空",
              (mockProvider.synthesizer.startedText?.isEmpty == false))

        // E. mode=none → 语音通道静默，但音效通道不受影响（两开关各管一通道）
        voice.stopAll()
        voice.updateMode(.none)
        mockProvider.synthesizer.resetRecording()
        let beforeE = mockPlayer.playCount
        voice.announceRestoreOutcome(.restored(spaceExact: true), windowID: 7005,
                                     playsSuccessSound: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check("restoreOutcome E1: 语音关 → 零开口但成功音照播",
              mockProvider.synthesizer.startedText == nil
              && mockPlayer.playCount == beforeE + 1)
    }
}

