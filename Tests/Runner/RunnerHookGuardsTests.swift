// Tests/Runner/RunnerHookGuardsTests.swift
// B221 覆盖堆叠·Hook 入口守卫域：handleStop（remoteOnly 拒绝）/ handleUserPromptSubmit
// （无绑定 noBinding）/ handleSessionStart（无终端上下文 409）。
// 零 DB 污染已核实：touch() 对无绑定会话首行 guard 即返回；setLastEventDescription
// 纯内存。偏好读写走 Runner 自有 defaults 域，与生产 app 域隔离，defer 复位。

import Foundation
@testable import VibeFocusKit

extension RunnerHarness {

    /// 同步 harness 桥接 @MainActor async handler（B154 家法：短片等待泵主 RunLoop）
    private func runHookAsync(
        _ block: @escaping () async -> (statusCode: Int, response: ClaudeHookResponse)
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        final class Box: @unchecked Sendable {
            var result: (statusCode: Int, response: ClaudeHookResponse)? = nil
        }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            box.result = await block()
            sem.signal()
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if sem.wait(timeout: .now() + 0.05) == .success { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return box.result ?? (0, ClaudeHookResponse(ok: false, code: "timeout", message: "timeout", sessionID: "b221", handled: false))
    }

    func runHookGuardTests() {
        print("\n=== HookGuards (B221) ===")
        let handler = HookEventHandler.shared
        let bogus = ClaudeHookPayload(
            event: .stop, sessionID: "b221-nonexistent-session", source: nil, timestamp: nil,
            cwd: "/tmp/b221", model: nil, terminalCtx: nil,
            lastAssistantMessage: nil, transcriptPath: nil, message: nil
        )

        // 1) handleStop：triggerOnStop=false → remoteOnly 在一切绑定 IO 前拒绝
        let savedStop = ClaudeHookPreferences.triggerOnStop
        ClaudeHookPreferences.triggerOnStop = false
        let stopR = runHookAsync { await handler.handleStop(payload: bogus) }
        ClaudeHookPreferences.triggerOnStop = savedStop
        check("hook: Stop 关开关 remoteOnly 拒绝 trigger_disabled_skip",
              stopR.1.code == "trigger_disabled_skip" && stopR.1.ok == true)

        // 2) handleUserPromptSubmit：autoRestore ON + 无绑定会话 → no_binding_skip
        let savedUps = ClaudeHookPreferences.autoRestoreOnPromptSubmit
        ClaudeHookPreferences.autoRestoreOnPromptSubmit = true
        let upsPayload = ClaudeHookPayload(
            event: .userPromptSubmit, sessionID: "b221-nonexistent-session", source: nil,
            timestamp: nil, cwd: "/tmp/b221", model: nil, terminalCtx: nil,
            lastAssistantMessage: nil, transcriptPath: nil, message: nil
        )
        let upsR = runHookAsync { await handler.handleUserPromptSubmit(payload: upsPayload) }
        ClaudeHookPreferences.autoRestoreOnPromptSubmit = savedUps
        check("hook: UPS 无绑定会话 no_binding_skip", upsR.1.code == "no_binding_skip")

        // 3) handleSessionStart：无终端上下文 → 409 no_terminal_context
        let ssR = handler.handleSessionStart(payload: bogus)
        check("hook: SessionStart 无上下文 409",
              ssR.0 == 409 && ssR.1.code == "no_terminal_context" && ssR.1.ok == false)

        // 4) SessionStart 本地通道：幻影 tty/ppid 匹配不到窗口 → 409
        //    terminal_context_match_failed（setLastEventDescription 纯内存）
        let localCtx = TerminalContext(
            termSessionID: nil, itermSessionID: nil, kittyWindowID: nil, weztermPane: nil,
            tty: "/dev/ttys997", ppid: "999997", claudeProjectDir: "/tmp/b226",
            windowID: nil, machineLabel: nil
        )
        let localPayload = ClaudeHookPayload(
            event: .sessionStart, sessionID: "b226-local", source: nil, timestamp: nil,
            cwd: "/tmp/b226", model: nil, terminalCtx: localCtx,
            lastAssistantMessage: nil, transcriptPath: nil, message: nil
        )
        let localR = handler.handleSessionStart(payload: localPayload)
        check("hook: SessionStart 本地幻影上下文 match_failed 409",
              localR.0 == 409 && localR.1.code == "terminal_context_match_failed")

        // 5) SessionStart 远程通道：未映射 machine_label → 409 remote_binding_failed
        //    （resolveRemoteBinding 读映射表，Runner 域为空 → 必失败，只读）
        let remoteCtx = TerminalContext(
            termSessionID: nil, itermSessionID: nil, kittyWindowID: nil, weztermPane: nil,
            tty: "/dev/ttys996", ppid: "999996", claudeProjectDir: "/tmp/b226",
            windowID: nil, machineLabel: "b226-unmapped-host"
        )
        let remotePayload = ClaudeHookPayload(
            event: .sessionStart, sessionID: "b226-remote", source: "forwarder",
            timestamp: nil, cwd: "/tmp/b226", model: nil, terminalCtx: remoteCtx,
            lastAssistantMessage: nil, transcriptPath: nil, message: nil
        )
        let remoteR = handler.handleSessionStart(payload: remotePayload)
        check("hook: SessionStart 远程未映射标签 remote_binding_failed 409",
              remoteR.0 == 409 && remoteR.1.code == "remote_binding_failed")

        // 6) resolveRemoteBinding 直测：未映射 label → nil（label_not_found 路）
        check("hook: resolveRemoteBinding 未映射 nil",
              handler.resolveRemoteBinding(label: "b226-nope", sessionID: "s") == nil)

        // 7) resolveRemoteBinding：映射到幻影 CG 窗口 → 解析落空 nil
        //    （remoteBindings 写 Runner 自有 defaults 域，JSON string 键存，defer 还原）
        let savedBindings = UserDefaults.standard.data(forKey: "claudeHookRemoteBindings")
        defer {
            if let saved = savedBindings {
                UserDefaults.standard.set(saved, forKey: "claudeHookRemoteBindings")
            } else {
                UserDefaults.standard.removeObject(forKey: "claudeHookRemoteBindings")
            }
        }
        let fakeMap = ["b226-phantom-host": UInt32(0xB226)]
        UserDefaults.standard.set(try! JSONEncoder().encode(fakeMap),
                                  forKey: "claudeHookRemoteBindings")
        check("hook: resolveRemoteBinding 幻影窗口 nil",
              handler.resolveRemoteBinding(label: "b226-phantom-host", sessionID: "s") == nil)
    }
}
