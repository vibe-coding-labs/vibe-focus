// Tests/Runner/RunnerBubbleAutoShowOrchestrationTests.swift
// B230 覆盖堆叠·气泡自动弹出编排守卫路：InputBubbleAutoShow 的 seedBaselines（只读
// CGWindowList 扫描+基线簿记）与 tick（autoShowOnFocus 钉 false 强制走 skipNotEnabled
// 守卫路——绝不触发 controller.summon() 真弹气泡）；VoiceAnnouncementManager+LLMSummary
// 的 summarizeAndSpeak 无配置/空消息 fallback 路（speak 空文本守卫兜底=全程静默）。

import AppKit
import Foundation
@testable import VibeFocusKit

extension RunnerHarness {

    func runBubbleAutoShowOrchestrationTests() {
        print("\n=== BubbleAutoShowOrchestration (B230) ===")
        let autoshow = InputBubbleAutoShow.shared

        // 出声/弹出安全闸：focus 自动弹出钉 false（Runner 自有 defaults 域，测后还原），
        // tick 的门判定必落 .skipNotEnabled——summon 分支结构性不可达
        let savedAutoShowFocus = InputBubblePreferences.autoShowOnFocus
        InputBubblePreferences.autoShowOnFocus = false
        defer { InputBubblePreferences.autoShowOnFocus = savedAutoShowFocus }

        // 基线全量播种：只读扫描当前全部 onscreen 常规窗（含用户窗口——纯读零副作用）
        autoshow.seedBaselines()
        check("autoShow: seedBaselines 只读扫描不崩溃", true)

        // tick 驱动（当前前台多半非终端→skipNotTerminal；即便前台是终端，
        // autoShowOnFocus=false 也必落 skipNotEnabled）——两条守卫路都不弹
        autoshow.tick()
        check("autoShow: tick 关开关守卫路不弹不崩溃", true)
        autoshow.tick()
        check("autoShow: tick 二连（同窗/未启用守卫幂等）", true)
    }

    func runLLMSummaryFallbackTests() {
        print("\n=== LLMSummaryFallback (B230) ===")
        let vam = VoiceAnnouncementManager.shared

        // 出声安全：Runner 域 LLM 配置为默认空（llmApiBase/llmApiKey 空）→
        // guard 必落 fallback；消息=空（无 lastAssistantMessage+无 tail）→
        // speakFallback 最终 speak("") 被空文本守卫拦下=全程静默。
        // 用 VoiceQueue 同款在播闸双保险：isAnnouncing=true 期间队列推进短路。
        vam.isAnnouncing = true
        vam.pendingAnnouncements = []
        let payload = ClaudeHookPayload(
            event: .stop, sessionID: "b230-llm", source: nil, timestamp: nil,
            cwd: "/tmp/b230", model: nil, terminalCtx: nil,
            lastAssistantMessage: nil, transcriptPath: nil, message: nil
        )
        vam.summarizeAndSpeak(payload: payload, transcriptTail: [], pendingQuestion: false)
        check("llmSummary: 无配置+空消息 fallback 静默早退",
              vam.pendingAnnouncements.isEmpty && vam.llmTask == nil)

        // codex transcript 嗅探变体（waitingPrefix 按 / codex/ 路径切换文案）——同样空消息静默
        let codexPayload = ClaudeHookPayload(
            event: .stop, sessionID: "b230-llm-codex", source: nil, timestamp: nil,
            cwd: "/tmp/b230", model: nil, terminalCtx: nil,
            lastAssistantMessage: nil, transcriptPath: "/tmp/.codex/sessions/rollout-b230.jsonl",
            message: nil
        )
        vam.summarizeAndSpeak(payload: codexPayload, transcriptTail: [], pendingQuestion: true)
        check("llmSummary: codex transcript 变体同样静默 fallback",
              vam.pendingAnnouncements.isEmpty)

        // 现场还原
        vam.isAnnouncing = false
        vam.pendingAnnouncements = []
    }
}
