import Foundation

// MARK: - 语音播报 LLM 总结路径
// llmSummary 模式的实现：请求 OpenAI 兼容接口对会话做一句话总结，成功 TTS 念出，
// 失败走多级 fallback。播放本体（NSSpeechSynthesizer）在主文件，本文件只做编排与网络。

@MainActor
extension VoiceAnnouncementManager {

    /// 调用 LLM 总结 last_assistant_message，成功后 TTS 念出；失败走 fallback 链。
    ///
    /// ## 场景
    /// - `announceCompletion` / `preview` 的 llmSummary 分支调用（主线程入口，网络在
    ///   后台 Task，hook 响应已同步返回不受影响）；
    /// - 任务句柄存 `llmTask`：新播报或 `stopAll` 时取消（防旧总结覆盖新会话播报）。
    ///
    /// ## 并发约束
    /// - 回主线程应用结果前必须检查 `Task.isCancelled`——stopAll 取消后不得再 speak；
    /// - summarizeAndSpeak 读取配置在主线程完成（llmApiBase/Key/Model 快照进 Task），
    ///   Task 内不读 @Published 偏好（避免跨 actor 竞争）。
    ///
    /// - Parameters:
    ///   - transcriptTail: transcript 近期助手文本（旧→新，B197）——LLM 总结的上下文，
    ///     最后一条消息为空时也用它兜底内容。
    ///   - pendingQuestion: 最后一条以问号结束（B197）——总结被要求点出「等你回复」。
    func summarizeAndSpeak(
        payload: ClaudeHookPayload,
        transcriptTail: [String] = [],
        pendingQuestion: Bool = false
    ) {
        // P-INST-273: LLM 总结请求编排耗时（Task 创建 + requestLLMSummary 网络请求 P-INST-279 + 成功 speak / 失败 speakFallback；announceCompletion P-INST-271 llmSummary 分支；网络请求在后台 Task，hook 响应已同步返回不受影响）。
        let ssStart = Date()
        log("[VoiceAnnouncementManager] summarizeAndSpeak started", fields: [
            "sessionID": payload.sessionID,
            "hasApiKey": String(!preferences.llmApiKey.isEmpty),
            "hasApiBase": String(!preferences.llmApiBase.isEmpty),
            "tailCount": String(transcriptTail.count),
            "pendingQuestion": String(pendingQuestion)
        ])

        var message = payload.lastAssistantMessage ?? ""
        if message.isEmpty {
            // 最后一条消息为空（如纯工具轮后 Stop）——transcript 尾部兜底，
            // 否则直接落 fallback 念不出任何有价值内容。
            message = transcriptTail.joined(separator: "\n")
        }
        let tail = transcriptTail
        let maxChars = preferences.llmMaxChars
        let apiBase = preferences.llmApiBase
        let apiKey = preferences.llmApiKey
        let model = preferences.llmModel

        // 无 API 配置或无消息内容时直接走 fallback
        guard !apiBase.isEmpty, !apiKey.isEmpty, !message.isEmpty else {
            log("[VoiceAnnouncementManager] LLM summary skipped (missing config or message), using fallback", level: .info)
            speakFallback(message: message, maxChars: maxChars, pendingQuestion: pendingQuestion,
                          waitingPrefix: TranscriptTailReader.waitingPrefix(forTranscriptPath: payload.transcriptPath))
            log("[VoiceAnnouncementManager] summarizeAndSpeak finished (fallback)", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: ssStart))
            ])
            return
        }
        // B207：CLI 名随 transcript 来源诚实切换（codex 念「Codex 在等你回复」）。
        let waitingPrefixText = TranscriptTailReader.waitingPrefix(forTranscriptPath: payload.transcriptPath)

        llmTask = Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await self.requestLLMSummary(
                    message: message, apiBase: apiBase, apiKey: apiKey, model: model, maxChars: maxChars,
                    context: tail, pendingQuestion: pendingQuestion
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
                        self.speakFallback(message: message, maxChars: maxChars, pendingQuestion: pendingQuestion,
                                           waitingPrefix: waitingPrefixText)
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
                    self.speakFallback(message: message, maxChars: maxChars, pendingQuestion: pendingQuestion,
                                       waitingPrefix: waitingPrefixText)
                    log("[VoiceAnnouncementManager] summarizeAndSpeak finished (fallback after error)", level: .debug, fields: [
                        "durationMs": String(elapsedMilliseconds(since: ssStart))
                    ])
                }
            }
        }
    }

    /// 请求 OpenAI 兼容的 /chat/completions 接口做一句话总结。
    ///
    /// ## 样例
    /// 请求体：
    /// ```json
    /// {"model": "gpt-4o-mini", "max_tokens": 100, "temperature": 0.3,
    ///  "messages": [{"role": "system", "content": "请用一句话总结…不超过30字"},
    ///               {"role": "user", "content": "<截断到 2000 字的会话内容>"}]}
    /// ```
    /// 响应取 `choices[0].message.content`。
    ///
    /// - Parameters:
    ///   - context: transcript 近期助手文本（旧→新，B197）——拼进 user 内容给总结
    ///     提供上下文，空数组=旧行为只看 message。
    ///   - pendingQuestion: 最后一条以问号结束——system prompt 要求点出「等你回复」。
    /// - Throws: `VoiceAnnouncementError`（invalidAPIBase / invalidResponse /
    ///   httpError(status) / parseError）；网络层错误原样抛出。
    func requestLLMSummary(
        message: String, apiBase: String, apiKey: String, model: String, maxChars: Int,
        context: [String] = [], pendingQuestion: Bool = false
    ) async throws -> String {
        // P-INST-279: LLM API 网络请求耗时（URLSession POST /chat/completions + JSON 解析 choices[0].message.content；summarizeAndSpeak P-INST-273 子阶段；超时 15s，后台 Task 不阻塞 hook 响应）。
        #if PERF_INSTRUMENT
        let rlStart = Date()
        defer {
            log("[VoiceAnnouncementManager] requestLLMSummary finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: rlStart))
            ])
        }
        #endif

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
                ["role": "system", "content": Self.llmSystemPrompt(pendingQuestion: pendingQuestion, maxChars: maxChars)],
                ["role": "user", "content": Self.llmUserContent(message: message, context: context)]
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

    // MARK: - LLM prompt 构造纯函数（B197 提缝，Runner 直测）

    /// system prompt：总结指令 + 待问时「点出等你回复」要求。
    static func llmSystemPrompt(pendingQuestion: Bool, maxChars: Int) -> String {
        var prompt = "请用一句话总结以下 AI 回复，不超过\(maxChars)字。直接输出总结，不加引号或前缀。"
        if pendingQuestion {
            prompt += "AI 正在向用户提问并等待回复，请在总结开头加上「需要你的输入，」。"
        }
        return prompt
    }

    /// user 内容：近期上下文（旧→新）在前，最后一条消息压轴；总量截断 2000 字。
    static func llmUserContent(message: String, context: [String]) -> String {
        var parts = context
        parts.append(message)
        var joined = parts.joined(separator: "\n---\n")
        if joined.count > 2000 {
            joined = String(joined.suffix(2000))
        }
        return joined
    }

    /// Fallback 链：截断 lastAssistantMessage 前 maxChars 字 → 若空念模板 → 若模板空念"对话完成"。
    ///
    /// ## 场景
    /// - LLM 配置缺失、请求失败、返回空总结三种情况的兜底；保证任何路径都有声音反馈。
    /// - pendingQuestion（B197）：等待输入时前置同一措辞提醒，与模板/音频路听感一致。
    ///   B207：waitingPrefix 由调用方按 transcript 来源传入（codex 念「Codex 在等你
    ///   回复」），缺省 Claude 名兼容旧调用（试听路径）。
    func speakFallback(message: String, maxChars: Int, pendingQuestion: Bool = false,
                       waitingPrefix: String = TranscriptTailReader.waitingPrefix) {
        // P-INST-280: 语音播报 fallback 耗时（截断 lastAssistantMessage + speak；LLM 失败时调用）。
        #if PERF_INSTRUMENT
        let sfStart = Date()
        defer {
            log("[VoiceAnnouncementManager] speakFallback finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: sfStart))
            ])
        }
        #endif
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let truncated = trimmed.count > maxChars ? String(trimmed.prefix(maxChars)) : trimmed
            let spoken = pendingQuestion
                ? waitingPrefix + "，" + truncated
                : truncated
            speak(spoken)
            log("[VoiceAnnouncementManager] fallback: speaking truncated lastAssistantMessage", fields: [
                "length": String(truncated.count),
                "pendingQuestion": String(pendingQuestion)
            ])
            return
        }
        if pendingQuestion {
            speak(waitingPrefix)
            log("[VoiceAnnouncementManager] fallback: speaking waiting prefix only")
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
}
