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

    /// UserPromptSubmit 事件处理：确保终端窗口在主屏可见。
    ///
    /// **设计原则（单向移动）**：只在窗口不在主屏时将其拉到主屏，永远不会把窗口推离主屏。
    /// 旧逻辑使用 ToggleEngine.restore() 会把窗口移回 origFrame（副屏），
    /// 导致 Stop→UPS→Stop→UPS 无限循环，窗口在主屏和副屏之间反复跳动。
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

        // 门 3/4/5 输入采集：主屏归属 / 冷却。
        let onMain = WindowManager.shared.isWindowOnMainScreen(windowID: identity.windowID)
        let inCooldown = MoveCooldownRegistry.shared.isInCooldown(windowID: identity.windowID)
        let cooldownRemaining = inCooldown ? MoveCooldownRegistry.shared.remainingSeconds(windowID: identity.windowID) : 0

        let decision = Self.decidePromptMove(
            autoRestoreEnabled: true,
            hasWindowIdentity: true,
            rateLimited: rate.limited,
            recentUPSCount: rate.recentCount,
            maxUPSEvents: Self.upsRateMaxEvents,
            isOnMainScreen: onMain,
            isInCooldown: inCooldown,
            cooldownRemainingSeconds: cooldownRemaining
        )

        switch decision {
        case .autoRestoreDisabled, .noBinding:
            return Self.promptHttpResponse(for: decision, sessionID: payload.sessionID)

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

        case .proceedToMove:
            // 窗口不在主屏 → 移到主屏（单向操作，不会推离主屏）。
            log(
                "[HookEventHandler] UserPromptSubmit: moving window to main screen",
                level: .info,
                fields: [
                    "traceID": traceID,
                    "windowID": String(identity.windowID),
                    "app": identity.appName ?? "unknown",
                    "sessionID": payload.sessionID
                ]
            )
            let moved = WindowManager.shared.moveWindowToMainScreen(
                identity: identity,
                reason: .userPromptSubmit,
                sessionID: payload.sessionID
            )
            if moved {
                MoveCooldownRegistry.shared.setCooldown(windowID: identity.windowID)
                SessionWindowRegistry.shared.reactivate(sessionID: payload.sessionID)
            }
            return Self.promptMoveOutcomeResponse(moved: moved, sessionID: payload.sessionID)
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
