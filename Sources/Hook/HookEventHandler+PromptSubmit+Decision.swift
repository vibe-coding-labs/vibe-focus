import Foundation

// MARK: - UPS（UserPromptSubmit）搬窗决策 + 响应映射（Batch 14，与 B7 的
// WindowMove 决策树同款模式：纯决策 + 响应表，Runner 直测穷尽锁定）。
//
// 决策序 = 生产守护顺序（handleUserPromptSubmit 消费）：
//   autoRestore 关闭 → 无窗口身份 → UPS 限流 → 已在主屏 → 冷却中 → 搬窗。
// 每个决策的响应码唯一且稳定；「单向移动」原则（只拉向主屏、永不推离）由
// 决策集不含任何「移离主屏」分支体现。

@MainActor
extension HookEventHandler {

    /// UPS 搬窗决策。
    enum PromptMoveDecision: Equatable {
        case autoRestoreDisabled
        case noBinding
        case rateLimited(recentCount: Int, maxEvents: Int)
        case alreadyOnMain
        case cooldownActive(remainingSeconds: Int)
        case proceedToMove
    }

    /// 守护顺序裁决（顺序即契约：前一道门不满足时不看后一道）。
    static func decidePromptMove(
        autoRestoreEnabled: Bool,
        hasWindowIdentity: Bool,
        rateLimited: Bool,
        recentUPSCount: Int,
        maxUPSEvents: Int,
        isOnMainScreen: Bool,
        isInCooldown: Bool,
        cooldownRemainingSeconds: Int
    ) -> PromptMoveDecision {
        guard autoRestoreEnabled else { return .autoRestoreDisabled }
        guard hasWindowIdentity else { return .noBinding }
        if rateLimited {
            return .rateLimited(recentCount: recentUPSCount, maxEvents: maxUPSEvents)
        }
        if isOnMainScreen { return .alreadyOnMain }
        if isInCooldown {
            return .cooldownActive(remainingSeconds: cooldownRemainingSeconds)
        }
        return .proceedToMove
    }

    /// 决策 → HTTP 响应映射表（每个决策的码/文案唯一且稳定）。
    static func promptHttpResponse(for decision: PromptMoveDecision, sessionID: String) -> (statusCode: Int, response: ClaudeHookResponse) {
        switch decision {
        case .autoRestoreDisabled:
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "auto_restore_disabled",
                    message: "UserPromptSubmit received, auto restore disabled",
                    sessionID: sessionID, handled: false
                )
            )
        case .noBinding:
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "no_binding_skip",
                    message: "Could not resolve window identity",
                    sessionID: sessionID, handled: false
                )
            )
        case .rateLimited(let recentCount, let maxEvents):
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "session_rate_limited",
                    message: "Session UPS rate limited (\(recentCount)/\(maxEvents) in 10min), skipping move",
                    sessionID: sessionID, handled: false
                )
            )
        case .alreadyOnMain:
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "already_on_main_screen",
                    message: "Window already on main screen, no action needed",
                    sessionID: sessionID, handled: false
                )
            )
        case .cooldownActive(let remainingSeconds):
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "cooldown_active",
                    message: "Auto-restore cooldown active (\(remainingSeconds)s remaining)",
                    sessionID: sessionID, handled: false
                )
            )
        case .proceedToMove:
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "proceed_to_move",
                    message: "Proceeding to move window",
                    sessionID: sessionID, handled: false
                )
            )
        }
    }

    /// 搬窗结果二分响应（moved → 200 window_focused；失败 → 200 move_failed，
    /// handled 反映是否真的动了窗）。
    static func promptMoveOutcomeResponse(moved: Bool, sessionID: String) -> (statusCode: Int, response: ClaudeHookResponse) {
        (
            200,
            ClaudeHookResponse(
                ok: true, code: moved ? "moved_to_main" : "move_failed",
                message: moved ? "Window moved to main screen" : "Failed to move window to main screen",
                sessionID: sessionID, handled: moved
            )
        )
    }
}
