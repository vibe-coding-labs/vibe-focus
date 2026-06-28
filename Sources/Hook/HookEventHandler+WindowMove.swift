import AppKit
import Foundation

// 决策逻辑已移至 HookEventHandler+WindowMove+Decision.swift
// 包含: WindowMoveDecision 枚举, decideWindowMove(), isTerminalOrIDEApp()
// 执行逻辑已移至 HookEventHandler+WindowMove+Execute.swift
// 包含: moveBindingToMainScreen(), moveWindowToMainScreenAndRespond()

@MainActor
extension HookEventHandler {

    // MARK: - Window Move Trigger (Stop / SessionEnd)

    func handleWindowMoveTrigger(
        payload: ClaudeHookPayload,
        triggerName: String,
        remoteOnly: Bool = false
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        // P-INST-31: handleWindowMoveTrigger 总耗时（Stop/SessionEnd hook 同步响应延迟；defer 统一记，含 moveBindingToMainScreen）。
        let wmtStart = Date()
        defer {
            log("[HookEventHandler] \(triggerName) finished", fields: [
                "sessionID": payload.sessionID,
                "triggerName": triggerName,
                "durationMs": String(elapsedMilliseconds(since: wmtStart))
            ])
        }
        log(
            "[HookEventHandler] \(triggerName) triggered",
            fields: [
                "sessionID": payload.sessionID,
                "autoFocusEnabled": String(ClaudeHookPreferences.autoFocusOnSessionEnd),
                "cwd": payload.cwd ?? "nil"
            ]
        )

        guard ClaudeHookPreferences.autoFocusOnSessionEnd else {
            SessionWindowRegistry.shared.touch(
                sessionID: payload.sessionID,
                message: "\(triggerName) 收到（自动聚焦已关闭）"
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "auto_focus_disabled",
                    message: "\(triggerName) received, auto focus disabled",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 尝试获取 binding，无 binding 时通过 machineLabel 自愈远程 session
        let binding: WindowState
        if let existing = SessionWindowRegistry.shared.binding(for: payload.sessionID) {
            binding = existing
        } else if let label = payload.terminalCtx?.machineLabel, !label.isEmpty,
                  let identity = resolveRemoteBinding(label: label, sessionID: payload.sessionID) {
            log(
                "[HookEventHandler] \(triggerName) self-heal: resolved remote binding via machineLabel",
                level: .info,
                fields: [
                    "sessionID": payload.sessionID,
                    "machineLabel": label,
                    "windowID": String(identity.windowID),
                    "app": identity.appName ?? "unknown"
                ]
            )
            SessionWindowRegistry.shared.bind(
                sessionID: payload.sessionID,
                windowIdentity: identity,
                terminalTTY: payload.terminalCtx?.tty,
                terminalSessionID: payload.terminalCtx?.termSessionID,
                itermSessionID: payload.terminalCtx?.itermSessionID,
                cwd: payload.cwd,
                model: payload.model,
                bindingType: .remote
            )
            guard let healed = SessionWindowRegistry.shared.binding(for: payload.sessionID) else {
                return (
                    200,
                    ClaudeHookResponse(
                        ok: true, code: "no_binding_skip",
                        message: "Self-heal binding lost after registration",
                        sessionID: payload.sessionID, handled: false
                    )
                )
            }
            binding = healed
        } else {
            log(
                "[HookEventHandler] \(triggerName) no binding found, skipping",
                level: .warn,
                fields: [
                    "sessionID": payload.sessionID,
                    "machineLabel": payload.terminalCtx?.machineLabel ?? "nil",
                    "isRemote": String(payload.terminalCtx?.isRemote ?? false)
                ]
            )

            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "no_binding_skip",
                    message: "No session binding, skipping window move",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // remoteOnly 模式：triggerOnStop=false 时跳过所有绑定（不区分 local/remote）
        // 之前的逻辑只跳过 local 绑定，允许 remote 绑定通过。但用户关闭 triggerOnStop
        // 意味着"不希望任何 Stop 事件移动窗口"，不论绑定类型。
        // 如果 remote 绑定通过，窗口仍会被移动，违背用户意图。
        if remoteOnly {
            SessionWindowRegistry.shared.touch(
                sessionID: payload.sessionID,
                message: "\(triggerName) 跳过（remoteOnly 模式，triggerOnStop=false）"
            )
            log(
                "[HookEventHandler] \(triggerName) skipped (remoteOnly mode, triggerOnStop=false)",
                level: .debug,
                fields: [
                    "sessionID": payload.sessionID,
                    "windowID": String(binding.windowID),
                    "bindingType": binding.bindingType.rawValue,
                    "machineLabel": payload.terminalCtx?.machineLabel ?? "nil"
                ]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "trigger_disabled_skip",
                    message: "\(triggerName) skipped (triggerOnStop=false, no window movement)",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        guard SessionWindowRegistry.shared.verifyBinding(binding) else {
            log(
                "[HookEventHandler] \(triggerName) binding verification failed",
                level: .warn,
                fields: [
                    "sessionID": payload.sessionID,
                    "windowID": String(describing: binding.windowID),
                    "pid": String(binding.pid)
                ]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "binding_verification_failed",
                    message: "Binding verification failed, skipping window move",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        return moveBindingToMainScreen(binding: binding, payload: payload, triggerName: triggerName)
    }
}
