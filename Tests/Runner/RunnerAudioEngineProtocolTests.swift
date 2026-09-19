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
}
