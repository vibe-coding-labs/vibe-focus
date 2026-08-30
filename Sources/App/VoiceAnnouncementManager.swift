import AppKit
import Foundation

// MARK: - 语音播报主文件（编排 + TTS 播放 + 持久化）
// 文件分层（2026-08-31 拆分，行为不变）：
//   VoiceAnnouncementManager.swift（本文件）       — 播报编排（announce/preview/stopAll）、
//                                                   偏好更新 API、TTS/音频播放、持久化
//   VoiceAnnouncementPreferences.swift             — 模式枚举/偏好/模板插值纯函数/错误类型
//   VoiceAnnouncementManager+LLMSummary.swift      — llmSummary 模式（请求编排/网络/fallback 链）

/// 会话完成语音播报管理器。
///
/// 在 ClaudeHookServer 的 Stop 事件分支中被无条件异步触发（与移窗逻辑解耦），
/// 按 preferences.mode 分发到模板插值 TTS / 本地音频 / LLM 总结 TTS 三种模式。
/// 镜像 SoundManager 的偏好持久化模式：@Published private(set) + didSet→savePreferences()，
/// init 只读不写（遵守偏好持久化铁律）。
@MainActor
final class VoiceAnnouncementManager: ObservableObject {
    static let shared = VoiceAnnouncementManager()

    /// UserDefaults key。internal：由 +Persistence.swift（跨文件 extension）读写。
    static let preferencesKey = "voiceAnnouncementPreferences"

    @Published private(set) var preferences: VoiceAnnouncementPreferences {
        didSet {
            // P-INST-269: 语音播报偏好变更触发持久化入口（savePreferences P-INST-270 JSONEncoder+UserDefaults 写；偏好 UI 变更触发 didSet，归因持久化触发频率；slow-op ≥5ms warn）。
            #if PERF_INSTRUMENT
            let dslStart = Date()
            defer {
                let durMs = elapsedMilliseconds(since: dslStart)
                if durMs >= 5 { log("[VoiceAnnouncementManager] preferences didSet→save slow", level: .warn, fields: ["durationMs": String(durMs)]) }
            }
            #endif
            savePreferences()
        }
    }

    private var speechSynthesizer: NSSpeechSynthesizer?
    private var currentSound: NSSound?
    /// 当前进行中的 LLM 请求任务，新播报或 stopAll 时取消。
    /// internal：由 VoiceAnnouncementManager+LLMSummary.swift（跨文件 extension）写入。
    var llmTask: Task<Void, Never>?

    private init() {
        self.preferences = Self.loadPreferences()
    }

    // MARK: - Public API

    /// 会话完成时触发语音播报（由 ClaudeHookServer Stop 分支异步调用）。
    /// 无条件入口：mode == .none 直接返回。开头先 stopAll() 防重入。
    ///
    /// ## 场景
    /// - ClaudeHookServer 收到 Stop 事件的 fire-and-forget 异步路径，不阻塞 hook 响应；
    /// - 防重入：连续多次 Stop（多会话并发完成）时只播最后一个——先 stopAll 停掉
    ///   上一次播放并取消上一次 LLM 请求。
    func announceCompletion(payload: ClaudeHookPayload) {
        // P-INST-271: 语音播报完成触发总耗时（按 mode 分发 template/audioFile/llmSummary；Stop hook 异步 fire-and-forget 路径，不阻塞 hook 响应；LLM 模式含网络请求 P-INST-273）。
        #if PERF_INSTRUMENT
        let acStart = Date()
        defer {
            log("[VoiceAnnouncementManager] announceCompletion finished", level: .debug, fields: [
                "mode": preferences.mode.rawValue,
                "sessionID": payload.sessionID,
                "durationMs": String(elapsedMilliseconds(since: acStart))
            ])
        }
        #endif
        guard preferences.mode != .none else {
            log("[VoiceAnnouncementManager] mode is none, skipping announcement")
            return
        }

        // 防重入：停掉上一次播放 / 取消上一次 LLM 请求
        stopAll()

        switch preferences.mode {
        case .none:
            return
        case .template:
            let text = VoiceAnnouncementTemplate.interpolate(preferences.templateText, payload: payload)
            let resolved = text.isEmpty ? "对话完成" : text
            speak(resolved)
            log("[VoiceAnnouncementManager] template announcement", fields: [
                "text": resolved,
                "sessionID": payload.sessionID
            ])
        case .audioFile:
            guard let path = preferences.audioFilePath, !path.isEmpty else {
                log("[VoiceAnnouncementManager] audioFile mode but path empty, falling back", level: .warn)
                speak("对话完成")
                return
            }
            playAudioFile(path: path)
            log("[VoiceAnnouncementManager] audioFile announcement", fields: [
                "path": path,
                "sessionID": payload.sessionID
            ])
        case .llmSummary:
            summarizeAndSpeak(payload: payload)
        }
    }

