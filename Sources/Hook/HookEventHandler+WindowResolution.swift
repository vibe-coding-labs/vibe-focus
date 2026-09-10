// HookEventHandler+WindowResolution.swift
// VibeFocus — 会话→窗口绑定解析（Stop/SessionEnd 与 UPS 共用同一套编排）
// 从 HookEventHandler.swift 中提取
//
// 历史注（playbook 2.16a 第十一步刀）：此前"绑定查找 + machineLabel 自愈 + 注册 +
// 活性校验"在 resolveWindowIdentity（UPS 路径）与 handleWindowMoveTrigger（Stop 路径）
// 各写一份、日志文案与校验时序各有漂移（UPS 自愈后不再校验，Stop 自愈后校验）。
// 现收敛为唯一执行器 resolveSessionBinding，纯决策 decideSessionBindingStep 锁定分支顺序。
// 统一后的不变量：凡以 .bound/.healed 交付的绑定都通过了 verifyBinding 活性校验。

import Cocoa
import Foundation

/// 会话绑定解析的下一步动作（纯决策，生产按此执行）
enum SessionBindingStep: Equatable {
    /// 已有绑定 → 活性校验
    case verifyExisting
    /// 无绑定但 machineLabel 非空 → 尝试远程自愈
    case attemptSelfHeal
    /// 无绑定且无法自愈 → 放弃
    case giveUp
}

/// resolveSessionBinding 的解析结果
enum SessionBindingOutcome {
    /// 已有绑定，通过活性校验
    case bound(WindowState)
    /// 绑定存在但活性校验失败（PID 消失 / 窗口消失 / 归属易主）
    case verificationFailed(WindowState)
    /// 无绑定，经 machineLabel 自愈注册成功且通过活性校验
    case healed(WindowState)
    /// 自愈 bind 已执行但立即重取失败（近乎不可达的竞态；调用方据此区分响应文案）
    case healLost
    /// 无绑定且无法自愈（无 label / label 未映射 / 映射窗口已消失）
    case none
}

@MainActor
extension HookEventHandler {

    // MARK: - Pure Decision

    /// 绑定解析分支决策（纯函数）——顺序即执行器行为：
    /// 有绑定先验证（自愈只救"无绑定"，不救"绑定失效"）；
    /// 自愈仅在无绑定且 label 非空时尝试（历史两处内联各自判断，此处唯一事实源）。
    static func decideSessionBindingStep(
        hasBinding: Bool,
        machineLabel: String?
    ) -> SessionBindingStep {
        if hasBinding { return .verifyExisting }
        if let label = machineLabel, !label.isEmpty { return .attemptSelfHeal }
        return .giveUp
    }

    // MARK: - Shared Resolution

    /// 会话→窗口绑定的唯一解析编排：查找 → （无绑定时）machineLabel 远程自愈 → 活性校验。
    /// Stop/SessionEnd（handleWindowMoveTrigger）与 UPS（resolveWindowIdentity）共用。
    /// - Parameter traceID: 调用方追踪标识（Stop/SessionEnd 传 triggerName，UPS 传 traceID）
    func resolveSessionBinding(
        payload: ClaudeHookPayload,
        traceID: String
    ) -> SessionBindingOutcome {
        let existing = SessionWindowRegistry.shared.binding(for: payload.sessionID)

        switch Self.decideSessionBindingStep(
            hasBinding: existing != nil,
            machineLabel: payload.terminalCtx?.machineLabel
        ) {
        case .verifyExisting:
            let binding = existing!
            log(
                "[HookEventHandler] resolveSessionBinding: found binding",
                level: .debug,
                fields: [
                    "traceID": traceID,
                    "sessionID": payload.sessionID,
                    "windowID": String(binding.windowID),
                    "bindingType": binding.bindingType.rawValue,
                    "app": binding.appName ?? "unknown"
                ]
            )
            if SessionWindowRegistry.shared.verifyBinding(binding) {
                log(
                    "[HookEventHandler] resolveSessionBinding: binding verified",
                    level: .debug,
                    fields: [
                        "traceID": traceID,
                        "windowID": String(binding.windowID),
                        "source": "binding"
                    ]
                )
                return .bound(binding)
            }
            log(
                "[HookEventHandler] resolveSessionBinding: binding verification failed",
                level: .warn,
                fields: [
                    "traceID": traceID,
                    "sessionID": payload.sessionID,
                    "boundWindowID": String(binding.windowID)
                ]
            )
            return .verificationFailed(binding)

        case .attemptSelfHeal:
            let label = payload.terminalCtx?.machineLabel ?? ""
            log(
                "[HookEventHandler] resolveSessionBinding: no binding, attempting remote self-heal",
                level: .info,
                fields: [
                    "traceID": traceID,
                    "sessionID": payload.sessionID,
                    "machineLabel": label
                ]
            )
            guard let identity = resolveRemoteBinding(label: label, sessionID: payload.sessionID) else {
                return .none
            }
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
                log(
                    "[HookEventHandler] resolveSessionBinding: heal registered but binding lost immediately",
                    level: .warn,
                    fields: [
                        "traceID": traceID,
                        "sessionID": payload.sessionID,
                        "windowID": String(identity.windowID)
                    ]
                )
                return .healLost
            }
            // 与既有绑定同一门槛：自愈产物也必须通过活性校验才交付
            // （历史 UPS 路径自愈后不校验，属两路漂移；Stop 路径本就校验，行为不变）
            guard SessionWindowRegistry.shared.verifyBinding(healed) else {
                log(
                    "[HookEventHandler] resolveSessionBinding: healed binding verification failed",
                    level: .warn,
                    fields: [
                        "traceID": traceID,
                        "sessionID": payload.sessionID,
                        "windowID": String(healed.windowID)
                    ]
                )
                return .verificationFailed(healed)
            }
            log(
                "[HookEventHandler] resolveSessionBinding: remote self-heal succeeded",
                level: .info,
                fields: [
                    "traceID": traceID,
                    "sessionID": payload.sessionID,
                    "machineLabel": label,
                    "windowID": String(healed.windowID),
                    "app": healed.appName ?? "unknown"
                ]
            )
            return .healed(healed)

        case .giveUp:
            log(
                "[HookEventHandler] resolveSessionBinding: no binding, cannot identify window",
                level: .warn,
                fields: [
                    "traceID": traceID,
                    "sessionID": payload.sessionID,
                    "machineLabel": payload.terminalCtx?.machineLabel ?? "nil",
                    "isRemote": String(payload.terminalCtx?.isRemote ?? false)
                ]
            )
            return .none
        }
    }

    // MARK: - UPS Adapter

    /// UPS 路径的窗口身份解析——共享解析器的 WindowIdentity 适配。
    func resolveWindowIdentity(
        payload: ClaudeHookPayload,
        traceID: String,
        startedAt: Date
    ) -> WindowIdentity? {
        // P-INST-32: resolveWindowIdentity 耗时（startedAt 由调用方传入；verifyBinding CGWindowList ~5ms，resolveRemoteBinding 远程自愈偶发）。
        defer {
            log("[HookEventHandler] resolveWindowIdentity finished", level: .debug, fields: [
                "traceID": traceID,
                "sessionID": payload.sessionID,
                "durationMs": String(elapsedMilliseconds(since: startedAt))
            ])
        }
        switch resolveSessionBinding(payload: payload, traceID: traceID) {
        case .bound(let state), .healed(let state):
            return WindowIdentity(from: state)
        case .verificationFailed, .healLost, .none:
            return nil
        }
    }
}
