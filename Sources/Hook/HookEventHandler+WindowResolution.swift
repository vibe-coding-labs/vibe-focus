// HookEventHandler+WindowResolution.swift
// VibeFocus — 窗口身份解析与 restore 决策
// 从 HookEventHandler.swift 中提取

import Cocoa
import Foundation

@MainActor
extension HookEventHandler {

    // MARK: - Window Identity Resolution

    // 历史注（playbook 2.16a）：decideWindowResolution/WindowResolutionSource 与
    // decideRestoreEligibility/RestoreEligibility 两套"仅测试引用"的影子决策已删除——
    // 前者只覆盖 hasBinding 分支、无法表达 self-heal 路径（真实决策在下方
    // resolveWindowIdentity 内联且无分歧语义可收敛）；后者已废弃（UPS 改为
    // 单向 moveWindowToMainScreen）。

    func resolveWindowIdentity(
        payload: ClaudeHookPayload,
        traceID: String,
        startedAt: Date
    ) -> WindowIdentity? {
        // P-INST-32: resolveWindowIdentity 耗时（startedAt 由调用方传入，此前是 dead parameter；verifyBinding CGWindowList ~5ms，resolveRemoteBinding 远程自愈偶发）。
        defer {
            log("[HookEventHandler] resolveWindowIdentity finished", level: .debug, fields: [
                "traceID": traceID,
                "sessionID": payload.sessionID,
                "durationMs": String(elapsedMilliseconds(since: startedAt))
            ])
        }
        let state = SessionWindowRegistry.shared.binding(for: payload.sessionID)

        if let state {
            log(
                "[HookEventHandler] resolveWindowIdentity: found binding",
                level: .debug,
                fields: [
                    "traceID": traceID,
                    "sessionID": payload.sessionID,
                    "windowID": String(state.windowID),
                    "bindingType": String(describing: state.bindingType),
                    "app": state.appName ?? "unknown"
                ]
            )
            if SessionWindowRegistry.shared.verifyBinding(state) {
                log(
                    "[HookEventHandler] resolveWindowIdentity: binding verified",
                    level: .debug,
                    fields: [
                        "traceID": traceID,
                        "windowID": String(state.windowID),
                        "source": "binding"
                    ]
                )
                return WindowIdentity(from: state)
            }
            log(
                "[HookEventHandler] resolveWindowIdentity: binding verification failed",
                level: .warn,
                fields: [
                    "traceID": traceID,
                    "sessionID": payload.sessionID,
                    "boundWindowID": String(state.windowID)
                ]
            )
            return nil
        }

        // 无绑定 — 尝试通过 machineLabel 自愈远程 binding
        if let label = payload.terminalCtx?.machineLabel, !label.isEmpty {
            log(
                "[HookEventHandler] resolveWindowIdentity: no binding, attempting remote self-heal",
                level: .info,
                fields: [
                    "traceID": traceID,
                    "sessionID": payload.sessionID,
                    "machineLabel": label
                ]
            )
            if let identity = resolveRemoteBinding(label: label, sessionID: payload.sessionID) {
                log(
                    "[HookEventHandler] resolveWindowIdentity: remote self-heal succeeded, registering binding",
                    level: .info,
                    fields: [
                        "traceID": traceID,
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
                return identity
            }
        }

        log(
            "[HookEventHandler] resolveWindowIdentity: no binding, cannot identify window",
            level: .warn,
            fields: [
                "traceID": traceID,
                "sessionID": payload.sessionID
            ]
        )
        return nil
    }
}
