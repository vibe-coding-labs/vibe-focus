import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerSessionStartSeamTests.swift
// 靶：HookEventHandler.handleSessionStart（HookSessionStartEnvironment 注入）——
// 无上下文 409、远程 label 绑定成功/映射失败、本地 TTY/PPID 绑定成功/匹配失败、
// 绑定尾 AX 解析成功自动改名与 AX 缺失跳过。零注册表持久化、零 AX 写。

final class SessionStartSeamState: @unchecked Sendable {
    var remoteIdentity: WindowIdentity?
    var localIdentity: WindowIdentity?
    var axWindow: AXUIElement?
    var bindCalls: [(sessionID: String, windowID: UInt32, type: WindowState.BindingType)] = []
    var auditCalls = 0
    var titleCalls: [String?] = []
}

extension RunnerHarness {
    func runSessionStartSeamTests() {
        let state = SessionStartSeamState()
        let identity = WindowIdentity(
            windowID: 7101, pid: 4242, bundleIdentifier: "com.apple.Terminal",
            appName: "Terminal", windowNumber: 7101, title: "t")

        func ctx(
            tty: String? = "/dev/ttys001", ppid: String? = "4242",
            machineLabel: String? = nil
        ) -> TerminalContext {
            TerminalContext(
                termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
                weztermPane: nil, tty: tty, ppid: ppid, claudeProjectDir: nil,
                windowID: nil, machineLabel: machineLabel)
        }
        func payload(_ terminalCtx: TerminalContext?) -> ClaudeHookPayload {
            ClaudeHookPayload(
                event: .sessionStart, sessionID: "ut-start",
                source: nil, timestamp: nil, cwd: "/tmp/proj", model: nil,
                terminalCtx: terminalCtx, lastAssistantMessage: nil, transcriptPath: nil)
        }
        func reset() {
            state.remoteIdentity = nil
            state.localIdentity = nil
            state.axWindow = AXUIElementCreateSystemWide()
            state.bindCalls = []
            state.auditCalls = 0
            state.titleCalls = []
        }
        func makeEnv() -> HookSessionStartEnvironment {
            HookSessionStartEnvironment(
                resolveRemoteBinding: { _, _ in state.remoteIdentity },
                findLocalWindow: { _ in state.localIdentity },
                bind: { payload, identity, type, _ in
                    state.bindCalls.append((payload.sessionID, identity.windowID, type))
                },
                audit: { _, _, _ in state.auditCalls += 1 },
                resolveAX: { _ in state.axWindow },
                autoSetTitle: { payload, _, _ in state.titleCalls.append(payload.cwd) }
            )
        }
        let handler = HookEventHandler.shared

        // A. 无终端上下文 → 409
        reset()
        let a = handler.handleSessionStart(payload: payload(nil), environment: makeEnv())
        check("sessionStart A1: 无上下文 → 409 no_terminal_context",
              a.statusCode == 409 && a.response.code == "no_terminal_context"
              && state.bindCalls.isEmpty)

        // A2. 上下文存在但无可用字段（tty/ppid 皆空）→ 仍判 noContext
        reset()
        let a2 = handler.handleSessionStart(
            payload: payload(ctx(tty: nil, ppid: nil)), environment: makeEnv())
        check("sessionStart A2: 上下文无可用字段 → 409", a2.statusCode == 409)

        // B. 远程 label + 映射命中 → 绑定成功
        reset()
        state.remoteIdentity = identity
        let b = handler.handleSessionStart(
            payload: payload(ctx(machineLabel: "laptop-002")), environment: makeEnv())
        check("sessionStart B1: 远程映射命中 → 200 session_bound",
              b.statusCode == 200 && b.response.code == "session_bound"
              && b.response.handled)
        check("sessionStart B2: 绑定类型 remote 且携 sessionID",
              state.bindCalls.count == 1 && state.bindCalls[0].type == .remote
              && state.bindCalls[0].sessionID == "ut-start")
        check("sessionStart B3: 审计一次、自动标题带 cwd",
              state.auditCalls == 1 && state.titleCalls == ["/tmp/proj"])

        // C. 远程 label 映射失败 → 409
        reset()
        let c = handler.handleSessionStart(
            payload: payload(ctx(machineLabel: "laptop-999")), environment: makeEnv())
        check("sessionStart C1: 远程映射失败 → 409 remote_binding_failed",
              c.statusCode == 409 && c.response.code == "remote_binding_failed"
              && state.bindCalls.isEmpty)

        // D. 本地 TTY/PPID 命中 → 绑定成功
        reset()
        state.localIdentity = identity
        let d = handler.handleSessionStart(payload: payload(ctx()), environment: makeEnv())
        check("sessionStart D1: 本地匹配命中 → 200 且 bindingType local",
              d.statusCode == 200 && state.bindCalls.first?.type == .local)

        // E. 本地匹配失败 → 409
        reset()
        let e = handler.handleSessionStart(payload: payload(ctx()), environment: makeEnv())
        check("sessionStart E1: 本地匹配失败 → 409 terminal_context_match_failed",
              e.statusCode == 409 && e.response.code == "terminal_context_match_failed"
              && state.auditCalls == 0)

        // F. AX 解析失败 → 绑定照常、跳过自动标题
        reset()
        state.localIdentity = identity
        state.axWindow = nil
        let f = handler.handleSessionStart(payload: payload(ctx()), environment: makeEnv())
        check("sessionStart F1: AX 缺失 → 仍绑定成功但不改名",
              f.statusCode == 200 && state.bindCalls.count == 1 && state.titleCalls.isEmpty)
    }
}
