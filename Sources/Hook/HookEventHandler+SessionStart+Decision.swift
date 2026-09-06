import Foundation

// MARK: - SessionStart 绑定决策（Batch 19，与 PromptMove/WindowMove 决策树同款模式）
//
// decideSessionBind：remote（machine_label 映射表）/ local（TTY/PPID 进程树）
// 双通道解析结果 → 绑定/失败决策；sessionBindHttpResponse：决策 → HTTP 响应
// 映射（码/文案与提取前逐字一致）。

@MainActor
extension HookEventHandler {

    enum SessionBindDecision: Equatable {
        /// 解析成功 → 注册绑定。bindingType 供 store 与审计。
        case bind(identity: WindowIdentity, bindingType: WindowState.BindingType)
        /// 远程 machine_label 未在映射表中。
        case remoteBindingFailed(label: String)
        /// 本地 TTY/PPID 进程树无法匹配窗口。
        case terminalContextMatchFailed
    }

    /// 双通道解析裁决。调用方先按 isRemote 只发起对应通道的解析（另一通道传 nil）。
    static func decideSessionBind(
        isRemote: Bool,
        machineLabel: String?,
        localResolved: WindowIdentity?,
        remoteResolved: WindowIdentity?
    ) -> SessionBindDecision {
        if isRemote {
            if let resolved = remoteResolved {
                return .bind(identity: resolved, bindingType: .remote)
            }
            return .remoteBindingFailed(label: machineLabel ?? "nil")
        }
        if let local = localResolved {
            return .bind(identity: local, bindingType: .local)
        }
        return .terminalContextMatchFailed
    }

    /// 决策 → HTTP 响应（成功终态 session_bound 的 message 按 viaLabel 区分）。
    static func sessionBindHttpResponse(
        for decision: SessionBindDecision,
        sessionID: String
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        switch decision {
        case .remoteBindingFailed(let label):
            return (
                409,
                ClaudeHookResponse(
                    ok: false, code: "remote_binding_failed",
                    message: "Remote machine label '\(label)' not mapped to a window",
                    sessionID: sessionID, handled: false
                )
            )
        case .terminalContextMatchFailed:
            return (
                409,
                ClaudeHookResponse(
                    ok: false, code: "terminal_context_match_failed",
                    message: "Terminal context could not be resolved to a window",
                    sessionID: sessionID, handled: false
                )
            )
        case .bind(_, let bindingType):
            let viaLabel = bindingType == .remote
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "session_bound",
                    message: "Session bound to terminal window via \(viaLabel ? "remote_label" : "TTY/PPID")",
                    sessionID: sessionID, handled: true
                )
            )
        }
    }
}
