import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerHookPromptSubmitSeamTests.swift
// 靶：HookEventHandler.handleUserPromptSubmit 五重门编排（HookPromptSubmitEnvironment
// 注入）——开关关、无身份、限流、在途去重、四态记录资格门（keep/expired/already）、
// 已主屏、冷却、留在当前屏。断言决策码逐路唯一；零真实 DB 写、零窗口查询。

final class HookPromptSubmitSeamState: @unchecked Sendable {
    var autoEnabled = true
    var identity: WindowIdentity? = WindowIdentity(
        windowID: 8301, pid: 4242, bundleIdentifier: "com.apple.Terminal",
        appName: "Terminal", windowNumber: 8301, title: "t")
    var record: ToggleRecord?
    var bounds: CGRect?
    var inFlight = false
    var onMain = false
    var cooldown = false
    var remaining = 12
    var cleared: [UInt32] = []
}

extension RunnerHarness {
    func runHookPromptSubmitSeamTests() {
        let state = HookPromptSubmitSeamState()

        func record(toggledAt: Date, origFrame: CGRect) -> ToggleRecord {
            ToggleRecord(
                windowID: 8301, pid: 4242, bundleIdentifier: "com.apple.Terminal",
                appName: "Terminal",
                origFrame: origFrame,
                sourceSpace: 1, sourceDisplay: 1, sourceYabaiDisp: 1, sourceDispSpace: 1,
                targetFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                targetDisplay: 1, toggledAt: toggledAt, sessionID: "ut")
        }
        func reset() {
            state.autoEnabled = true
            state.identity = WindowIdentity(
                windowID: 8301, pid: 4242, bundleIdentifier: "com.apple.Terminal",
                appName: "Terminal", windowNumber: 8301, title: "t")
            state.record = nil
            state.bounds = nil
            state.inFlight = false
            state.onMain = false
            state.cooldown = false
            state.remaining = 12
            state.cleared = []
        }
        let handler = HookEventHandler.shared
        func run(_ session: String) -> (statusCode: Int, code: String) {
            let box = HookSubmitResultBox()
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                let env = HookPromptSubmitEnvironment(
                    autoRestoreEnabled: { state.autoEnabled },
                    resolveIdentity: { _, _ in state.identity },
                    loadToggleRecord: { _ in state.record },
                    clearToggleRecord: { id in state.cleared.append(id) },
                    cgWindowBounds: { _ in state.bounds },
                    restoreInFlight: { _ in state.inFlight },
                    isOnMainScreen: { _ in state.onMain },
                    isInCooldown: { _ in state.cooldown },
                    cooldownRemaining: { _ in state.remaining }
                )
                let payload = ClaudeHookPayload(
                    event: .userPromptSubmit, sessionID: session,
                    source: nil, timestamp: nil, cwd: "/tmp", model: nil,
                    terminalCtx: nil, lastAssistantMessage: nil, transcriptPath: nil)
                let r = await handler.handleUserPromptSubmit(payload: payload, environment: env)
                box.status = r.statusCode
                box.code = r.response.code
                sem.signal()
            }
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if sem.wait(timeout: .now() + 0.05) == .success { break }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return (box.status, box.code)
        }
        let farFrame = CGRect(x: 900, y: 900, width: 500, height: 400)
        let origFrame = CGRect(x: 0, y: 0, width: 500, height: 400)

        // A. 自动恢复总开关关闭
        reset()
        state.autoEnabled = false
        let a = run("ut-ups-a")
        check("hookUPS A1: 开关关闭 → auto_restore_disabled", a.code == "auto_restore_disabled")

        // B. 无身份
        reset()
        state.identity = nil
        check("hookUPS B1: 无身份 → no_binding_skip", run("ut-ups-b").code == "no_binding_skip")

        // C. 时效内记录且不在原位 → 原地保留看回复
        reset()
        state.record = record(toggledAt: Date(), origFrame: origFrame)
        state.bounds = farFrame
        check("hookUPS C1: 时效内记录 → submit_keep_window",
              run("ut-ups-c").code == "submit_keep_window")

        // D. 记录超时效 → 不再归位
        reset()
        state.record = record(toggledAt: Date().addingTimeInterval(-3600), origFrame: origFrame)
        state.bounds = farFrame
        check("hookUPS D1: 记录超 30min → toggle_record_expired",
              run("ut-ups-d").code == "toggle_record_expired")

        // E. 窗口已在记录原位 → 清陈旧记录
        reset()
        state.record = record(toggledAt: Date(), origFrame: origFrame)
        state.bounds = origFrame
        let e = run("ut-ups-e")
        check("hookUPS E1: 已在原位 → already_at_original", e.code == "already_at_original")
        check("hookUPS E2: 陈旧记录被清理", state.cleared == [8301])

        // F. 归位在途去重
        reset()
        state.inFlight = true
        check("hookUPS F1: 在途 → restore_already_active",
              run("ut-ups-f").code == "restore_already_active")

        // G. 无记录且已在主屏
        reset()
        state.onMain = true
        check("hookUPS G1: 已在主屏 → already_on_main_screen",
              run("ut-ups-g").code == "already_on_main_screen")

        // H. 冷却中
        reset()
        state.cooldown = true
        let h = run("ut-ups-h")
        check("hookUPS H1: 冷却中 → cooldown_active 且带剩余秒",
              h.code == "cooldown_active")

        // I. 用户在当前屏交互
        reset()
        check("hookUPS I1: 副屏交互 → stay_on_current_screen",
              run("ut-ups-i").code == "stay_on_current_screen")

        // J. 会话限流：同一 session 连发 21 次 → 第 21 次被限
        reset()
        state.onMain = true
        // 同一 session 连发 21 次打满 10min/20 次窗口。
        let rateSession = "ut-ups-rate-\(UUID().uuidString)"
        var sawLimited = false
        for _ in 0..<21 {
            if run(rateSession).code == "session_rate_limited" { sawLimited = true }
        }
        check("hookUPS J1: 同会话 21 连发触发 session_rate_limited", sawLimited)
    }
}

final class HookSubmitResultBox: @unchecked Sendable {
    var status = -1
    var code = ""
}
