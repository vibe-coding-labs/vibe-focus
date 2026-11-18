import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerHookMoveExecuteSeamTests.swift
// 靶：HookEventHandler.moveWindowToMainScreenAndRespond（HookMoveExecuteEnvironment 注入）——
// 移动成功臂（响应契约 + onComplete + 完成音/角标归因）与
// 气泡自动弹出三态（开关关闭/气泡占用/直弹），移动失败臂（409 + touch 记账）。
// 零真实移窗、零声音、零角标、零注册库写。

private final class HookMoveResultBox<T>: @unchecked Sendable {
    var value: T?
}

final class HookMoveExecuteSeamState: @unchecked Sendable {
    var moveResult = true
    var moves: [(windowID: UInt32, sessionID: String)] = []
    var autoShowEnabled = true
    var idle = true
    var summons: [(windowID: UInt32, pid: pid_t, appName: String?)] = []
    var celebrations: [(projectName: String?, bundleID: String?, appName: String?)] = []
    var touches: [(sessionID: String, message: String)] = []

    func reset() {
        moveResult = true
        moves = []
        autoShowEnabled = true
        idle = true
        summons = []
        celebrations = []
        touches = []
    }
}

extension RunnerHarness {
    func runHookMoveExecuteSeamTests() {
        let state = HookMoveExecuteSeamState()
        let handler = HookEventHandler.shared
        let identity = WindowIdentity(
            windowID: 7101, pid: 4242, bundleIdentifier: "com.googlecode.iterm2",
            appName: "iTerm2", windowNumber: nil, title: "t")
        let payload = ClaudeHookPayload(
            event: .stop, sessionID: "s-exec", source: nil, timestamp: nil,
            cwd: "/tmp/MyProj", model: "claude", terminalCtx: nil,
            lastAssistantMessage: nil, transcriptPath: nil)

        func environment() -> HookMoveExecuteEnvironment {
            HookMoveExecuteEnvironment(
                moveToMain: { id, sessionID in
                    state.moves.append((id.windowID, sessionID))
                    return state.moveResult
                },
                autoShowOnMoveToMain: { state.autoShowEnabled },
                bubbleIdle: { state.idle },
                summonBubble: { id, pid, name in
                    state.summons.append((id, pid, name))
                },
                celebrate: { project, bundle, app in
                    state.celebrations.append((project, bundle, app))
                },
                touch: { sessionID, message in
                    state.touches.append((sessionID, message))
                }
            )
        }
        func run(onComplete: (() -> Void)? = nil) -> (statusCode: Int, response: ClaudeHookResponse)? {
            let box = HookMoveResultBox<(statusCode: Int, response: ClaudeHookResponse)>()
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                box.value = await handler.moveWindowToMainScreenAndRespond(
                    identity: identity, payload: payload,
                    triggerName: "Stop", source: "ut",
                    onComplete: onComplete, environment: environment())
                sem.signal()
            }
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if sem.wait(timeout: .now() + 0.05) == .success { break }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return box.value
        }

        // A. 成功臂：气泡直弹 + 完成音角标 + onComplete
        state.reset()
        var completed = 0
        let success = run(onComplete: { completed += 1 })
        check("hookMoveExecute A1: 移动成功 → 200 window_focused handled",
              success?.statusCode == 200 && success?.response.ok == true
              && success?.response.code == "window_focused"
              && success?.response.handled == true)
        check("hookMoveExecute A2: 移动调用透传窗口与会话",
              state.moves.count == 1 && state.moves[0].windowID == 7101
              && state.moves[0].sessionID == "s-exec")
        check("hookMoveExecute A3: onComplete 回调恰一次", completed == 1)
        check("hookMoveExecute A4: 气泡自动弹出（开关开 + 空闲）",
              state.summons.count == 1 && state.summons[0].windowID == 7101
              && state.summons[0].appName == "iTerm2")
        check("hookMoveExecute A5: 完成音项目名由 cwd 末段归一 + 角标目标透传",
              state.celebrations.count == 1
              && state.celebrations[0].projectName == "myproj"
              && state.celebrations[0].bundleID == "com.googlecode.iterm2")
        check("hookMoveExecute A6: 成功臂不写失败 touch", state.touches.isEmpty)

        // B. 开关关闭 → 不弹但照常庆祝
        state.reset()
        state.autoShowEnabled = false
        _ = run()
        check("hookMoveExecute B1: 自动弹出关闭 → 不召唤气泡",
              state.summons.isEmpty && state.celebrations.count == 1)

        // C. 气泡占用（非空闲）→ 不弹
        state.reset()
        state.idle = false
        _ = run()
        check("hookMoveExecute C1: 气泡非空闲 → 不召唤气泡",
              state.summons.isEmpty && state.celebrations.count == 1)

        // D. 失败臂：409 + touch 记账，零庆祝/零弹窗
        state.reset()
        state.moveResult = false
        var completedOnFailure = 0
        let failure = run(onComplete: { completedOnFailure += 1 })
        check("hookMoveExecute D1: 移动失败 → 409 window_move_failed",
              failure?.statusCode == 409 && failure?.response.ok == false
              && failure?.response.code == "window_move_failed"
              && failure?.response.handled == false)
        check("hookMoveExecute D2: 失败 touch 带会话与触发名",
              state.touches.count == 1 && state.touches[0].sessionID == "s-exec"
              && state.touches[0].message.contains("Stop"))
        check("hookMoveExecute D3: 失败臂零庆祝零召唤零 onComplete",
              state.celebrations.isEmpty && state.summons.isEmpty && completedOnFailure == 0)
    }
}