    /// UI 试听：用当前偏好播报一次（用一个合成的假 payload 填充变量）。
    ///
    /// ## 场景
    /// - 设置界面「试听」按钮调用；LLM 模式会真实发起网络请求（15s 超时）。
    func preview() {
        // P-INST-272: 语音播报试听耗时（按 mode 分发；设置 UI 试听按钮调用；LLM 模式含网络请求 P-INST-273）。
        #if PERF_INSTRUMENT
        let pvStart = Date()
        defer {
            log("[VoiceAnnouncementManager] preview finished", level: .debug, fields: [
                "mode": preferences.mode.rawValue,
                "durationMs": String(elapsedMilliseconds(since: pvStart))
            ])
        }
        #endif
        guard preferences.mode != .none else { return }
        stopAll()

        // 试听用的合成 payload（填入变量默认值）
        let fakePayload = ClaudeHookPayload(
            event: .stop,
            sessionID: "preview-session",
            source: "preview",
            timestamp: nil,
            cwd: FileManager.default.currentDirectoryPath,
            model: "preview-model",
            terminalCtx: TerminalContext(
                termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
                weztermPane: nil, tty: nil, ppid: nil,
                claudeProjectDir: FileManager.default.currentDirectoryPath,
                windowID: nil, machineLabel: nil
            ),
            lastAssistantMessage: "这是一段用于试听的示例 AI 回复内容。",
            transcriptPath: nil
        )

        switch preferences.mode {
        case .none:
            return
        case .template:
            let text = VoiceAnnouncementTemplate.interpolate(preferences.templateText, payload: fakePayload)
            speak(text.isEmpty ? "对话完成" : text)
        case .audioFile:
            guard let path = preferences.audioFilePath, !path.isEmpty else {
                speak("未选择音频文件")
                return
            }
            playAudioFile(path: path)
        case .llmSummary:
            summarizeAndSpeak(payload: fakePayload)
        }
    }

