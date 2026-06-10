import Foundation
import Cocoa

@MainActor
final class HookEventHandler {
    static let shared = HookEventHandler()

    private static let autoRestoreCooldownSeconds: TimeInterval = 30
    private var lastAutoRestoreByWindowID: [UInt32: Date] = [:]

    // MARK: - Per-session UPS rate tracking
    // Prevents automated/loop sessions from endlessly moving the same window.
    // 54+ sessions on one remote machine → all mapped to one window → constant jumping.

    /// Sliding-window UPS counter per session.
    private struct UPSRateWindow {
        var timestamps: [Date] = []
        /// Prune events older than `windowDuration` and return the count of remaining events.
        mutating func pruneAndCount(now: Date, windowDuration: TimeInterval) -> Int {
            timestamps = timestamps.filter { now.timeIntervalSince($0) < windowDuration }
            return timestamps.count
        }
    }

    private var sessionUPSRate: [String: UPSRateWindow] = [:]

    /// Sliding window duration for UPS rate tracking (10 minutes)
    private static let upsRateWindowDuration: TimeInterval = 600
    /// Max UPS events per session within the window before triggering rate limit
    private static let upsRateMaxEvents: Int = 20

    private init() {}

    // MARK: - Pure Decision Helpers (extracted for testability)

    /// Pure: is a window still in the auto-restore cooldown period?
    static func isInCooldown(lastRestore: Date?, now: Date = Date(), cooldownSeconds: TimeInterval = 30) -> Bool {
        guard let lastRestore else { return false }
        return now.timeIntervalSince(lastRestore) < cooldownSeconds
    }

    /// Check if a window is in move cooldown — recently restored by user or UPS.
    /// Used by Stop handler to avoid re-moving a window the user just put back.
    func isWindowInMoveCooldown(windowID: UInt32) -> Bool {
        return Self.isInCooldown(lastRestore: lastAutoRestoreByWindowID[windowID])
    }

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

        log(
            "[HookEventHandler] UserPromptSubmit triggered",
            fields: [
                "traceID": traceID,
                "sessionID": payload.sessionID,
                "autoRestoreEnabled": String(ClaudeHookPreferences.autoRestoreOnPromptSubmit),
                "cwd": payload.cwd ?? "nil"
            ]
        )

        guard ClaudeHookPreferences.autoRestoreOnPromptSubmit else {
            SessionWindowRegistry.shared.touch(
                sessionID: payload.sessionID,
                message: "UserPromptSubmit 收到（自动恢复已关闭）"
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "auto_restore_disabled",
                    message: "UserPromptSubmit received, auto restore disabled",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 1. 解析窗口身份
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
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "no_binding_skip",
                    message: "Could not resolve window identity",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 1.5. Session-level UPS rate limit — prevents automated/loop sessions
        // from endlessly moving the same window (e.g., 54 sessions on one remote machine).
        let now = Date()
        var rateWindow = sessionUPSRate[payload.sessionID] ?? UPSRateWindow()
        let recentCount = rateWindow.pruneAndCount(now: now, windowDuration: Self.upsRateWindowDuration)
        rateWindow.timestamps.append(now)
        sessionUPSRate[payload.sessionID] = rateWindow

        if recentCount >= Self.upsRateMaxEvents {
            log(
                "[HookEventHandler] UserPromptSubmit: session rate-limited (automated session detected), skipping move",
                level: .info,
                fields: [
                    "traceID": traceID,
                    "sessionID": payload.sessionID,
                    "windowID": String(identity.windowID),
                    "upsCount": String(recentCount),
                    "upsMax": String(Self.upsRateMaxEvents)
                ]
            )
            SessionWindowRegistry.shared.touch(
                sessionID: payload.sessionID,
                message: "UserPromptSubmit 被限流（session 自动化检测）"
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "session_rate_limited",
                    message: "Session UPS rate limited (\(recentCount)/\(Self.upsRateMaxEvents) in 10min), skipping move",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 2. 窗口已在主屏 → 无需操作
        if WindowManager.shared.isWindowOnMainScreen(windowID: identity.windowID) {
            log(
                "[HookEventHandler] UserPromptSubmit: window already on main screen, skipping",
                fields: [
                    "traceID": traceID,
                    "windowID": String(identity.windowID),
                    "sessionID": payload.sessionID
                ]
            )
            SessionWindowRegistry.shared.reactivate(sessionID: payload.sessionID)
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "already_on_main_screen",
                    message: "Window already on main screen, no action needed",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 3. 冷却检查：同一窗口在冷却期内不重复移动
        if let lastRestore = lastAutoRestoreByWindowID[identity.windowID],
           Date().timeIntervalSince(lastRestore) < Self.autoRestoreCooldownSeconds {
            let remaining = Int(Self.autoRestoreCooldownSeconds - Date().timeIntervalSince(lastRestore))
            log(
                "[HookEventHandler] UserPromptSubmit: cooldown active, skipping",
                level: .info,
                fields: [
                    "traceID": traceID,
                    "windowID": String(identity.windowID),
                    "cooldownRemaining": String(remaining) + "s"
                ]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "cooldown_active",
                    message: "Auto-restore cooldown active (\(remaining)s remaining)",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 4. 窗口不在主屏 → 移到主屏（单向操作，不会推离主屏）
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
            lastAutoRestoreByWindowID[identity.windowID] = Date()
            SessionWindowRegistry.shared.reactivate(sessionID: payload.sessionID)
        }

        return (
            200,
            ClaudeHookResponse(
                ok: true,
                code: moved ? "moved_to_main" : "move_failed",
                message: moved ? "Window moved to main screen" : "Failed to move window to main screen",
                sessionID: payload.sessionID,
                handled: moved
            )
        )
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

    func clearAutoRestoreCooldown(windowID: UInt32) {
        lastAutoRestoreByWindowID.removeValue(forKey: windowID)
    }

    /// Stop 移动窗口后设置冷却期，阻止 UserPromptSubmit 立即 restore 同一窗口
    func setMoveCooldown(windowID: UInt32) {
        lastAutoRestoreByWindowID[windowID] = Date()
    }

}
