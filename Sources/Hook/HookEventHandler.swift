import Foundation
import Cocoa

@MainActor
final class HookEventHandler {
    static let shared = HookEventHandler()

    // 窗口移动冷却状态已抽至 MoveCooldownRegistry（Support/）——
    // 引擎层 restore/move_to_main 后直接写注册表，不再回调本类（断开 Hook→Window→Hook 环）。

    // MARK: - Per-session UPS rate tracking
    // Prevents automated/loop sessions from endlessly moving the same window.
    // 54+ sessions on one remote machine → all mapped to one window → constant jumping.
    // Batch 14：滑动窗口限流器提取为 UPSRateLimiter（internal，真身直测穷尽锁定）。

    private var sessionUPSLimiters: [String: UPSRateLimiter] = [:]

    /// Sliding window duration for UPS rate tracking (10 minutes)
    private static let upsRateWindowDuration: TimeInterval = 600
    /// Max UPS events per session within the window before triggering rate limit
    private static let upsRateMaxEvents: Int = 20

    private init() {}

    // handleSessionStart 已移至 HookEventHandler+SessionStart.swift

    // MARK: - User Prompt Submit

    /// UserPromptSubmit 事件处理：双向编排的「回程」——提交新提示词时回原位。
    ///
    /// **语义（2026-09-10 用户定案，=设置页「提交后自动恢复」的承诺）**：
    /// 窗口带 toggle 记录（Stop 拉主屏时保存的原始屏幕/工作区/位置）→ 经
    /// ToggleEngine.restore 回原位；无记录保持单向兜底（不在主屏→拉主屏，
    /// 已在主屏→跳过）。
    ///
    /// **历史教训（0f0a3bc 曾把本路径退化成单向移主屏）**：旧 restore 实现
    /// 因 Stop→UPS 无限循环被移除，但设置页承诺未改——UI 与行为脱节数月。
    /// 新实现的可界性：restore 仅在 toggle 记录存在时触发（记录只由真实移动
    /// 创建、成功即清除，每次回跳需一次新的 Stop 移动作凭证）+ UPS 限流闸前置。
    func handleUserPromptSubmit(
        payload: ClaudeHookPayload
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        let traceID = makeOperationID(prefix: "ups")
        // P-INST-29: handleUserPromptSubmit 总耗时（hook 同步响应延迟；defer 统一记，outcome 见各路径 code 字段，用 traceID 关联）。
        #if PERF_INSTRUMENT
        let upsStart = Date()
        defer {
            log("[HookEventHandler] UserPromptSubmit finished", fields: [
                "traceID": traceID,
                "sessionID": payload.sessionID,
                "durationMs": String(elapsedMilliseconds(since: upsStart))
            ])
        }
        #endif

        log(
            "[HookEventHandler] UserPromptSubmit triggered",
            fields: [
                "traceID": traceID,
                "sessionID": payload.sessionID,
                "autoRestoreEnabled": String(ClaudeHookPreferences.autoRestoreOnPromptSubmit),
                "cwd": payload.cwd ?? "nil"
            ]
        )

        // Batch 14：五重门决策收敛为 decidePromptMove 纯判定 + 响应表
        //（+PromptSubmit+Decision.swift，Runner 真身穷尽锁定）。守护顺序：
        // disabled → 无身份 → 限流 → 已在主屏 → 冷却 → 搬窗。

        // 门 0：自动恢复总开关。
        guard ClaudeHookPreferences.autoRestoreOnPromptSubmit else {
            SessionWindowRegistry.shared.touch(
                sessionID: payload.sessionID,
                message: "UserPromptSubmit 收到（自动恢复已关闭）"
            )
            return Self.promptHttpResponse(for: .autoRestoreDisabled, sessionID: payload.sessionID)
        }

        // 门 1：解析窗口身份。
        guard let identity = resolveWindowIdentity(payload: payload, traceID: traceID, startedAt: Date()) else {
            log(
                "[HookEventHandler] UserPromptSubmit: window identity resolution failed",
                level: .warn,
                fields: [
                    "traceID": traceID,
                    "sessionID": payload.sessionID,
                    "hasTerminalCtx": String(payload.terminalCtx != nil),
                    "machineLabel": payload.terminalCtx?.machineLabel ?? "nil"
                ]
            )
            return Self.promptHttpResponse(for: .noBinding, sessionID: payload.sessionID)
        }

        // 门 2：Session 级 UPS 限流（先剪枝计数后注册，连发持续被限）。
        let now = Date()
        var limiter = sessionUPSLimiters[payload.sessionID]
            ?? UPSRateLimiter(windowDuration: Self.upsRateWindowDuration, maxEvents: Self.upsRateMaxEvents)
        let rate = limiter.registerAndEvaluate(now: now)
        sessionUPSLimiters[payload.sessionID] = limiter

        // 门 3/4/5 输入采集：toggle 记录（Stop 拉主屏时保存的原始位置）/ 主屏归属 / 冷却。
        let toggleRecord = ToggleEngine.shared.load(windowID: identity.windowID)
        let hasToggleRecord = toggleRecord != nil
        // B126：记录由用户手动热键创建 = 窗口是用户自己放置的，UPS 不 Undo 其放置
        let recordCreatedByUser = toggleRecord?.reason == WindowMoveReason.manualHotkey.rawValue
        let onMain = WindowManager.shared.isWindowOnMainScreen(windowID: identity.windowID)
        let inCooldown = MoveCooldownRegistry.shared.isInCooldown(windowID: identity.windowID)
        let cooldownRemaining = inCooldown ? MoveCooldownRegistry.shared.remainingSeconds(windowID: identity.windowID) : 0

        let decision = Self.decidePromptMove(
            autoRestoreEnabled: true,
            hasWindowIdentity: true,
            rateLimited: rate.limited,
            recentUPSCount: rate.recentCount,
            maxUPSEvents: Self.upsRateMaxEvents,
            hasToggleRecord: hasToggleRecord,
            recordCreatedByUser: recordCreatedByUser,
            isOnMainScreen: onMain,
            isInCooldown: inCooldown,
            cooldownRemainingSeconds: cooldownRemaining
        )

        switch decision {
        case .autoRestoreDisabled, .noBinding:
            return Self.promptHttpResponse(for: decision, sessionID: payload.sessionID)

        case .userPlacedSkip:
            // 用户手动热键放置的窗口：提交提示词不 Undo 其放置，原样留在原地
            //（B126：语音输入中窗口被自动恢复甩回副屏的真机事故修复）
            log(
                "[HookEventHandler] UserPromptSubmit: window placed by user (manual hotkey), leaving in place",
                level: .info,
                fields: [
                    "traceID": traceID,
                    "windowID": String(identity.windowID),
                    "sessionID": payload.sessionID
                ]
            )
            return Self.promptHttpResponse(for: decision, sessionID: payload.sessionID)

        case .restoreToOriginal:
            // 有 toggle 记录 = Stop 拉主屏时保存过原始屏幕/工作区/位置 → 经
            // ToggleEngine.restore 回原位（本地会话与远程 machine_label 会话通用）。
            // 记录在 restore 成功后由引擎清除：每次回跳都需要一次新的 Stop 移动作
            // 凭证，配合前置 UPS 限流闸，震荡天然有界。
            log(
                "[HookEventHandler] UserPromptSubmit: toggle record present, restoring to original screen/space/position",
                level: .info,
                fields: [
                    "traceID": traceID,
                    "windowID": String(identity.windowID),
                    "sessionID": payload.sessionID
                ]
            )
            let outcome = ToggleEngine.shared.restore(
                windowID: identity.windowID,
                triggerSource: "hook_user_prompt_submit",
                traceID: traceID
            )
            var restored = false
            if case .restored = outcome { restored = true }
            if restored {
                SessionWindowRegistry.shared.reactivate(sessionID: payload.sessionID)
            } else {
                log(
                    "[HookEventHandler] UserPromptSubmit: restore to original failed",
                    level: .warn,
                    fields: [
                        "traceID": traceID,
                        "windowID": String(identity.windowID),
                        "outcome": outcome.outcomeLabel,
                        "sessionID": payload.sessionID
                    ]
                )
            }
            return (
                200,
                ClaudeHookResponse(
                    ok: true,
                    code: restored ? "restored_to_original" : "restore_failed",
                    message: restored
                        ? "Window restored to original screen/space/position"
                        : "Restore to original position failed (\(outcome.outcomeLabel))",
                    sessionID: payload.sessionID,
                    handled: restored
                )
            )

        case .rateLimited:
            log(
                "[HookEventHandler] UserPromptSubmit: session rate-limited (automated session detected), skipping move",
                level: .info,
                fields: [
                    "traceID": traceID,
                    "sessionID": payload.sessionID,
                    "windowID": String(identity.windowID),
                    "upsCount": String(rate.recentCount),
                    "upsMax": String(Self.upsRateMaxEvents)
                ]
            )
            SessionWindowRegistry.shared.touch(
                sessionID: payload.sessionID,
                message: "UserPromptSubmit 被限流（session 自动化检测）"
            )
            return Self.promptHttpResponse(for: decision, sessionID: payload.sessionID)

        case .alreadyOnMain:
            log(
                "[HookEventHandler] UserPromptSubmit: window already on main screen, skipping",
                fields: [
                    "traceID": traceID,
                    "windowID": String(identity.windowID),
                    "sessionID": payload.sessionID
                ]
            )
            SessionWindowRegistry.shared.reactivate(sessionID: payload.sessionID)
            return Self.promptHttpResponse(for: decision, sessionID: payload.sessionID)

        case .cooldownActive(let remaining):
            log(
                "[HookEventHandler] UserPromptSubmit: cooldown active, skipping",
                level: .info,
                fields: [
                    "traceID": traceID,
                    "windowID": String(identity.windowID),
                    "cooldownRemaining": String(remaining) + "s"
                ]
            )
            return Self.promptHttpResponse(for: decision, sessionID: payload.sessionID)

        case .stayOnCurrentScreen:
            // B126：用户在副屏/其它屏提交提示词 = 正在该屏交互，窗口原地不动。
            // 「拉主屏」只归 Stop（claude 完成时）；提交即搬窗是用户明令禁止的
            // 复现行为（2026-09-11：副屏输入回车被拉主屏）。
            log(
                "[HookEventHandler] UserPromptSubmit: staying on current screen (user interacting)",
                level: .info,
                fields: [
                    "traceID": traceID,
                    "windowID": String(identity.windowID),
                    "sessionID": payload.sessionID
                ]
            )
            return Self.promptHttpResponse(for: decision, sessionID: payload.sessionID)
        }
    }

    // 窗口解析逻辑已移至 HookEventHandler+WindowResolution.swift

    // MARK: - Stop

    func handleStop(
        payload: ClaudeHookPayload
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        // triggerOnStop=true: 处理所有 session（本地+远程）
        // triggerOnStop=false: 仅处理远程 session（跳过本地绑定）
        let remoteOnly = !ClaudeHookPreferences.triggerOnStop
        return handleWindowMoveTrigger(payload: payload, triggerName: "Stop", remoteOnly: remoteOnly)
    }

}
