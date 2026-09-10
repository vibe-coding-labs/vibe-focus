import Foundation

// MARK: - UPS（UserPromptSubmit）搬窗决策 + 响应映射（Batch 14，与 B7 的
// WindowMove 决策树同款模式：纯决策 + 响应表，Runner 直测穷尽锁定）。
//
// 决策序 = 生产守护顺序（handleUserPromptSubmit 消费）：
//   autoRestore 关闭 → 无窗口身份 → UPS 限流 → 有 toggle 记录（回原位；
//   但记录若由用户手动热键创建则跳过——用户自己放置的窗口，提交提示词
//   不得Undo其放置，2026-09-11 真机事故：语音输入中窗口被甩回副屏）
//   → 留在当前屏（UPS 永不搬窗：用户正在副屏/其它屏交互时拉去主屏 =
//   2026-09-11 用户明令禁止的复现行为；「拉主屏」只归 Stop）。
// 每个决策的响应码唯一且稳定。
//
// 「回原位」语义（2026-09-10 用户定案，恢复 0f0a3bc 移除的承诺）：存在 toggle
// 记录 = Stop 拉主屏时保存过原始屏幕/工作区/位置 → UserPromptSubmit 时经
// ToggleEngine.restore 回到原位（本地会话与远程 machine_label 会话通用——
// 都在窗口身份解析之后）。震荡天然有界：记录只由真实移动创建、restore 成功
// 即清除，每次回跳都需要一次新的 Stop 移动作凭证；UPS 限流闸在其前兜底。

@MainActor
extension HookEventHandler {

    /// UPS 搬窗决策。
    enum PromptMoveDecision: Equatable {
        case autoRestoreDisabled
        case noBinding
        case rateLimited(recentCount: Int, maxEvents: Int)
        case restoreToOriginal
        /// 有 toggle 记录但记录由用户手动热键创建 = 窗口是用户自己放置的，
        /// 提交提示词不 Undo 其放置（B126）。
        case userPlacedSkip
        case alreadyOnMain
        case cooldownActive(remainingSeconds: Int)
        /// 用户正在当前屏交互（提交即证明），窗口原地不动；「拉主屏」只归 Stop。
        case stayOnCurrentScreen
    }

    /// 守护顺序裁决（顺序即契约：前一道门不满足时不看后一道）。
    static func decidePromptMove(
        autoRestoreEnabled: Bool,
        hasWindowIdentity: Bool,
        rateLimited: Bool,
        recentUPSCount: Int,
        maxUPSEvents: Int,
        hasToggleRecord: Bool,
        recordCreatedByUser: Bool,
        isOnMainScreen: Bool,
        isInCooldown: Bool,
        cooldownRemainingSeconds: Int
    ) -> PromptMoveDecision {
        guard autoRestoreEnabled else { return .autoRestoreDisabled }
        guard hasWindowIdentity else { return .noBinding }
        if rateLimited {
            return .rateLimited(recentCount: recentUPSCount, maxEvents: maxUPSEvents)
        }
        if hasToggleRecord {
            return recordCreatedByUser ? .userPlacedSkip : .restoreToOriginal
        }
        if isOnMainScreen { return .alreadyOnMain }
        if isInCooldown {
            return .cooldownActive(remainingSeconds: cooldownRemainingSeconds)
        }
        return .stayOnCurrentScreen
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
        case .restoreToOriginal:
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "restore_to_original",
                    message: "Toggle record present, restoring window to original screen/space/position",
                    sessionID: sessionID, handled: false
                )
            )
        case .userPlacedSkip:
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "user_placed_skip",
                    message: "Window was placed by user (manual hotkey); leaving it in place",
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
        case .stayOnCurrentScreen:
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "stay_on_current_screen",
                    message: "User is interacting on current display; window stays put",
                    sessionID: sessionID, handled: false
                )
            )
        }
    }


}
