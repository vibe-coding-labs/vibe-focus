// HookEventHandler+WindowResolution.swift
// VibeFocus — 窗口身份解析与 restore 决策
// 从 HookEventHandler.swift 中提取

import Cocoa
import Foundation

@MainActor
extension HookEventHandler {

    // MARK: - Window Identity Resolution

    /// Window identity resolution decision — extracted for testability.
    enum WindowResolutionSource {
        case binding(WindowIdentity)
    }

    /// Pure decision logic for resolveWindowIdentity.
    static func decideWindowResolution(
        hasBinding: Bool,
        bindingVerified: Bool,
        bindingIdentity: WindowIdentity?
    ) -> WindowResolutionSource? {
        if hasBinding {
            if bindingVerified, let identity = bindingIdentity {
                return .binding(identity)
            }
            return nil
        }
        return nil
    }

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

    // MARK: - Restore Eligibility (Deprecated — kept for test compatibility)

    /// Restore eligibility decision — extracted for testability.
    /// ⚠️ 注意：此 enum 及 decideRestoreEligibility 仅被测试引用，生产代码不再使用。
    /// UserPromptSubmit 现在直接使用 moveWindowToMainScreen（单向移动到主屏）。
    enum RestoreEligibility {
        case eligible(record: ToggleRecord, mainScreenFrame: CGRect)
        case toggleInFlight
        case windowNotOnMainScreen
        case noRecord
        case recordInvalid(windowID: UInt32)
    }

    /// Pure decision logic for validateRestoreEligibility.
    static func decideRestoreEligibility(
        isToggleInFlight: Bool,
        isWindowOnMainScreen: Bool,
        record: ToggleRecord?,
        mainScreenFrame: CGRect?
    ) -> RestoreEligibility {
        if isToggleInFlight { return .toggleInFlight }
        // 不再要求窗口必须在主屏 — 窗口在副屏但有 ToggleRecord 时也应该可以 restore
        guard let record else { return .noRecord }
        guard let mainScreenFrame, record.isValid(mainScreenFrame: mainScreenFrame) else {
            return .recordInvalid(windowID: record.windowID)
        }
        return .eligible(record: record, mainScreenFrame: mainScreenFrame)
    }
}
