import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerWindowResolutionSeamTests.swift
// 靶：HookEventHandler.resolveSessionBinding 共享解析编排（SessionBindingEnvironment 注入）——
// 既有绑定活性校验两态、UPS 前台终端窗自愈绑定、远程自愈 healed/healLost/校验失败、
// 无 label 放弃、非 UPS 不走前台捕获，以及 resolveWindowIdentity 适配层。
// 零注册库写、零 AX、零远程解析。

final class WindowResolutionSeamState: @unchecked Sendable {
    /// 首次 binding() 的返回值（之后返回 registeredAfterBind）
    var existing: WindowState?
    var registeredAfterBind: WindowState?
    var bindingCalls = 0
    var verifyResult = true
    var verifyCalls = 0
    var binds: [(sessionID: String, windowID: UInt32, ctx: TerminalContext?, cwd: String?, model: String?)] = []
    var focused: WindowIdentity?
    var focusedCalls = 0
    var terminalBundle = true
    var remoteIdentity: WindowIdentity?
    var remoteCalls = 0

    func nextBinding() -> WindowState? {
        bindingCalls += 1
        return bindingCalls == 1 ? existing : registeredAfterBind
    }
}

extension RunnerHarness {
    func runWindowResolutionSeamTests() {
        let state = WindowResolutionSeamState()
        let handler = HookEventHandler.shared

        func makeState(_ wid: UInt32 = 7001, type: WindowState.BindingType = .remote) -> WindowState {
            WindowState(
                windowID: wid, pid: 4242, tty: nil,
                axWindowNumber: nil, appName: "Terminal", bundleIdentifier: "com.apple.Terminal",
                title: "t", termSessionID: nil, itermSessionID: nil,
                kittyWindowID: nil, weztermPane: nil, envWindowID: nil,
                sessionID: "s-1", cwd: nil, model: nil,
                bindingType: type,
                origX: nil, origY: nil, origW: nil, origH: nil,
                targetX: nil, targetY: nil, targetW: nil, targetH: nil,
                sourceSpace: nil, sourceDisplay: nil,
                sourceYabaiDisp: nil, sourceDispSpace: nil,
                targetDisplay: nil, toggleReason: nil, toggledAt: nil,
                isCompleted: false, completedAt: nil,
                createdAt: Date(), updatedAt: Date())
        }
        func identity(_ wid: UInt32 = 7002) -> WindowIdentity {
            WindowIdentity(
                windowID: wid, pid: 4242, bundleIdentifier: "com.apple.Terminal",
                appName: "Terminal", windowNumber: nil, title: "focused")
        }
        func context(_ label: String?) -> TerminalContext? {
            guard let label else { return nil }
            return TerminalContext(
                termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
                weztermPane: nil, tty: "/dev/ttys001", ppid: nil,
                claudeProjectDir: nil, windowID: nil, machineLabel: label)
        }
        func payload(
            _ event: ClaudeHookEventType = .stop,
            label: String? = nil,
            session: String = "s-1"
        ) -> ClaudeHookPayload {
            ClaudeHookPayload(
                event: event, sessionID: session, source: nil, timestamp: nil,
                cwd: "/tmp/proj", model: "claude", terminalCtx: context(label),
                lastAssistantMessage: nil, transcriptPath: nil)
        }
        func environment() -> SessionBindingEnvironment {
            SessionBindingEnvironment(
                binding: { _ in state.nextBinding() },
                verifyBinding: { _ in
                    state.verifyCalls += 1
                    return state.verifyResult
                },
                bind: { sessionID, identity, ctx, cwd, model in
                    state.binds.append((sessionID, identity.windowID, ctx, cwd, model))
                },
                captureFocused: {
                    state.focusedCalls += 1
                    return state.focused
                },
                isTerminalBundleID: { _ in state.terminalBundle },
                resolveRemoteBinding: { _, _ in
                    state.remoteCalls += 1
                    return state.remoteIdentity
                }
            )
        }
        func reset() {
            state.existing = nil
            state.registeredAfterBind = nil
            state.bindingCalls = 0
            state.verifyResult = true
            state.verifyCalls = 0
            state.binds = []
            state.focused = nil
            state.focusedCalls = 0
            state.terminalBundle = true
            state.remoteIdentity = nil
            state.remoteCalls = 0
        }

        // A1. 既有绑定通过活性校验
        reset()
        state.existing = makeState()
        var outcome = handler.resolveSessionBinding(
            payload: payload(), traceID: "ut", environment: environment())
        if case .bound(let bound) = outcome {
            check("windowResolution A1: 既有绑定校验通过 → bound", bound.windowID == 7001)
        } else {
            check("windowResolution A1: 既有绑定校验通过 → bound", false)
        }
        check("windowResolution A2: 校验仅一次、零自愈", state.verifyCalls == 1 && state.remoteCalls == 0)

        // B1. 既有绑定校验失败
        reset()
        state.existing = makeState()
        state.verifyResult = false
        outcome = handler.resolveSessionBinding(
            payload: payload(), traceID: "ut", environment: environment())
        if case .verificationFailed(let failed) = outcome {
            check("windowResolution B1: 校验失败 → verificationFailed", failed.windowID == 7001)
        } else {
            check("windowResolution B1: 校验失败 → verificationFailed", false)
        }
        check("windowResolution B2: 校验失败不触发自愈绑定", state.binds.isEmpty && state.remoteCalls == 0)

        // C1. 无绑定且无 label → giveUp
        reset()
        outcome = handler.resolveSessionBinding(
            payload: payload(), traceID: "ut", environment: environment())
        if case .none = outcome {
            check("windowResolution C1: 无绑定无 label → none", true)
        } else {
            check("windowResolution C1: 无绑定无 label → none", false)
        }
        check("windowResolution C2: 放弃路径零前台捕获零绑定",
              state.focusedCalls == 0 && state.binds.isEmpty)

        // D1. UPS + 前台终端窗 → 直接自愈绑定
        reset()
        state.focused = identity(7002)
        state.registeredAfterBind = makeState(7002)
        outcome = handler.resolveSessionBinding(
            payload: payload(.userPromptSubmit, label: "m1"), traceID: "ut", environment: environment())
        if case .bound(let autoBound) = outcome {
            check("windowResolution D1: UPS 前台终端窗 → 自动绑定并 bound", autoBound.windowID == 7002)
        } else {
            check("windowResolution D1: UPS 前台终端窗 → 自动绑定并 bound", false)
        }
        check("windowResolution D2: bind 透传 session/上下文/cwd/model",
              state.binds.count == 1 && state.binds[0].sessionID == "s-1"
              && state.binds[0].windowID == 7002
              && state.binds[0].ctx?.machineLabel == "m1"
              && state.binds[0].cwd == "/tmp/proj" && state.binds[0].model == "claude")
        check("windowResolution D3: 自动绑定不再走远程解析", state.remoteCalls == 0)

        // D4. UPS + 前台非终端窗 → 回落远程自愈
        reset()
        state.focused = identity(7003)
        state.terminalBundle = false
        state.remoteIdentity = identity(7004)
        state.registeredAfterBind = makeState(7004)
        outcome = handler.resolveSessionBinding(
            payload: payload(.userPromptSubmit, label: "m1"), traceID: "ut", environment: environment())
        if case .healed(let healed) = outcome {
            check("windowResolution D4: 前台非终端 → 回落远程自愈 healed", healed.windowID == 7004)
        } else {
            check("windowResolution D4: 前台非终端 → 回落远程自愈 healed", false)
        }
        check("windowResolution D5: 远程解析一次且只绑一次",
              state.remoteCalls == 1 && state.binds.count == 1)

        // E1. Stop + label + 远程命中 → healed
        reset()
        state.remoteIdentity = identity(7005)
        state.registeredAfterBind = makeState(7005)
        outcome = handler.resolveSessionBinding(
            payload: payload(.stop, label: "m1"), traceID: "ut", environment: environment())
        if case .healed(let healed) = outcome {
            check("windowResolution E1: Stop 远程自愈成功 → healed", healed.windowID == 7005)
        } else {
            check("windowResolution E1: Stop 远程自愈成功 → healed", false)
        }
        check("windowResolution E2: 非 UPS 不走前台捕获", state.focusedCalls == 0)
        check("windowResolution E3: healed 产物过活性校验", state.verifyCalls == 1)

        // E4. 远程解析失败 → none
        reset()
        outcome = handler.resolveSessionBinding(
            payload: payload(.stop, label: "m1"), traceID: "ut", environment: environment())
        if case .none = outcome {
            check("windowResolution E4: 远程解析失败 → none", state.remoteCalls == 1 && state.binds.isEmpty)
        } else {
            check("windowResolution E4: 远程解析失败 → none", false)
        }

        // F1. bind 后立刻取不到绑定 → healLost
        reset()
        state.remoteIdentity = identity(7006)
        state.registeredAfterBind = nil
        outcome = handler.resolveSessionBinding(
            payload: payload(.stop, label: "m1"), traceID: "ut", environment: environment())
        if case .healLost = outcome {
            check("windowResolution F1: 绑定立即丢失 → healLost", state.binds.count == 1)
        } else {
            check("windowResolution F1: 绑定立即丢失 → healLost", false)
        }

        // F2. healed 但活性校验失败 → verificationFailed
        reset()
        state.remoteIdentity = identity(7007)
        state.registeredAfterBind = makeState(7007)
        state.verifyResult = false
        outcome = handler.resolveSessionBinding(
            payload: payload(.stop, label: "m1"), traceID: "ut", environment: environment())
        if case .verificationFailed(let failed) = outcome {
            check("windowResolution F2: 自愈产物校验失败 → verificationFailed",
                  failed.windowID == 7007 && state.verifyCalls == 1)
        } else {
            check("windowResolution F2: 自愈产物校验失败 → verificationFailed", false)
        }

        // G1/G2. resolveWindowIdentity 适配层
        reset()
        state.existing = makeState(7008)
        let resolved = handler.resolveWindowIdentity(
            payload: payload(), traceID: "ut", startedAt: Date(), environment: environment())
        check("windowResolution G1: 绑定有效 → 适配为 WindowIdentity",
              resolved?.windowID == 7008)
        reset()
        state.existing = makeState(7009)
        state.verifyResult = false
        let unresolved = handler.resolveWindowIdentity(
            payload: payload(), traceID: "ut", startedAt: Date(), environment: environment())
        check("windowResolution G2: 校验失败 → 适配层返回 nil", unresolved == nil)
    }
}
