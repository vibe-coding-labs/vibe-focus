import AppKit
import Foundation

// 决策逻辑已移至 HookEventHandler+WindowMove+Decision.swift
// 包含: WindowMoveDecision 枚举, decideWindowMove(), httpResponse(for:), isTerminalOrIDEApp()
// 执行逻辑已移至 HookEventHandler+WindowMove+Execute.swift
// 包含: moveWindowToMainScreenAndRespond()

@MainActor
extension HookEventHandler {

    // MARK: - Window Move Trigger (Stop / SessionEnd)

    /// Handle Stop/SessionEnd hook events — move the bound window back to the main screen.
    ///
    /// This is the "auto-focus on session end" feature. When a Claude Code session
    /// ends (Stop or SessionEnd hook), the terminal window that was bound to that
    /// session is moved back to the main screen so the user can see the result.
    ///
    /// 决策顺序由 HookEventHandler.decideWindowMove（WindowMoveDecision 枚举）唯一定义；
    /// 本函数只负责按同一顺序收集输入（含 IO），所有提前返回经由 httpResponse(for:) 产生。
    /// 竞态风险：remoteOnly 拒绝必须发生在任何 bind/self-heal 持久化之前——
    /// 否则被拒事件会留下"刚 self-heal 出来的 binding"脏状态（2.16 第五刀修复项）。
    ///
    /// - Parameters:
    ///   - payload: The hook event payload containing session info
    ///   - triggerName: Name of the triggering hook ("Stop" or "SessionEnd")
    ///   - remoteOnly: If true, skip ALL sessions (triggerOnStop=false semantics)
    /// - Returns: HTTP-style status code and hook response
    func handleWindowMoveTrigger(
        payload: ClaudeHookPayload,
        triggerName: String,
        remoteOnly: Bool = false
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        // P-INST-31: handleWindowMoveTrigger 总耗时（Stop/SessionEnd hook 同步响应延迟；defer 统一记，
        // 含决策输入收集与 moveWindowToMainScreenAndRespond）。
        let wmtStart = Date()
        var decision: WindowMoveDecision?
        defer {
            log("[HookEventHandler] \(triggerName) finished", fields: [
                "sessionID": payload.sessionID,
                "triggerName": triggerName,
                "decision": decision?.logDescription ?? "unknown",
                "durationMs": String(elapsedMilliseconds(since: wmtStart))
            ])
        }
        log(
            "[HookEventHandler] \(triggerName) triggered",
            fields: [
                "sessionID": payload.sessionID,
                "autoFocusEnabled": String(ClaudeHookPreferences.autoFocusOnSessionEnd),
                "remoteOnly": String(remoteOnly),
                "cwd": payload.cwd ?? "nil"
            ]
        )

        // ① autoFocus 总开关（任何 IO 之前）
        guard ClaudeHookPreferences.autoFocusOnSessionEnd else {
            decision = .autoFocusDisabled
            SessionWindowRegistry.shared.touch(
                sessionID: payload.sessionID,
                message: "\(triggerName) 收到（自动聚焦已关闭）"
            )
            return Self.httpResponse(for: .autoFocusDisabled, triggerName: triggerName, sessionID: payload.sessionID)!
        }

        // ② remoteOnly（triggerOnStop=false）在一切绑定 IO 之前拒绝。
        // 之前该判定后置在 binding 解析之后：无绑定时 self-heal 已把 session→window
        // 持久化进注册表，随后事件才被拒——被拒事件留下了 binding 副作用。
        if remoteOnly {
            decision = .localBindingSkip
            SessionWindowRegistry.shared.touch(
                sessionID: payload.sessionID,
                message: "\(triggerName) 跳过（remoteOnly 模式，triggerOnStop=false）"
            )
            log(
                "[HookEventHandler] \(triggerName) skipped (remoteOnly mode, triggerOnStop=false)",
                level: .debug,
                fields: [
                    "sessionID": payload.sessionID,
                    "machineLabel": payload.terminalCtx?.machineLabel ?? "nil"
                ]
            )
            return Self.httpResponse(for: .localBindingSkip, triggerName: triggerName, sessionID: payload.sessionID)!
        }

        // ③④ 绑定解析（含 machineLabel 自愈）+ 活性校验 —— 与 UPS 共用同一编排
        // （resolveSessionBinding；此前两路各写一份，校验时序与日志文案漂移）
        let binding: WindowState
        switch resolveSessionBinding(payload: payload, traceID: triggerName) {
        case .bound(let resolved), .healed(let resolved):
            binding = resolved
        case .verificationFailed(let resolved):
            decision = .bindingVerificationFailed
            log(
                "[HookEventHandler] \(triggerName) binding verification failed",
                level: .warn,
                fields: [
                    "sessionID": payload.sessionID,
                    "windowID": String(resolved.windowID),
                    "pid": String(resolved.pid)
                ]
            )
            return Self.httpResponse(for: .bindingVerificationFailed, triggerName: triggerName, sessionID: payload.sessionID)!
        case .healLost:
            decision = .noBindingSkip
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "no_binding_skip",
                    message: "Self-heal binding lost after registration",
                    sessionID: payload.sessionID, handled: false
                )
            )
        case .none:
            decision = .noBindingSkip
            return Self.httpResponse(for: .noBindingSkip, triggerName: triggerName, sessionID: payload.sessionID)!
        }

        // ⑤ 尾部决策统一走 decideWindowMove（唯一决策树）。
        // stale PID 证据按需收集：纯函数仅在 bindingAge > 1800 时消费 pidMatches，
        // 因此年轻绑定不做 CGWindowList 扫描（维持既有性能画像）。
        let windowID = binding.windowID
        let bindingAge = Date().timeIntervalSince(binding.createdAt)
        var staleActualPID: pid_t?
        let pidMatches: Bool?
        if bindingAge > 1800, let entry = cgWindowListAll().first(where: { $0.windowID == windowID }) {
            staleActualPID = entry.ownerPID
            pidMatches = entry.ownerPID == binding.pid
        } else {
            pidMatches = nil
        }
        let identity = WindowIdentity(from: binding)
        let tailDecision = Self.decideWindowMove(
            autoFocusEnabled: true,   // ① 已排除
            hasBinding: true,         // ③ 已排除
            bindingVerified: true,    // ④ 已排除
            isWindowOnMainScreen: WindowManager.shared.isWindowOnMainScreen(windowID: windowID),
            isInCooldown: MoveCooldownRegistry.shared.isInCooldown(windowID: windowID),
            bindingAge: bindingAge,
            pidMatches: pidMatches,
            isTerminalOrIDE: Self.isTerminalOrIDEApp(
                appName: identity.appName,
                bundleIdentifier: identity.bundleIdentifier
            )
        )
        decision = tailDecision

        switch tailDecision {
        case .proceedToMove:
            log(
                "[HookEventHandler] \(triggerName) proceeding to move binding window",
                fields: [
                    "sessionID": payload.sessionID,
                    "windowID": String(windowID),
                    "bindingType": binding.bindingType.rawValue,
                    "app": binding.appName ?? "unknown",
                    "bindingAge": String(Int(bindingAge)) + "s"
                ]
            )
            return moveWindowToMainScreenAndRespond(
                identity: identity,
                payload: payload,
                triggerName: triggerName,
                source: "binding",
                bindingAge: bindingAge,
                onComplete: {
                    SessionWindowRegistry.shared.markCompleted(sessionID: payload.sessionID)
                    MoveCooldownRegistry.shared.setCooldown(windowID: windowID)
                }
            )

        case .alreadyOnMainScreen:
            SessionWindowRegistry.shared.setLastEventDescription(
                "\(triggerName) 窗口已在主屏幕，跳过移动"
            )
            log(
                "[HookEventHandler] \(triggerName) window already on main screen, skipping move",
                fields: [
                    "sessionID": payload.sessionID,
                    "windowID": String(windowID),
                    "app": binding.appName ?? "unknown"
                ]
            )
            return Self.httpResponse(for: tailDecision, triggerName: triggerName, sessionID: payload.sessionID)!

        case .restoreCooldownActive:
            SessionWindowRegistry.shared.setLastEventDescription(
                "\(triggerName) 窗口刚被恢复，跳过移动（冷却中）"
            )
            log(
                "[HookEventHandler] \(triggerName) window recently restored, skipping move (cooldown)",
                level: .info,
                fields: [
                    "sessionID": payload.sessionID,
                    "windowID": String(windowID),
                    "app": binding.appName ?? "unknown"
                ]
            )
            return Self.httpResponse(for: tailDecision, triggerName: triggerName, sessionID: payload.sessionID)!

        case .staleBindingPIDMismatch:
            SessionWindowRegistry.shared.markCompleted(sessionID: payload.sessionID)
            log(
                "[HookEventHandler] \(triggerName) stale binding: window PID mismatch (binding age: \(Int(bindingAge))s)",
                level: .warn,
                fields: [
                    "sessionID": payload.sessionID,
                    "windowID": String(windowID),
                    "boundPID": String(binding.pid),
                    "actualPID": String(staleActualPID ?? -1),
                    "bindingAge": String(Int(bindingAge))
                ]
            )
            return Self.httpResponse(for: tailDecision, triggerName: triggerName, sessionID: payload.sessionID)!

        case .nonTerminalWindow:
            log(
                "[HookEventHandler] \(triggerName) window is non-terminal, skipping",
                level: .warn,
                fields: [
                    "sessionID": payload.sessionID,
                    "app": identity.appName ?? "unknown",
                    "bundleID": identity.bundleIdentifier ?? "nil"
                ]
            )
            return Self.httpResponse(for: tailDecision, triggerName: triggerName, sessionID: payload.sessionID)!

        case .autoFocusDisabled, .localBindingSkip, .noBindingSkip, .bindingVerificationFailed:
            // 头部 ①—④ 已处理并返回，此分支不可达；穷举仅为编译器完整性
            return Self.httpResponse(for: tailDecision, triggerName: triggerName, sessionID: payload.sessionID)!
        }
    }
}
