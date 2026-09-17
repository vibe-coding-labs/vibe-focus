import Foundation

// MARK: - UPS（UserPromptSubmit）搬窗决策 + 响应映射（Batch 14，与 B7 的
// WindowMove 决策树同款模式：纯决策 + 响应表，Runner 直测穷尽锁定）。
//
// 决策序 = 生产守护顺序（handleUserPromptSubmit 消费）：
//   autoRestore 关闭 → 无窗口身份 → UPS 限流 → 有 toggle 记录（回原位，
//   不论记录来自手动热键还是 Stop——2026-09-16 用户定案：气泡提交与直接在
//   Claude Code 输入框回车的归位语义必须一致；2026-09-15 生产日志实锤同一
//   手动放置窗口气泡提交归位、UPS userPlacedSkip 分叉，该分支已退役。B126
//   的 ambient 提交顾虑由「提交后自动恢复」偏好承担：关掉即整体不归位）
//   → 留在当前屏（UPS 永不搬窗：用户正在副屏/其它屏交互时拉去主屏 =
//   2026-09-11 用户明令禁止的复现行为；「拉主屏」只归 Stop）。
// 每个决策的响应码唯一且稳定。
//
// 「回原位」语义（2026-09-10 用户定案，恢复 0f0a3bc 移除的承诺）：存在 toggle
// 记录 = 拉主屏时保存过原始屏幕/工作区/位置 → UserPromptSubmit 时经
// ToggleEngine.restore 回到原位（本地会话与远程 machine_label 会话通用——
// 都在窗口身份解析之后）。震荡天然有界：记录只由真实移动创建、restore 成功
// 即清除，每次回跳都需要一次新的移动作凭证；UPS 限流闸在其前兜底。

@MainActor
extension HookEventHandler {

    /// UPS 搬窗决策。
    enum PromptMoveDecision: Equatable {
        case autoRestoreDisabled
        case noBinding
        case rateLimited(recentCount: Int, maxEvents: Int)
        case restoreToOriginal
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
            return .restoreToOriginal
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

    // MARK: - B198 additionalContext 注入（纯函数，Runner 直测）

    /// UPS 响应的环境上下文文案。绑定成功=一句轻量环境感知（窗在主/副屏）；
    /// 解析失败=诚实告知自动化不会生效（用户中途抱怨「窗口没动」时模型有据可答）。
    static func makeUPSAdditionalContext(identityResolved: Bool, onMainScreen: Bool) -> String {
        if identityResolved {
            return "[VibeFocus] 会话已绑定终端窗（\(onMainScreen ? "主屏" : "副屏")）。"
        }
        return "[VibeFocus] 注意：本会话未绑定终端窗口，窗口自动化（完成拉主屏/提交归位）不会生效。"
    }

    /// 给 UPS 响应挂 hookSpecificOutput（Claude Code UserPromptSubmit 契约）。
    /// context=nil 原样返回——线格式与历史一致。
    static func injecting(
        _ base: (statusCode: Int, response: ClaudeHookResponse),
        context: String?
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        guard let context, !context.isEmpty else { return base }
        var response = base.response
        response.hookSpecificOutput = HookSpecificOutput(
            hookEventName: "UserPromptSubmit",
            additionalContext: context
        )
        return (base.statusCode, response)
    }
}
