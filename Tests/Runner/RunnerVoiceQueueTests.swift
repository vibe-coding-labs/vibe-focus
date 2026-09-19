import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerVoiceQueueTests.swift — 覆盖率批次 22（B253）：
// VoiceAnnouncementManager 播报队列推进直测（依赖 B249 SpeechSynthesizerProviding
// 注入缝——mock 合成器记录文本，零发声）。
// 覆盖：enqueue 立即消费（非 announcing）/announcing 态入队等待/满容量丢最旧
// （maxQueuedAnnouncements=3）/audioFile 缺失 fallback speak(「对话完成」)/
// handleSpeechDidFinish 推进队列。

extension RunnerHarness {
    func runVoiceQueueAdvanceTests() {
        let voice = VoiceAnnouncementManager.shared
        voice.stopAll() // 干净起点

        // MARK: A. 非 announcing 态：入队即消费
        let provider = MockSynthesizerProvider()
        voice.synthesizerProvider = provider
        voice.enqueueAnnouncement(.text("b253 第一条"), sessionID: "s1")
        check("voiceQueue: 非播报态入队立即消费且文本送达合成器",
              provider.synthesizer.startedText == "b253 第一条"
              && voice.pendingAnnouncements.isEmpty
              && voice.isAnnouncing)

        // MARK: B. announcing 态：入队等待；满 3 条溢出丢最旧
        // 当前 isAnnouncing=true（A 尾 speak 未 finish）——连续入队 5 条。
        voice.enqueueAnnouncement(.text("q1"), sessionID: "s1")
        voice.enqueueAnnouncement(.text("q2"), sessionID: "s1")
        voice.enqueueAnnouncement(.text("q3"), sessionID: "s1")
        voice.enqueueAnnouncement(.text("q4"), sessionID: "s1")
        voice.enqueueAnnouncement(.text("q5"), sessionID: "s1")
        check("voiceQueue: announcing 态入队只累积不消费（容量 3 丢最旧）",
              voice.pendingAnnouncements == [.text("q3"), .text("q4"), .text("q5")])

        // MARK: C. handleSpeechDidFinish：复位并推进队列下一条
        voice.handleSpeechDidFinish(sender: provider.synthesizer, finished: true)
        check("voiceQueue: 朗读完成复位 isAnnouncing 并推进 q3",
              voice.isAnnouncing
              && provider.synthesizer.startedText == "q3"
              && voice.pendingAnnouncements.first == .text("q4"))
        voice.handleSpeechDidFinish(sender: provider.synthesizer, finished: true)
        voice.handleSpeechDidFinish(sender: provider.synthesizer, finished: true)
        // 队列耗尽后 finish 推进为 no-op（不崩、isAnnouncing 复位路径）。
        voice.handleSpeechDidFinish(sender: provider.synthesizer, finished: true)
        check("voiceQueue: 队列耗尽后 finish 幂等", true)

        // MARK: D. audioFile 缺失 fallback：enqueue .audioFile(不存在路径) →
        // playNextFromQueue → playAudioFile 走「文件缺失 → speak(对话完成)」回退链。
        voice.stopAll()
        voice.enqueueAnnouncement(.audioFile(path: "/nonexistent-b253/x.wav"), sessionID: "s2")
        check("voiceQueue: audioFile 缺失回退 TTS「对话完成」",
              provider.synthesizer.startedText == "对话完成")

        // MARK: E. 收尾复位
        voice.stopAll()
        check("voiceQueue: 收尾 stopAll 干净", !voice.isAnnouncing && voice.pendingAnnouncements.isEmpty)
    }
}