    /// 停止所有播放与进行中的 LLM 请求
    ///
    /// ## 场景
    /// - announceCompletion/preview 开头防重入 + 设置界面停止按钮。
    func stopAll() {
        // P-INST-274: 语音播报停止耗时（NSSpeechSynthesizer.stopSpeaking + NSSound.stop + llmTask.cancel；announceCompletion 防重入 + UI 停止按钮调用）。
        #if PERF_INSTRUMENT
        let saStart = Date()
        defer {
            log("[VoiceAnnouncementManager] stopAll finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: saStart))
            ])
        }
        #endif
        speechSynthesizer?.stopSpeaking()
        speechSynthesizer = nil
        currentSound?.stop()
        currentSound = nil
        llmTask?.cancel()
        llmTask = nil
    }

    // MARK: - Update API（每个赋值触发 didSet→持久化）

    func updateMode(_ mode: VoiceAnnouncementMode) {
        preferences.mode = mode
    }

    func updateTemplateText(_ text: String) {
        preferences.templateText = text
    }

    func updateAudioFilePath(_ path: String?) {
        // P-INST-275: 音频文件路径更新耗时（preferences.audioFilePath didSet 持久化写；设置 UI 选择/清除文件按钮调用）。
        #if PERF_INSTRUMENT
        let uapStart = Date()
        defer {
            log("[VoiceAnnouncementManager] updateAudioFilePath finished", level: .debug, fields: [
                "hasPath": String(path != nil),
                "durationMs": String(elapsedMilliseconds(since: uapStart))
            ])
        }
        #endif
        preferences.audioFilePath = path
    }

    func updateVolume(_ volume: Float) {
        preferences.volume = volume
    }

    func updateSpeechRate(_ rate: Float) {
        preferences.speechRate = rate
    }

    func updateLLMApiBase(_ base: String) {
        preferences.llmApiBase = base
    }

    func updateLLMApiKey(_ key: String) {
        preferences.llmApiKey = key
    }

    func updateLLMModel(_ model: String) {
        preferences.llmModel = model
    }

    func updateLLMMaxChars(_ maxChars: Int) {
        preferences.llmMaxChars = maxChars
    }

    // MARK: - TTS (NSSpeechSynthesizer)

    /// 用 NSSpeechSynthesizer 朗读文本。
    /// internal：由 VoiceAnnouncementManager+LLMSummary.swift（跨文件 extension）调用。
    ///
    /// ## 场景
    /// - template / llmSummary / fallback 三种文案来源共用的最终发声口；
    /// - 空文本静默跳过（fallback 链末端已保证非空，此处再防御）。
    func speak(_ text: String) {
        // P-INST-277: TTS 朗读耗时（NSSpeechSynthesizer 构造 + set rate/volume + startSpeaking；announceCompletion P-INST-271 / preview P-INST-272 / summarizeAndSpeak 子阶段；startSpeaking 异步但合成器构造在调用线程）。
        #if PERF_INSTRUMENT
        let spStart = Date()
        defer {
            log("[VoiceAnnouncementManager] speak finished", level: .debug, fields: [
                "textLength": String(text.count),
                "durationMs": String(elapsedMilliseconds(since: spStart))
            ])
        }
        #endif
        guard !text.isEmpty else {
            log("[VoiceAnnouncementManager] speak: empty text, skipping")
            return
        }
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.rate = preferences.speechRate
        synthesizer.volume = preferences.volume
        speechSynthesizer = synthesizer
        synthesizer.startSpeaking(text)
        log("[VoiceAnnouncementManager] TTS speaking", fields: [
            "rate": String(preferences.speechRate),
            "volume": String(preferences.volume),
            "textPreview": String(text.prefix(40))
        ])
    }

    /// 播放本地音频文件；文件缺失或解码失败回退 TTS「对话完成」。
    private func playAudioFile(path: String) {
        // P-INST-278: 本地音频播放耗时（NSSound(contentsOfFile:byReference:) 加载解码 + play；announceCompletion P-INST-271 audioFile 分支 / preview P-INST-272 子阶段；音频解码在调用线程可阻塞）。
        #if PERF_INSTRUMENT
        let pfStart = Date()
        defer {
            log("[VoiceAnnouncementManager] playAudioFile finished", level: .debug, fields: [
                "path": path,
                "durationMs": String(elapsedMilliseconds(since: pfStart))
            ])
        }
        #endif
        guard FileManager.default.fileExists(atPath: path) else {
            log("[VoiceAnnouncementManager] audio file not found: \(path)", level: .warn)
            speak("对话完成")
            return
        }
        guard let sound = NSSound(contentsOfFile: path, byReference: false) else {
            log("[VoiceAnnouncementManager] failed to load audio: \(path)", level: .warn)
            speak("对话完成")
            return
        }
        sound.volume = preferences.volume
        sound.play()
        currentSound = sound
        log("[VoiceAnnouncementManager] playing audio file", fields: [
            "path": path,
            "volume": String(preferences.volume)
        ])
    }

    // MARK: - Persistence

    // 偏好读写已拆至 VoiceAnnouncementManager+Persistence.swift：
    // savePreferences()（didSet 触发）与 loadPreferences()（init 调用，internal 供跨文件）。
}
