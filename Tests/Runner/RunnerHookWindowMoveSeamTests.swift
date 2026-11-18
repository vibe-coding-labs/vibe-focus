import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerHookWindowMoveSeamTests.swift
// 靶：HookEventHandler.handleWindowMoveTrigger（Stop/SessionEnd）七路尾部决策
// （HookWindowMoveEnvironment 注入）——总开关、remoteOnly、绑定解析四态、
// 已主屏、冷却、陈旧 PID、非终端窗、进入移窗管线。
// 零真实窗口移动、零绑定持久化副作用断言依赖。

final class HookWindowMoveSeamState: @unchecked Sendable {
    var autoFocus = true
    var outcome: SessionBindingOutcome = .none
    var cgWindows: [CGWindowEntry] = []
    var onMain = false
    var cooldown = false
    var moveCalls = 0
    var onCompleteCalls = 0
}

extension RunnerHarness {
    func runHookWindowMoveSeamTests() {
        let state = HookWindowMoveSeamState()

        func binding(
            windowID: UInt32 = 8401, pid: Int32 = 4242,
            appName: String? = "Terminal", bundleID: String? = "com.apple.Terminal",
            age: TimeInterval = 0
        ) -> WindowState {
            WindowState(
                windowID: windowID, pid: pid, tty: nil,
                axWindowNumber: nil, appName: appName, bundleIdentifier: bundleID,
                title: "t", termSessionID: nil, itermSessionID: nil,
                kittyWindowID: nil, weztermPane: nil, envWindowID: nil,
                sessionID: "ut", cwd: nil, model: nil,
                origX: nil, origY: nil, origW: nil, origH: nil,
                targetX: nil, targetY: nil, targetW: nil, targetH: nil,
                sourceSpace: nil, sourceDisplay: nil,
                sourceYabaiDisp: nil, sourceDispSpace: nil,
                targetDisplay: nil, toggleReason: nil, toggledAt: nil,
                isCompleted: false, completedAt: nil,
                createdAt: Date().addingTimeInterval(-age),
                updatedAt: Date().addingTimeInterval(-age)
            )
        }
        func payload(_ session: String = "ut-move") -> ClaudeHookPayload {
            ClaudeHookPayload(
                event: .stop, sessionID: session,
                source: nil, timestamp: nil, cwd: "/tmp", model: nil,
                terminalCtx: nil, lastAssistantMessage: nil, transcriptPath: nil)
        }
        func reset() {
            state.autoFocus = true
            state.outcome = .none
            state.cgWindows = []
            state.onMain = false
            state.cooldown = false
            state.moveCalls = 0
            state.onCompleteCalls = 0
        }
        func run(_ remoteOnly: Bool = false) -> (statusCode: Int, code: String) {
            let box = HookSubmitResultBox()
            let sem = DispatchSemaphore(value: 0)
            let payloadValue = payload()
            Task { @MainActor in
                let env = HookWindowMoveEnvironment(
                    autoFocusEnabled: { state.autoFocus },
                    resolveBinding: { _, _ in state.outcome },
                    cgWindows: { state.cgWindows },
                    isOnMainScreen: { _ in state.onMain },
                    isInCooldown: { _ in state.cooldown },
                    moveAndRespond: { _, _, _, _, onComplete in
                        state.moveCalls += 1
                        onComplete()
                        state.onCompleteCalls += 1
                        return (200, ClaudeHookResponse(
                            ok: true, code: "moved_ok", message: "moved",
                            sessionID: payloadValue.sessionID, handled: true))
                    }
                )
                let r = await HookEventHandler.shared.handleWindowMoveTrigger(
                    payload: payloadValue, triggerName: "Stop",
                    remoteOnly: remoteOnly, environment: env)
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

        // A. 总开关关闭
        reset()
        state.autoFocus = false
        check("hookMove A1: autoFocus 关闭 → auto_focus_disabled",
              run().code == "auto_focus_disabled")

        // B. remoteOnly 在绑定 IO 之前拒绝
        reset()
        state.outcome = .bound(binding())
        check("hookMove B1: remoteOnly → trigger_disabled_skip（零移窗）",
              run(true).code == "trigger_disabled_skip" && state.moveCalls == 0)

        // C. 绑定活性校验失败
        reset()
        state.outcome = .verificationFailed(binding())
        check("hookMove C1: 活性校验失败 → binding_verification_failed",
              run().code == "binding_verification_failed")

        // D. 自愈后立即丢失
        reset()
        state.outcome = .healLost
        check("hookMove D1: healLost → no_binding_skip", run().code == "no_binding_skip")

        // E. 无绑定
        reset()
        state.outcome = .none
        check("hookMove E1: 无绑定 → no_binding_skip", run().code == "no_binding_skip")

        // F. 进入移窗管线（终端窗、年轻绑定、副屏、无冷却）
        reset()
        state.outcome = .bound(binding())
        let f = run()
        check("hookMove F1: proceedToMove → 执行器响应透传",
              f.code == "moved_ok" && state.moveCalls == 1)
        check("hookMove F2: onComplete 回调被调用", state.onCompleteCalls == 1)

        // G. 已在主屏
        reset()
        state.outcome = .healed(binding())
        state.onMain = true
        check("hookMove G1: 已在主屏 → already_on_main_screen（零移窗）",
              run().code == "already_on_main_screen" && state.moveCalls == 0)

        // H. 冷却中
        reset()
        state.outcome = .bound(binding())
        state.cooldown = true
        check("hookMove H1: 冷却中 → restore_cooldown_active",
              run().code == "restore_cooldown_active")

        // I. 陈旧绑定 PID 不符（>30min 且 CG 读回 pid 不同）
        reset()
        state.outcome = .bound(binding(pid: 4242, age: 3600))
        state.cgWindows = [CGWindowEntry(from: [
            kCGWindowNumber as String: UInt32(8401),
            kCGWindowOwnerPID as String: Int32(9999),
        ])!]
        check("hookMove I1: 陈旧绑定 PID 不符 → stale_binding_pid_mismatch",
              run().code == "stale_binding_pid_mismatch")

        // I2. 陈旧绑定但 PID 一致 → 继续走终端判定（非主屏 → 移窗）
        reset()
        state.outcome = .bound(binding(age: 3600))
        state.cgWindows = [CGWindowEntry(from: [
            kCGWindowNumber as String: UInt32(8401),
            kCGWindowOwnerPID as String: Int32(4242),
        ])!]
        check("hookMove I2: 陈旧绑定 PID 一致 → 仍进移窗管线",
              run().code == "moved_ok")

        // J. 非终端窗
        reset()
        state.outcome = .bound(binding(appName: "Safari", bundleID: "com.apple.Safari"))
        check("hookMove J1: 非终端/IDE 窗 → non_terminal_window",
              run().code == "non_terminal_window")
    }
}
