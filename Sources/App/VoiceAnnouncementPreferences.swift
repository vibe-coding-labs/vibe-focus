import Foundation

// MARK: - 语音播报纯类型层
// 模式枚举、持久化偏好、模板插值纯函数、错误类型。不依赖 AppKit、无状态，
// 插值逻辑由 Tests/Standalone/VoiceAnnouncementTemplateTests.swift fixture 驱动测试。

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

/// 模板变量插值（纯函数命名空间）。
///
/// ## 场景
/// - `VoiceAnnouncementManager` 的 template 播报与 LLM fallback 前的文案生成；
/// - 纯字符串变换，无副作用，fixture 可测（见 Standalone 同名测试）。
///
/// ## 样例
/// ```
/// 模板 "{project_name} 完成"，payload.cwd = "/Users/me/github/vibe-labs"
///   → "vibe-labs 完成"
/// 模板 "{model}@{cwd}"，payload.model = nil → "未知模型@"
/// ```
enum VoiceAnnouncementTemplate {

    /// 将模板中的 {project_name} / {model} / {cwd} / {session_id} 替换为 payload 中的实际值。
    ///
    /// 变量取值规则：project_name 取 claudeProjectDir 的最后一段路径（去首尾 `/`），
    /// 缺失时各变量用「未知项目 / 未知模型 / 空串 / 原样 sessionID」兜底。
    static func interpolate(_ template: String, payload: ClaudeHookPayload) -> String {
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
