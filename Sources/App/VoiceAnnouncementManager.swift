import AppKit
import Foundation

// MARK: - Voice Announcement Mode

/// 语音播报模式：会话/回合完成时如何播报
enum VoiceAnnouncementMode: String, CaseIterable, Codable {
    /// 不播报
    case none
    /// 固定文案模板（支持 {project_name} 等变量插值）
    case template
    /// 本地音频文件
    case audioFile
    /// LLM 总结（配 API key，对会话做一句话总结再 TTS 念出）
    case llmSummary

    var displayName: String {
        switch self {
        case .none: return "无"
        case .template: return "固定文案"
        case .audioFile: return "本地音频"
        case .llmSummary: return "LLM 总结"
        }
    }
}

// MARK: - Voice Announcement Preferences

/// 持久化的语音播报偏好，通过 UserDefaults 存储（JSON 编码）
struct VoiceAnnouncementPreferences: Codable {
    var mode: VoiceAnnouncementMode
    /// 固定文案模板，支持 {project_name} / {model} / {cwd} / {session_id} 变量插值
    var templateText: String
    /// 本地音频文件路径（wav/mp3/m4a/aiff）
    var audioFilePath: String?
    /// TTS 音量（0.0~1.0）与音频文件播放音量
    var volume: Float
    /// NSSpeechSynthesizer 语速（100~300，默认 180）
    var speechRate: Float
    /// OpenAI 兼容 API base URL，如 https://api.openai.com/v1
    var llmApiBase: String
    /// LLM API key（明文存 UserDefaults，与项目其他偏好一致）
    var llmApiKey: String
    /// LLM 模型名
    var llmModel: String
    /// LLM 总结最大字数（也用于 fallback 截断）
    var llmMaxChars: Int

    static let `default` = VoiceAnnouncementPreferences(
        mode: .none,
        templateText: "{project_name} 完成",
        audioFilePath: nil,
        volume: 0.7,
        speechRate: 180,
        llmApiBase: "",
        llmApiKey: "",
        llmModel: "gpt-4o-mini",
        llmMaxChars: 30
    )
}

// MARK: - Voice Announcement Manager

/// 会话完成语音播报管理器。
///
/// 在 ClaudeHookServer 的 Stop 事件分支中被无条件异步触发（与移窗逻辑解耦），
/// 按 preferences.mode 分发到模板插值 TTS / 本地音频 / LLM 总结 TTS 三种模式。
/// 镜像 SoundManager 的偏好持久化模式：@Published private(set) + didSet→savePreferences()，
/// init 只读不写（遵守偏好持久化铁律）。
@MainActor
final class VoiceAnnouncementManager: ObservableObject {
    static let shared = VoiceAnnouncementManager()

    private static let preferencesKey = "voiceAnnouncementPreferences"

    @Published private(set) var preferences: VoiceAnnouncementPreferences {
        didSet {
            // P-INST-269: 语音播报偏好变更触发持久化入口（savePreferences P-INST-270 JSONEncoder+UserDefaults 写；偏好 UI 变更触发 didSet，归因持久化触发频率；slow-op ≥5ms warn）。
            let dslStart = Date()
            defer {
                let durMs = elapsedMilliseconds(since: dslStart)
                if durMs >= 5 { log("[VoiceAnnouncementManager] preferences didSet→save slow", level: .warn, fields: ["durationMs": String(durMs)]) }
            }
            savePreferences()
        }
    }

    private var speechSynthesizer: NSSpeechSynthesizer?
    private var currentSound: NSSound?
    /// 当前进行中的 LLM 请求任务，新播报或 stopAll 时取消
    private var llmTask: Task<Void, Never>?

    private init() {
        self.preferences = Self.loadPreferences()
    }

    // MARK: - Public API

