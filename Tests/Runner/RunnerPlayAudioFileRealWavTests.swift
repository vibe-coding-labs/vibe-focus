import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerPlayAudioFileRealWavTests.swift — 覆盖率批次 58（B296）：
// playAudioFile 三路径直测（真静音 WAV + B249 mock 合成器拦截 fallback）。
//
// 与 B295 的差异：放弃 NSSound 子类化（SIGSEGV 根因），改用「真静音 WAV 文件 +
// 真 NSSound 加载播放」——数据全零无可闻输出，音频管线真实走通零打扰；
// fallback 路径经 B249 SpeechSynthesizerProviding 注入 mock 合成器拦截。

/// 生成合法最小 16-bit PCM WAV（0.05s 静音，数据全零无可闻输出）。
private func makeSilentWav() -> Data {
    var data = Data()
    let sampleRate = 8000
    let samples = 400
    let dataSize = samples * 2
    func append(_ s: String) { data.append(contentsOf: s.utf8) }
    func appendUInt32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func appendUInt16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    append("RIFF"); appendUInt32(UInt32(36 + dataSize)); append("WAVE")
    append("fmt "); appendUInt32(16); appendUInt16(1)
    appendUInt16(1); appendUInt32(UInt32(sampleRate))
    appendUInt32(UInt32(sampleRate * 2)); appendUInt16(2); appendUInt16(16)
    append("data"); appendUInt32(UInt32(dataSize))
    data.append(contentsOf: repeatElement(0, count: dataSize))
    return data
}

extension RunnerHarness {
    func runPlayAudioFileRealWavTests() {
        let voice = VoiceAnnouncementManager.shared
        voice.stopAll() // 干净起点
        defer { voice.stopAll() }

        // B249 注入缝：mock 合成器拦截 fallback speak（零真发声）。
        let provider = MockSynthesizerProvider()
        voice.synthesizerProvider = provider
        defer { voice.synthesizerProvider = AppSpeechSynthesizerProvider() }

        let wavPath = NSTemporaryDirectory() + "b296-silent.wav"
        FileManager.default.createFile(atPath: wavPath, contents: makeSilentWav())

        // ①真静音 WAV：加载成功走播放终点（音频管线走通，静音数据无可闻输出）。
        voice.playAudioFile(path: wavPath)
        check("playAudioFileReal: 真静音 WAV 播放走通且 isAnnouncing",
              voice.isAnnouncing && voice.currentSound != nil)
        voice.stopAll()

        // ②路径不存在 → fallback speak(「对话完成」)。
        voice.playAudioFile(path: "/nonexistent-b296/x.wav")
        check("playAudioFileReal: 路径缺失 fallback 送达合成器",
              provider.synthesizer.startedText == "对话完成")
        voice.stopAll()

        // ③文件存在但内容非法（文本冒充 wav）→ 解码失败 → fallback。
        let junkPath = NSTemporaryDirectory() + "b296-junk.wav"
        FileManager.default.createFile(atPath: junkPath, contents: Data("not audio".utf8))
        voice.playAudioFile(path: junkPath)
        check("playAudioFileReal: 非法音频解码失败 fallback 送达合成器",
              provider.synthesizer.startedText == "对话完成")
        try? FileManager.default.removeItem(atPath: wavPath)
        try? FileManager.default.removeItem(atPath: junkPath)
        voice.stopAll()
    }
}
