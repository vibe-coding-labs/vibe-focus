import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerBindingResolutionTests.swift — B230：resolveSessionBinding
// 解析编排四分支真身直测（Stop/SessionEnd/UPS 共用的绑定唯一入口，此前 0 计数行）。
// 共享注册表种子全程快照-还原；bound/verificationFailed 两分支用真实 CGWindowList
// 窗口走活性校验；自愈分支走「无映射 label + 非 UPS 事件」安全路（resolveRemoteBinding
// 空表 nil，不触发 bind 写库）。

extension RunnerHarness {
    func runBindingResolutionTests() {
        let handler = HookEventHandler.shared
        let registry = SessionWindowRegistry.shared

        // 种子快照-还原工具
        func withSeed(_ state: WindowState, _ body: () -> Void) {
            let existing = registry.windowStates[state.windowID]
            registry.windowStates[state.windowID] = state
            body()
            if let existing {
                registry.windowStates[state.windowID] = existing
            } else {
                registry.windowStates.removeValue(forKey: state.windowID)
            }
        }
        func payload(_ event: ClaudeHookEventType, _ sessionID: String, machineLabel: String?) -> ClaudeHookPayload {
            ClaudeHookPayload(
                event: event, sessionID: sessionID, source: nil, timestamp: nil,
                cwd: nil, model: nil,
                terminalCtx: machineLabel.map { TerminalContext(
                    termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
                    weztermPane: nil, tty: nil, ppid: nil,
                    claudeProjectDir: nil, windowID: nil, machineLabel: $0) },
                lastAssistantMessage: nil, transcriptPath: nil, message: nil)
        }
        func state(sessionID: String, pid: Int32, windowID: UInt32) -> WindowState {
            var ws = WindowState(
                windowID: windowID, pid: pid, tty: nil, axWindowNumber: nil, appName: "SeedApp",
                bundleIdentifier: nil, title: nil, termSessionID: nil, itermSessionID: nil,
                sessionID: sessionID, bindingType: .local, isCompleted: false,
                createdAt: Date(), updatedAt: Date())
            ws.completedAt = nil
            return ws
        }

        // 真实他属 layer0 在屏窗（活性校验真值源；同 B215 BindingVerifier 夹具）
        let myPID = ProcessInfo.processInfo.processIdentifier
        guard let foreign = cgWindowListAll().first(where: { $0.layer == 0 && $0.isOnScreen && $0.ownerPID != myPID }) else {
            check("bindRes: 环境存在他属 layer0 在屏窗（夹具前提）", false)
            return
        }

        // ===== 分支 1：verifyExisting + 活性校验通过 → .bound =====
        do {
            let ws = state(sessionID: "b230-bound", pid: foreign.ownerPID, windowID: foreign.windowID)
            var outcome: SessionBindingOutcome?
            withSeed(ws) {
                outcome = handler.resolveSessionBinding(payload: payload(.stop, "b230-bound", machineLabel: nil),
                                                        traceID: "t1")
            }
            if case .bound(let b)? = outcome {
                check("bindRes: 存活绑定 → bound 且窗身份一致",
                      b.windowID == foreign.windowID && b.sessionID == "b230-bound")
            } else {
                check("bindRes: 存活绑定 → bound（实得 \(String(describing: outcome)) ）", false)
            }
        }

        // ===== 分支 2：verifyExisting + 活性校验失败 → verificationFailed =====
        do {
            let ws = state(sessionID: "b230-dead", pid: myPID, windowID: 0x0FFF_FFFE)
            var outcome: SessionBindingOutcome?
            withSeed(ws) {
                outcome = handler.resolveSessionBinding(payload: payload(.stop, "b230-dead", machineLabel: nil),
                                                        traceID: "t2")
            }
            if case .verificationFailed(let b)? = outcome {
                check("bindRes: 幽灵窗绑定 → verificationFailed 保留原绑定体",
                      b.windowID == 0x0FFF_FFFE)
            } else {
                check("bindRes: 幽灵窗绑定 → verificationFailed（实得 \(String(describing: outcome)) ）", false)
            }
        }

        // ===== 分支 3：无绑定 + label + 非 UPS 事件 → 自愈查空映射 → .none（不写库） =====
        do {
            let savedBindings = UserDefaults.standard.string(forKey: "claudeHookRemoteBindings")
            defer {
                if let savedBindings { UserDefaults.standard.set(savedBindings, forKey: "claudeHookRemoteBindings") }
                else { UserDefaults.standard.removeObject(forKey: "claudeHookRemoteBindings") }
            }
            UserDefaults.standard.removeObject(forKey: "claudeHookRemoteBindings")
            let before = registry.windowStates.count
            let outcome = handler.resolveSessionBinding(
                payload: payload(.stop, "b230-heal", machineLabel: "ml-unmapped-b230"), traceID: "t3")
            var tag = "other"
            if case .none = outcome { tag = "none" }
            check("bindRes: 无映射 label 自愈落空 → none 且注册表零写入",
                  tag == "none" && registry.windowStates.count == before)
        }

        // ===== 分支 4：无绑定 + 无 label → giveUp → .none =====
        do {
            let outcome = handler.resolveSessionBinding(
                payload: payload(.userPromptSubmit, "b230-giveup", machineLabel: nil), traceID: "t4")
            var tag = "other"
            if case .none = outcome { tag = "none" }
            check("bindRes: 无绑定无 label → none（giveUp 早退）", tag == "none")
        }
    }
}
