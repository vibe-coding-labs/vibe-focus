import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerVoiceAnnouncementTests.swift — B216：语音播报 LLM prompt 构造纯函数
// 直测（B197 提缝的 llmSystemPrompt / llmUserContent 此前 0 覆盖——pendingQuestion 分支
// 与 2000 字截断是播报文案的最终形态，锁死防漂移）。

extension RunnerHarness {
    func runVoiceAnnouncementTests() {
        // ===== llmSystemPrompt：总结指令 + 待问前缀分支 =====
        let base = VoiceAnnouncementManager.llmSystemPrompt(pendingQuestion: false, maxChars: 30)
        check("voice: system prompt 含字数上限", base.contains("不超过30字") && base.contains("一句话总结"))
        check("voice: 非待问不带前缀要求", !base.contains("需要你的输入"))
        let waiting = VoiceAnnouncementManager.llmSystemPrompt(pendingQuestion: true, maxChars: 30)
        check("voice: 待问分支要求点出等你回复", waiting.contains("需要你的输入，"))
        check("voice: 待问 prompt 含基础指令", waiting.contains("不超过30字"))

        // ===== llmUserContent：上下文在前消息压轴 + 2000 字截断 =====
        let plain = VoiceAnnouncementManager.llmUserContent(message: "最后一条", context: [])
        check("voice: 无上下文 → 纯消息", plain == "最后一条")
        let joined = VoiceAnnouncementManager.llmUserContent(message: "压轴", context: ["旧一", "旧二"])
        check("voice: 上下文 --- 分隔且消息压轴", joined == "旧一\n---\n旧二\n---\n压轴")

        let long = String(repeating: "字", count: 2500)
        let truncated = VoiceAnnouncementManager.llmUserContent(message: long, context: [])
        check("voice: 超 2000 字截断保留尾部", truncated.count == 2000
              && truncated.hasSuffix(String(repeating: "字", count: 2000)))
        // 截断后尾部仍是最后一条消息（压轴语义在截断下也成立）
        let tailCheck = VoiceAnnouncementManager.llmUserContent(message: "TAIL-MARK", context: [String(repeating: "c", count: 2100)])
        check("voice: 截断保留末尾消息标记", tailCheck.count == 2000 && tailCheck.hasSuffix("TAIL-MARK"))
    }
}
