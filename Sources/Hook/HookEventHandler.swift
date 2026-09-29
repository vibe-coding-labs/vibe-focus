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
    /// **语义（2026-09-10 用户定案，=设置页「提交后自动恢复」的承诺；0.0.93
    /// 终局时机）**：窗口带可归位 toggle 记录（30min 时效内 + 不在原位；来源无关）
    /// → 登记 SubmitRestoreDeferral，约 3 秒后经 ToggleEngine.restore 回原位；
    /// 无记录保持单向兜底（不在主屏→拉主屏，已在主屏→跳过）。不在提交瞬间执行
    /// （回车余波先落地），气泡正开着输入则顺延——「提交后归位」必达且及时。
    ///
    /// **历史教训（0f0a3bc 曾把本路径退化成单向移主屏）**：旧 restore 实现
    /// 因 Stop→UPS 无限循环被移除，但设置页承诺未改——UI 与行为脱节数月。
    /// 新实现的可界性：restore 仅在可归位 toggle 记录存在时触发（记录只由真实
    /// 移动创建、成功即清除，每次回跳需一次新的移动作凭证）+ UPS 限流闸前置
    /// + 双通道在途去重 + 失焦延迟执行点复核资格门。
    func handleUserPromptSubmit(
        payload: ClaudeHookPayload
    ) async -> (statusCode: Int, response: ClaudeHookResponse) {
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
            return Self.injecting(
                Self.promptHttpResponse(for: .noBinding, sessionID: payload.sessionID),
                context: Self.makeUPSAdditionalContext(identityResolved: false, onMainScreen: false)
            )
        }

        // 门 2：Session 级 UPS 限流（先剪枝计数后注册，连发持续被限）。
        let now = Date()
        var limiter = sessionUPSLimiters[payload.sessionID]
            ?? UPSRateLimiter(windowDuration: Self.upsRateWindowDuration, maxEvents: Self.upsRateMaxEvents)
        let rate = limiter.registerAndEvaluate(now: now)
        sessionUPSLimiters[payload.sessionID] = limiter

        // 门 3/4/5 输入采集：toggle 记录资格归类 / 还原在途标记 / 主屏归属 / 冷却。
        // 资格门（2026-09-29 终版）：来源无关，时效 ≤30min 且不在原位即可归位；
        // 已在原位的陈旧记录仅清理不移动；气泡/UPS 双通道用在途标记去重——语义见
        // AutoRestoreRecordGate 头注与 docs/log-audit-2026-09-29.md。
        let toggleRecord = ToggleEngine.shared.load(windowID: identity.windowID)
        // 仅在有记录时做一次 CG 读回（已在原位检测）；无记录零额外查询。
        let currentFrameForGate: CGRect? = toggleRecord != nil ? cgWindowBounds(for: identity.windowID) : nil
        let recordGate = AutoRestoreRecordGate.evaluate(
            record: toggleRecord,
            now: now,
            currentFrame: currentFrameForGate,
            tolerance: WindowManager.shared.frameTolerance
        )
        if recordGate == .alreadyAtOriginalFrame, let staleRecord = toggleRecord {
            ToggleEngine.shared.clear(windowID: identity.windowID)
            log(
                "[HookEventHandler] UserPromptSubmit: window already at original position, clearing stale toggle record",
                fields: [
                    "traceID": traceID,
                    "windowID": String(identity.windowID),
                    "origFrame": QuartzRect(staleRecord.origFrame).description,
                    "sessionID": payload.sessionID
                ]
            )
        }
        let restoreAlreadyActive = RestoreInFlightRegistry.shared.isRecent(windowID: identity.windowID)
        let onMain = WindowManager.shared.isWindowOnMainScreen(windowID: identity.windowID)
        let inCooldown = MoveCooldownRegistry.shared.isInCooldown(windowID: identity.windowID)
        let cooldownRemaining = inCooldown ? MoveCooldownRegistry.shared.remainingSeconds(windowID: identity.windowID) : 0
        // B198: 绑定成功后的环境感知行（窗在主/副屏），注入本函数全部后续响应。
        let envContext = Self.makeUPSAdditionalContext(identityResolved: true, onMainScreen: onMain)

        let decision = Self.decidePromptMove(
            autoRestoreEnabled: true,
            hasWindowIdentity: true,
            rateLimited: rate.limited,
            recentUPSCount: rate.recentCount,
            maxUPSEvents: Self.upsRateMaxEvents,
            isRestoreAlreadyActive: restoreAlreadyActive,
            recordGate: recordGate,
            isOnMainScreen: onMain,
            isInCooldown: inCooldown,
            cooldownRemainingSeconds: cooldownRemaining
        )

        switch decision {
        case .autoRestoreDisabled, .noBinding:
            return Self.injecting(Self.promptHttpResponse(for: decision, sessionID: payload.sessionID), context: envContext)

        case .restoreDeferred:
            // 有可归位 toggle 记录（时效内 + 不在原位，来源无关）→ 登记延迟归位
            // （SubmitRestoreDeferral）：提交后 ~3 秒执行（0.0.93 终局语义——0.0.91
            // 的瞬间拽走与 0.0.92 的失焦保持双双被用户裁决否弃）；气泡正在输入则
            // 顺延。reactivate 由执行点在 restore 成功后补（UPS 通道携带 sessionID）。
            SubmitRestoreDeferral.shared.arm(
                windowID: identity.windowID,
                triggerSource: "hook_user_prompt_submit",
                sessionID: payload.sessionID
            )
            log(
                "[HookEventHandler] UserPromptSubmit: toggle record present, restore scheduled in a few seconds (postponed while bubble is composing)",
                level: .info,
                fields: [
                    "traceID": traceID,
                    "windowID": String(identity.windowID),
                    "sessionID": payload.sessionID
                ]
            )
            return Self.injecting(
                Self.promptHttpResponse(for: decision, sessionID: payload.sessionID),
                context: envContext
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
            return Self.injecting(Self.promptHttpResponse(for: decision, sessionID: payload.sessionID), context: envContext)

        case .restoreInProgress:
            // 双通道去重：气泡/先前通道已对该窗口占位归位（RestoreInFlightRegistry），
            // 本次诚实跳过，不重复跑全量 restore 管线。占位方成功后会做 reactivate。
            log(
                "[HookEventHandler] UserPromptSubmit: restore already in flight, skipping duplicate",
                level: .info,
                fields: [
                    "traceID": traceID,
                    "windowID": String(identity.windowID),
                    "sessionID": payload.sessionID
                ]
            )
            return Self.injecting(Self.promptHttpResponse(for: decision, sessionID: payload.sessionID), context: envContext)

        case .recordExpired:
            // 超 30min 时效的记录不再驱动自动归位（窗口多半早已回家/用户已长期使用
            // 当前位置）；记录保留——⌃Q 手动还原不受时效影响。
            log(
                "[HookEventHandler] UserPromptSubmit: toggle record expired, skipping auto-restore",
                level: .info,
                fields: [
                    "traceID": traceID,
                    "windowID": String(identity.windowID),
                    "sessionID": payload.sessionID
                ]
            )
            SessionWindowRegistry.shared.reactivate(sessionID: payload.sessionID)
            return Self.injecting(Self.promptHttpResponse(for: decision, sessionID: payload.sessionID), context: envContext)

        case .alreadyAtOriginal:
            // 窗口已在记录原位 = 陈旧记录（消费完成未清理），已在门内清理；
            // 不做任何移动，不触发 restore 管线（12:35 空转案根治点）。
            log(
                "[HookEventHandler] UserPromptSubmit: window already at original position, nothing to do",
                level: .info,
                fields: [
                    "traceID": traceID,
                    "windowID": String(identity.windowID),
                    "sessionID": payload.sessionID
                ]
            )
            SessionWindowRegistry.shared.reactivate(sessionID: payload.sessionID)
            return Self.injecting(Self.promptHttpResponse(for: decision, sessionID: payload.sessionID), context: envContext)

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
            return Self.injecting(Self.promptHttpResponse(for: decision, sessionID: payload.sessionID), context: envContext)

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
            return Self.injecting(Self.promptHttpResponse(for: decision, sessionID: payload.sessionID), context: envContext)

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
            return Self.injecting(Self.promptHttpResponse(for: decision, sessionID: payload.sessionID), context: envContext)
        }
    }

    // 窗口解析逻辑已移至 HookEventHandler+WindowResolution.swift

    // MARK: - Stop

    func handleStop(
        payload: ClaudeHookPayload
    ) async -> (statusCode: Int, response: ClaudeHookResponse) {
        // triggerOnStop=true: 处理所有 session（本地+远程）
        // triggerOnStop=false: 跳过全部 session（304373e 定案语义——remoteOnly 在一切
        // 绑定 IO 前拒绝，含远程；旧注释「仅处理远程」系漂移已修正，B176）
        let remoteOnly = !ClaudeHookPreferences.triggerOnStop
        return await handleWindowMoveTrigger(payload: payload, triggerName: "Stop", remoteOnly: remoteOnly)
    }

}
