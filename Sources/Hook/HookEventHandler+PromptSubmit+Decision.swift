import Foundation

// MARK: - UPS（UserPromptSubmit）搬窗决策 + 响应映射（Batch 14，与 B7 的
// WindowMove 决策树同款模式：纯决策 + 响应表，Runner 直测穷尽锁定）。
//
// 决策序 = 生产守护顺序（handleUserPromptSubmit 消费）：
//   autoRestore 关闭 → 无窗口身份 → UPS 限流 → 还原已在途（气泡/UPS 双通道
//   去重，RestoreInFlightRegistry）→ toggle 记录资格门（AutoRestoreRecordGate：
//   eligible 延迟归位[来源无关]；expired 超 30min 时效不归位；alreadyAtOriginalFrame
//   已在原位仅清理）→ 留在当前屏（UPS 永不搬窗：用户正在副屏/其它屏交互时拉去
//   主屏 = 2026-09-11 用户明令禁止的复现行为；「拉主屏」只归 Stop）。
// 每个决策的响应码唯一且稳定。
//
// 「回原位」语义（2026-09-10 用户定案，恢复 0f0a3bc 移除的承诺；2026-09-29 凌晨
// 用户裁决：**与记录来源无关**；2026-09-29 晚两度裁决：先「不得在干活时拽走」
// （0.0.92 失焦保持），同晚实测「提交后窗不回=开关承诺被违背」（用户三次手动
// ⌃Q 送回）→ **0.0.93 终局：提交后 ~3 秒归位，气泡正开着输入则顺延**——归位
// 必达且及时，唯一顺延条件是用户已经在写下一条）：存在可归位 toggle 记录
// （时效内 + 不在原位）→ UserPromptSubmit 登记 SubmitRestoreDeferral，约 3 秒后
// 经 ToggleEngine.restore 回到原位（本地会话与远程 machine_label 会话通用——都在
// 窗口身份解析之后）。震荡天然有界：记录只由真实移动创建、restore 成功即清除，
// 每次回跳都需要一次新的移动作凭证；UPS 限流闸在其前兜底。
//
// ## 修订史（供后续会话理解，勿再单方向推翻；全量取证 docs/log-audit-2026-09-29.md）
// B126(9-11 userPlacedSkip) → 65a1ad2(9-16 有记录即归位) → 0.0.90(9-28 手动摆位
// 粘滞——**实测回归**：装机 40 分钟拦掉 9 次真实提交归位，17:00~17:39Z 日志铁证)
// → 0.0.91(回退粘滞，9-28 主诉的真凶由时效门[recordExpired]/已在原位短路
// [alreadyAtOriginal]/双通道在途去重[restoreInProgress]承担，这三门保留)
// → 0.0.92(失焦归位，装机实测违背开关承诺) → 0.0.93(本版：延迟 3 秒 + 气泡输入
// 中顺延，restoreDeferred)。

@MainActor
extension HookEventHandler {

    /// UPS 搬窗决策。
    enum PromptMoveDecision: Equatable {
        case autoRestoreDisabled
        case noBinding
        case rateLimited(recentCount: Int, maxEvents: Int)
        /// 气泡/UPS 双通道去重：该窗口已有归位在途（RestoreInFlightRegistry）。
        case restoreInProgress
        /// 有可归位记录 → 不立即执行，登记延迟归位（SubmitRestoreDeferral），
        /// ~3 秒后由节拍复核资格门归位；气泡正在输入则顺延（0.0.93）。
        case restoreDeferred
        /// 记录超时效（AutoRestoreRecordGate.maxRecordAgeSeconds）→ 不再驱动自动归位。
        case recordExpired
        /// 窗口已在记录原位 → 无需移动（陈旧记录由调用方清理）。
        case alreadyAtOriginal
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
        isRestoreAlreadyActive: Bool,
        recordGate: AutoRestoreRecordGate,
        isOnMainScreen: Bool,
        isInCooldown: Bool,
        cooldownRemainingSeconds: Int
    ) -> PromptMoveDecision {
        guard autoRestoreEnabled else { return .autoRestoreDisabled }
        guard hasWindowIdentity else { return .noBinding }
        if rateLimited {
            return .rateLimited(recentCount: recentUPSCount, maxEvents: maxUPSEvents)
        }
        if isRestoreAlreadyActive {
            return .restoreInProgress
        }
        switch recordGate {
        case .eligible:
            return .restoreDeferred
        case .expired:
            return .recordExpired
        case .alreadyAtOriginalFrame:
            return .alreadyAtOriginal
        case .none:
            break
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
        case .restoreInProgress:
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "restore_already_active",
                    message: "A restore for this window is already in progress; skipping duplicate",
                    sessionID: sessionID, handled: false
                )
            )
        case .restoreDeferred:
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "restore_deferred",
                    message: "Toggle record present; window will return to its original position in a few seconds",
                    sessionID: sessionID, handled: false
                )
            )
        case .recordExpired:
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "toggle_record_expired",
                    message: "Toggle record older than 30min; leaving window in place",
                    sessionID: sessionID, handled: false
                )
            )
        case .alreadyAtOriginal:
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "already_at_original",
                    message: "Window already at original position; stale record cleared",
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