    /// 会话完成时触发语音播报（由 ClaudeHookServer Stop 分支异步调用）。
    /// 无条件入口：mode == .none 直接返回。开头先 stopAll() 防重入。
    func announceCompletion(payload: ClaudeHookPayload) {
        // P-INST-271: 语音播报完成触发总耗时（按 mode 分发 template/audioFile/llmSummary；Stop hook 异步 fire-and-forget 路径，不阻塞 hook 响应；LLM 模式含网络请求 P-INST-273）。
        let acStart = Date()
        defer {
            log("[VoiceAnnouncementManager] announceCompletion finished", level: .debug, fields: [
                "mode": preferences.mode.rawValue,
                "sessionID": payload.sessionID,
                "durationMs": String(elapsedMilliseconds(since: acStart))
            ])
        }
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
            let text = interpolateTemplate(preferences.templateText, payload: payload)
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

    /// UI 试听：用当前偏好播报一次（用一个合成的假 payload 填充变量）
    func preview() {
        // P-INST-272: 语音播报试听耗时（按 mode 分发；设置 UI 试听按钮调用；LLM 模式含网络请求 P-INST-273）。
        let pvStart = Date()
        defer {
            log("[VoiceAnnouncementManager] preview finished", level: .debug, fields: [
                "mode": preferences.mode.rawValue,
                "durationMs": String(elapsedMilliseconds(since: pvStart))
            ])
        }
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
            let text = interpolateTemplate(preferences.templateText, payload: fakePayload)
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
    func stopAll() {
        // P-INST-274: 语音播报停止耗时（NSSpeechSynthesizer.stopSpeaking + NSSound.stop + llmTask.cancel；announceCompletion 防重入 + UI 停止按钮调用）。
        let saStart = Date()
        defer {
            log("[VoiceAnnouncementManager] stopAll finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: saStart))
            ])
        }
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
        let uapStart = Date()
        defer {
            log("[VoiceAnnouncementManager] updateAudioFilePath finished", level: .debug, fields: [
                "hasPath": String(path != nil),
                "durationMs": String(elapsedMilliseconds(since: uapStart))
            ])
        }
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

    // MARK: - Template Interpolation

    /// 将模板中的 {project_name} / {model} / {cwd} / {session_id} 替换为 payload 中的实际值
    private func interpolateTemplate(_ template: String, payload: ClaudeHookPayload) -> String {
        // P-INST-276: 模板变量插值耗时（字符串替换；announceCompletion P-INST-271 template 分支 + preview P-INST-272 子阶段；纯内存操作通常 <1ms）。
        let itStart = Date()
        defer {
            log("[VoiceAnnouncementManager] interpolateTemplate finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: itStart))
            ])
        }
        let projectName = payload.terminalCtx?.claudeProjectDir?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .components(separatedBy: "/").last
            ?? "未知项目"
        let model = payload.model ?? "未知模型"
        let cwd = payload.cwd ?? ""
        let sessionID = payload.sessionID

        return template
            .replacingOccurrences(of: "{project_name}", with: projectName)
            .replacingOccurrences(of: "{model}", with: model)
            .replacingOccurrences(of: "{cwd}", with: cwd)
            .replacingOccurrences(of: "{session_id}", with: sessionID)
    }

    // MARK: - TTS (NSSpeechSynthesizer)

    /// 用 NSSpeechSynthesizer 朗读文本
    private func speak(_ text: String) {
        // P-INST-277: TTS 朗读耗时（NSSpeechSynthesizer 构造 + set rate/volume + startSpeaking；announceCompletion P-INST-271 / preview P-INST-272 / summarizeAndSpeak 子阶段；startSpeaking 异步但合成器构造在调用线程）。
        let spStart = Date()
        defer {
            log("[VoiceAnnouncementManager] speak finished", level: .debug, fields: [
                "textLength": String(text.count),
                "durationMs": String(elapsedMilliseconds(since: spStart))
            ])
        }
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

    /// 播放本地音频文件
    private func playAudioFile(path: String) {
        // P-INST-278: 本地音频播放耗时（NSSound(contentsOfFile:byReference:) 加载解码 + play；announceCompletion P-INST-271 audioFile 分支 / preview P-INST-272 子阶段；音频解码在调用线程可阻塞）。
        let pfStart = Date()
        defer {
            log("[VoiceAnnouncementManager] playAudioFile finished", level: .debug, fields: [
                "path": path,
                "durationMs": String(elapsedMilliseconds(since: pfStart))
            ])
        }
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

    // MARK: - LLM Summary

    /// 调用 LLM 总结 last_assistant_message，成功后 TTS 念出；失败走 fallback 链
    private func summarizeAndSpeak(payload: ClaudeHookPayload) {
        // P-INST-273: LLM 总结请求编排耗时（Task 创建 + requestLLMSummary 网络请求 P-INST-279 + 成功 speak / 失败 speakFallback；announceCompletion P-INST-271 llmSummary 分支；网络请求在后台 Task，hook 响应已同步返回不受影响）。
        let ssStart = Date()
        log("[VoiceAnnouncementManager] summarizeAndSpeak started", fields: [
            "sessionID": payload.sessionID,
            "hasApiKey": String(!preferences.llmApiKey.isEmpty),
            "hasApiBase": String(!preferences.llmApiBase.isEmpty)
        ])

        let message = payload.lastAssistantMessage ?? ""
        let maxChars = preferences.llmMaxChars
        let apiBase = preferences.llmApiBase
        let apiKey = preferences.llmApiKey
        let model = preferences.llmModel

        // 无 API 配置或无消息内容时直接走 fallback
        guard !apiBase.isEmpty, !apiKey.isEmpty, !message.isEmpty else {
            log("[VoiceAnnouncementManager] LLM summary skipped (missing config or message), using fallback", level: .info)
            speakFallback(message: message, maxChars: maxChars)
            log("[VoiceAnnouncementManager] summarizeAndSpeak finished (fallback)", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: ssStart))
            ])
            return
        }

        llmTask = Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await self.requestLLMSummary(
                    message: message, apiBase: apiBase, apiKey: apiKey, model: model, maxChars: maxChars
                )
                let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D}\u{2018}\u{2019}"))
                let resolved = trimmed.isEmpty ? nil : trimmed
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    if let resolved {
                        self.speak(resolved)
                        log("[VoiceAnnouncementManager] LLM summary spoken", fields: [
                            "summary": String(resolved.prefix(60)),
                            "sessionID": payload.sessionID
                        ])
                    } else {
                        self.speakFallback(message: message, maxChars: maxChars)
                    }
                    log("[VoiceAnnouncementManager] summarizeAndSpeak finished", level: .debug, fields: [
                        "durationMs": String(elapsedMilliseconds(since: ssStart))
                    ])
                }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    log("[VoiceAnnouncementManager] LLM summary failed, using fallback", level: .warn, fields: [
                        "error": error.localizedDescription,
                        "sessionID": payload.sessionID
                    ])
                    self.speakFallback(message: message, maxChars: maxChars)
                    log("[VoiceAnnouncementManager] summarizeAndSpeak finished (fallback after error)", level: .debug, fields: [
                        "durationMs": String(elapsedMilliseconds(since: ssStart))
                    ])
                }
            }
        }
    }

    /// 请求 OpenAI 兼容的 /chat/completions 接口做一句话总结
    private func requestLLMSummary(
        message: String, apiBase: String, apiKey: String, model: String, maxChars: Int
    ) async throws -> String {
        // P-INST-279: LLM API 网络请求耗时（URLSession POST /chat/completions + JSON 解析 choices[0].message.content；summarizeAndSpeak P-INST-273 子阶段；超时 15s，后台 Task 不阻塞 hook 响应）。
        let rlStart = Date()
        defer {
            log("[VoiceAnnouncementManager] requestLLMSummary finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: rlStart))
            ])
        }

        // 截断消息到 2000 字，避免超长输入
        let truncated: String
        if message.count > 2000 {
            truncated = String(message.prefix(2000))
        } else {
            truncated = message
        }

        let baseURL = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw VoiceAnnouncementError.invalidAPIBase
        }

        var request = URLRequest(url: url, timeoutInterval: 15.0)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "system",
                    "content": "请用一句话总结以下 AI 回复，不超过\(maxChars)字。直接输出总结，不加引号或前缀。"
                ],
                ["role": "user", "content": truncated]
            ],
            "max_tokens": 100,
            "temperature": 0.3
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VoiceAnnouncementError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw VoiceAnnouncementError.httpError(http.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let msg = firstChoice["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw VoiceAnnouncementError.parseError
        }
        return content
    }

    /// Fallback 链：截断 lastAssistantMessage 前 maxChars 字 → 若空念模板 → 若模板空念"对话完成"
    private func speakFallback(message: String, maxChars: Int) {
        // P-INST-280: 语音播报 fallback 耗时（截断 lastAssistantMessage + speak；LLM 失败时调用）。
        let sfStart = Date()
        defer {
            log("[VoiceAnnouncementManager] speakFallback finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: sfStart))
            ])
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let truncated = trimmed.count > maxChars ? String(trimmed.prefix(maxChars)) : trimmed
            speak(truncated)
            log("[VoiceAnnouncementManager] fallback: speaking truncated lastAssistantMessage", fields: [
                "length": String(truncated.count)
            ])
            return
        }
        // 消息为空时念模板
        let template = preferences.templateText
        if !template.isEmpty {
            // fallback 时无 payload 上下文，直接念模板原文（变量不替换）
            speak(template)
            log("[VoiceAnnouncementManager] fallback: speaking template text")
            return
        }
        speak("对话完成")
    }

    // MARK: - Persistence

    private func savePreferences() {
        // P-INST-270: 语音播报偏好持久化耗时（JSONEncoder.encode + UserDefaults.standard.set 写；VoiceAnnouncementPreferences didSet 触发，设置 UI 改动写）。
        let spStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: spStart)
            if durMs >= 5 { log("[VoiceAnnouncementManager] savePreferences slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        do {
            let data = try JSONEncoder().encode(preferences)
            UserDefaults.standard.set(data, forKey: Self.preferencesKey)
        } catch {
            log("[VoiceAnnouncementManager] failed to save preferences", level: .error, fields: [
                "error": error.localizedDescription
            ])
        }
    }

    private static func loadPreferences() -> VoiceAnnouncementPreferences {
        // P-INST-281: 语音播报偏好加载耗时（UserDefaults.standard.data 读 + JSONDecoder.decode；启动加载 + 偏好变更；slow-op ≥5ms warn）。
        let lpStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: lpStart)
            if durMs >= 5 { log("[VoiceAnnouncementManager] loadPreferences slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        guard let data = UserDefaults.standard.data(forKey: preferencesKey) else {
            return .default
        }
        do {
            return try JSONDecoder().decode(VoiceAnnouncementPreferences.self, from: data)
        } catch {
            log("[VoiceAnnouncementManager] failed to decode preferences, using defaults", level: .warn, fields: [
                "error": error.localizedDescription
            ])
            return .default
        }
    }
}

// MARK: - Voice Announcement Errors

enum VoiceAnnouncementError: LocalizedError {
    case invalidAPIBase
    case invalidResponse
    case httpError(Int)
    case parseError

    var errorDescription: String? {
        switch self {
        case .invalidAPIBase: return "无效的 API Base URL"
        case .invalidResponse: return "无效的 API 响应"
        case .httpError(let code): return "API 请求失败（HTTP \(code)）"
        case .parseError: return "无法解析 API 响应"
        }
    }
}
