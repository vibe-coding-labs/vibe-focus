// VoiceAnnouncementManager+Queue.swift
// VibeFocus — 语音播报多会话队列编排（第二十二刀）
//
// 职责：template/audioFile 播报的有界入队与串行推进，以及两类发声源的完成回调
// （NSSpeechSynthesizerDelegate / NSSoundDelegate）。队列状态（pendingAnnouncements/
// isAnnouncing）存于主类（Swift extension 不允许存属性）；入队策略纯函数在
// VoiceAnnouncementPreferences.swift（VoiceAnnouncementQueuePolicy），Standalone 测试覆盖。
//
// ## 为什么不再"只播最后一个"（旧行为）
// 旧 announceCompletion 开头 stopAll() 抢占：多会话几乎同时完成时只有最后一条能被
// 听到。新语义：相邻完成的播报串行播放，模板变量（{project_name} 等）提供听感区分；
// 队列有界（maxQueuedAnnouncements=3，满丢最旧），54 远程会话堆叠场景下行为收敛为
// "最近 3 条 + 在播的那条"，不会无限堆积。

import AppKit
import Foundation

@MainActor
extension VoiceAnnouncementManager {

    // MARK: - Enqueue

    /// 有界入队并尝试推进队列。
    ///
    /// ## 场景
    /// - announceCompletion 的 template / audioFile 分支（Stop hook 异步路径，主线程）；
    /// - 满队丢最旧记 info 日志（含被丢条目摘要），丢播报必须在日志可归因。
    ///
    /// ## 并发约束
    /// - 仅主线程（@MainActor）；与 stopAll / 完成回调同队列串行，无竞态。
    func enqueueAnnouncement(_ item: QueuedAnnouncement, sessionID: String) {
        if pendingAnnouncements.count >= Self.maxQueuedAnnouncements {
            let dropped = pendingAnnouncements.removeFirst()
            log("[VoiceAnnouncementManager] announcement queue full, dropping oldest", level: .info, fields: [
                "dropped": dropped.logDescription,
                "incoming": item.logDescription,
                "sessionID": sessionID
            ])
        }
        pendingAnnouncements = VoiceAnnouncementQueuePolicy.appendedQueue(
            pendingAnnouncements,
            appending: item,
            capacity: Self.maxQueuedAnnouncements
        )
        log("[VoiceAnnouncementManager] announcement enqueued", fields: [
            "item": item.logDescription,
            "queueDepth": String(pendingAnnouncements.count),
            "sessionID": sessionID
        ])
        playNextFromQueue()
    }

    // MARK: - Advance

    /// 队列推进闸门：无在播播报时取出队首发声；有在播则等待其完成回调再推进。
    func playNextFromQueue() {
        guard !isAnnouncing else { return }
        guard let next = pendingAnnouncements.first else { return }
        pendingAnnouncements.removeFirst()
        switch next {
        case .text(let text):
            speak(text)
        case .audioFile(let path):
            playAudioFile(path: path)
        }
        log("[VoiceAnnouncementManager] announcement started", fields: [
            "item": next.logDescription,
            "remainingInQueue": String(pendingAnnouncements.count)
        ])
    }

    // MARK: - Completion Handlers

    /// TTS 朗读完成（正常结束或被 stopSpeaking 打断）——复位状态并推进队列。
    /// stopAll 打断时队列已空，推进为 no-op。
    func handleSpeechDidFinish(sender: NSSpeechSynthesizer, finished: Bool) {
        guard sender === activeSynthesizer else { return }
        activeSynthesizer = nil
        isAnnouncing = false
        if !finished {
            log("[VoiceAnnouncementManager] TTS interrupted, advancing queue", level: .debug)
        }
        playNextFromQueue()
    }

    /// 音频播放完成——复位状态并推进队列。
    func handleSoundDidFinish(sender: NSSound, finished: Bool) {
        guard sender === currentSound else { return }
        currentSound = nil
        isAnnouncing = false
        if !finished {
            log("[VoiceAnnouncementManager] audio interrupted, advancing queue", level: .debug)
        }
        playNextFromQueue()
    }
}

// MARK: - Delegate Conformances
// AppKit 在播报开始的线程（主线程）回调 delegate；@MainActor 类的方法对非隔离协议
// 需求以 nonisolated 满足，内部经 Task 跳回 MainActor 访问状态——保证零警告编译。
// sender（NSSound/NSSpeechSynthesizer）非 Sendable：AppKit 保证回调发生在主线程，
// nonisolated(unsafe) 绑定仅为通过跨隔离捕获检查（仓库既有模式，见 SettingsView+Helpers），
// 实际语义仍是同一线程，无数据竞争。

extension VoiceAnnouncementManager: NSSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finished: Bool) {
        nonisolated(unsafe) let sender = sender
        Task { @MainActor in
            self.handleSpeechDidFinish(sender: sender, finished: finished)
        }
    }
}

extension VoiceAnnouncementManager: NSSoundDelegate {
    nonisolated func sound(_ sender: NSSound, didFinishPlaying finished: Bool) {
        Task { @MainActor in
            self.handleSoundDidFinish(sender: sender, finished: finished)
        }
    }
}

// MARK: - Log Support

extension QueuedAnnouncement {
    /// 队列条目的日志摘要（路径只取末段，文本截前 30 字）
    var logDescription: String {
        switch self {
        case .text(let text):
            return "text(\(text.prefix(30)))"
        case .audioFile(let path):
            return "audio(\(path.split(separator: "/").last ?? "?"))"
        }
    }
}
