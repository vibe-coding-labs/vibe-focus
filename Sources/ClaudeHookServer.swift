import Foundation
import Cocoa
@preconcurrency import GCDWebServer

@MainActor
final class ClaudeHookServer: ObservableObject {
    static let shared = ClaudeHookServer()

    @Published private(set) var isRunning = false
    @Published private(set) var statusDescription = "未启动"
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var lastEventAt: Date?
    @Published private(set) var totalRequestCount = 0
    @Published private(set) var handledRequestCount = 0
    @Published private(set) var unmatchedSessionCount = 0

    private var server: GCDWebServer?
    private var activePort: Int?
    private var configuredToken: String?

    /// 记录每个 session 最后收到 UserPromptSubmit 的时间，用于 Stop 防抖
    private var lastActivityBySession: [String: Date] = [:]
    /// Stop 防抖阈值：超过此时间无活动才视为真正结束
    private let stopDebounceInterval: TimeInterval = 30.0

    private init() {}

    func applyPreferences() {
        log(
            "[ClaudeHookServer] applyPreferences called",
            level: .debug,
            fields: [
                "isEnabled": String(ClaudeHookPreferences.isEnabled),
                "port": String(ClaudeHookPreferences.listenPort),
                "hasToken": String(ClaudeHookPreferences.authToken != nil && !ClaudeHookPreferences.authToken!.isEmpty)
            ]
        )
        if ClaudeHookPreferences.isEnabled {
            ClaudeHookPreferences.ensureTokenGenerated()
            startIfNeeded(port: ClaudeHookPreferences.listenPort, token: ClaudeHookPreferences.authToken)
            // 确保辅助脚本的配置文件（端口 + token）与当前 UserDefaults 同步
            // 防止 app 重启后 token 重新生成导致 hook-config.json 中的旧 token 失效
            ClaudeHookPreferences.writeConfigFile()
            ClaudeHookPreferences.installHelperScript()
        } else {
            stop()
        }
    }

    func stop() {
        log(
            "[ClaudeHookServer] stop called",
            level: .debug,
            fields: [
                "wasRunning": String(isRunning),
                "port": String(describing: activePort)
            ]
        )
        server?.stop()
        server = nil
        isRunning = false
        activePort = nil
        configuredToken = nil
        statusDescription = "未启动"
    }

    private func startIfNeeded(port: Int, token: String?) {
        log(
            "[ClaudeHookServer] startIfNeeded called",
            level: .debug,
            fields: [
                "requestedPort": String(port),
                "isRunning": String(isRunning),
                "currentPort": String(describing: activePort),
                "tokenChanged": String(configuredToken != token)
            ]
        )
        if isRunning, activePort == port, configuredToken == token {
            log(
                "[ClaudeHookServer] startIfNeeded: already running with same config",
                level: .debug
            )
            return
        }
        stop()

        guard port >= 1024, port <= 65535 else {
            log(
                "[ClaudeHookServer] startIfNeeded: invalid port",
                level: .debug,
                fields: ["port": String(port)]
            )
            isRunning = false
            statusDescription = "端口无效"
            lastErrorMessage = "Invalid port: \(port)"
            return
        }

        let webServer = GCDWebServer()

        webServer.addHandler(
            forMethod: "POST",
            path: ClaudeHookPreferences.endpointPath,
            request: GCDWebServerDataRequest.self,
            asyncProcessBlock: { [weak self] request, completionBlock in
                Task { @MainActor in
                    guard let self else {
                        let body = Data("{\"ok\":false,\"code\":\"server_error\"}".utf8)
                        let r = GCDWebServerDataResponse(data: body, contentType: "application/json")
                        r.statusCode = 500
                        completionBlock(r)
                        return
                    }

                    guard let dataRequest = request as? GCDWebServerDataRequest else {
                        completionBlock(
                            self.makeJSONResponse(
                                statusCode: 400,
                                response: ClaudeHookResponse(
                                    ok: false, code: "bad_request",
                                    message: "Invalid request body",
                                    sessionID: nil, handled: false
                                )
                            )
                        )
                        return
                    }

                    let result = self.handleHookRequest(
                        body: dataRequest.data,
                        query: request.query ?? [:],
                        headers: request.headers
                    )
                    completionBlock(
                        self.makeJSONResponse(statusCode: result.statusCode, response: result.response)
                    )
                }
            }
        )

        do {
            try webServer.start(options: [
                GCDWebServerOption_Port: UInt(port),
                GCDWebServerOption_BindToLocalhost: true
            ])
            self.server = webServer
            self.activePort = port
            self.configuredToken = token
            self.isRunning = true
            self.statusDescription = "监听中 127.0.0.1:\(port)"
            self.lastErrorMessage = nil
            log("[ClaudeHookServer] listening on 127.0.0.1:\(port)")
            NotificationCenter.default.post(name: .hookServerStateChanged, object: nil)
        } catch {
            isRunning = false
            statusDescription = "启动失败"
            lastErrorMessage = error.localizedDescription
            log("[ClaudeHookServer] failed to start: \(error.localizedDescription)")
        }
    }

    // MARK: - Request Handling

    private func handleHookRequest(
        body: Data,
        query: [String: String],
        headers: [String: String]
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        let bodyString = String(data: body, encoding: .utf8) ?? "non-utf8"
        updateCrashSnapshotFromRuntime()
        logRuntimeStateSnapshot(context: "hook_request")
        log(
            "[ClaudeHookServer] request received",
            level: .debug,
            fields: [
                "bodySize": String(body.count),
                "contentType": headerValue(from: headers, forKey: "Content-Type") ?? "nil",
                "body": truncateForLog(bodyString, limit: 500)
            ]
        )

        log(
            "[ClaudeHookServer] checking token authentication",
            level: .debug,
            fields: [
                "hasConfiguredToken": String(configuredToken != nil && !configuredToken!.isEmpty)
            ]
        )

        if let expectedToken = configuredToken, !expectedToken.isEmpty {
            let queryToken = query["token"]
            let headerToken = headerValue(from: headers, forKey: "X-VibeFocus-Token")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let providedToken = queryToken ?? headerToken
            log(
                "[ClaudeHookServer] token validation",
                level: .debug,
                fields: [
                    "hasQueryToken": String(queryToken != nil),
                    "hasHeaderToken": String(!headerToken.isEmpty)
                ]
            )
            guard providedToken == expectedToken else {
                log(
                    "[ClaudeHookServer] token validation failed",
                    level: .warn,
                    fields: [
                        "hasQueryToken": String(queryToken != nil),
                        "hasHeaderToken": String(!headerToken.isEmpty),
                        "tokenPrefix": String(providedToken.prefix(8)) + "..."
                    ]
                )
                return (
                    401,
                    ClaudeHookResponse(
                        ok: false, code: "unauthorized",
                        message: "Missing or invalid hook token",
                        sessionID: nil, handled: false
                    )
                )
            }
        }

        totalRequestCount += 1

        log(
            "[ClaudeHookServer] token OK, decoding JSON payload",
            level: .debug,
            fields: ["bodySize": String(body.count)]
        )

        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(ClaudeHookPayload.self, from: body) else {
            log(
                "[ClaudeHookServer] payload decode failed",
                level: .debug,
                fields: ["body": truncateForLog(bodyString, limit: 200)]
            )
            return (
                400,
                ClaudeHookResponse(
                    ok: false, code: "invalid_payload",
                    message: "JSON payload must contain event and session_id",
                    sessionID: nil, handled: false
                )
            )
        }

        lastEventAt = Date()
        log(
            "[ClaudeHookServer] routing event",
            level: .debug,
            fields: [
                "event": payload.event.rawValue,
                "sessionID": payload.sessionID,
                "cwd": payload.cwd ?? "nil"
            ]
        )
        log(
            "[ClaudeHookServer] entering event switch",
            level: .debug,
            fields: [
                "event": payload.event.rawValue,
                "sessionID": payload.sessionID
            ]
        )
        switch payload.event {
        case .sessionStart:
            log(
                "[ClaudeHookServer] routing to handleSessionStart",
                level: .debug,
                fields: ["sessionID": payload.sessionID]
            )
            return handleSessionStart(payload: payload)
        case .stop:
            log(
                "[ClaudeHookServer] routing to handleStop",
                level: .debug,
                fields: ["sessionID": payload.sessionID]
            )
            return handleStop(payload: payload)
        case .sessionEnd:
            log(
                "[ClaudeHookServer] routing to handleWindowMoveTrigger (SessionEnd)",
                level: .debug,
                fields: ["sessionID": payload.sessionID]
            )
            return handleWindowMoveTrigger(payload: payload, triggerName: "SessionEnd")
        case .userPromptSubmit:
            log(
                "[ClaudeHookServer] routing to handleUserPromptSubmit",
                level: .debug,
                fields: ["sessionID": payload.sessionID]
            )
            return handleUserPromptSubmit(payload: payload)
        }
    }

    private func handleSessionStart(
        payload: ClaudeHookPayload
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        log(
            "[handleSessionStart] called",
            level: .debug,
            fields: [
                "sessionID": payload.sessionID,
                "cwd": payload.cwd ?? "nil",
                "hasTerminalCtx": String(payload.terminalCtx != nil),
                "terminalCtxUseful": String(payload.terminalCtx?.hasUsefulContext ?? false)
            ]
        )

        // 唯一绑定路径：通过 terminal context (TTY/PPID 进程树) 精确匹配
        guard let terminalCtx = payload.terminalCtx, terminalCtx.hasUsefulContext else {
            log(
                "[handleSessionStart] no terminal context, cannot bind",
                level: .warn,
                fields: ["sessionID": payload.sessionID]
            )
            SessionWindowRegistry.shared.setLastEventDescription("SessionStart 失败：无终端上下文")
            return (
                409,
                ClaudeHookResponse(
                    ok: false, code: "no_terminal_context",
                    message: "No terminal context available for precise binding",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        guard let identity = WindowManager.shared.findWindowByTerminalContext(terminalCtx) else {
            log(
                "[handleSessionStart] terminal context match failed",
                level: .warn,
                fields: [
                    "sessionID": payload.sessionID,
                    "tty": terminalCtx.tty ?? "nil",
                    "ppid": terminalCtx.ppid ?? "nil"
                ]
            )
            SessionWindowRegistry.shared.setLastEventDescription("SessionStart 失败：终端上下文无法匹配窗口")
            return (
                409,
                ClaudeHookResponse(
                    ok: false, code: "terminal_context_match_failed",
                    message: "Terminal context could not be resolved to a window",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        log(
            "[ClaudeHookServer] SessionStart matched via terminal context",
            fields: [
                "sessionID": payload.sessionID,
                "app": identity.appName ?? "unknown",
                "title": identity.title ?? "untitled",
                "windowID": String(identity.windowID)
            ]
        )
        SessionWindowRegistry.shared.bind(
            sessionID: payload.sessionID,
            windowIdentity: identity,
            terminalTTY: payload.terminalCtx?.tty,
            terminalSessionID: payload.terminalCtx?.termSessionID ?? payload.terminalCtx?.itermSessionID
        )
        handledRequestCount += 1
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "session_bound",
                message: "Session bound to terminal window via TTY/PPID",
                sessionID: payload.sessionID, handled: true
            )
        )
    }

    private func handleUserPromptSubmit(
        payload: ClaudeHookPayload
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        lastActivityBySession[payload.sessionID] = Date()

        log(
            "[ClaudeHookServer] UserPromptSubmit triggered",
            fields: [
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
            handledRequestCount += 1
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "auto_restore_disabled",
                    message: "UserPromptSubmit received, auto restore disabled",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 严格检查：必须有 binding 且 binding 必须通过验证
        guard let binding = SessionWindowRegistry.shared.binding(for: payload.sessionID) else {
            log(
                "[ClaudeHookServer] UserPromptSubmit no binding found, skipping",
                level: .warn,
                fields: [
                    "sessionID": payload.sessionID,
                    "savedStatesCount": String(WindowManager.shared.savedWindowStates.count)
                ]
            )
            handledRequestCount += 1
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "no_binding_skip",
                    message: "No session binding, skipping restore",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 验证 binding：确认窗口 PID + windowID 仍然有效
        guard SessionWindowRegistry.shared.verifyBinding(binding) else {
            log(
                "[ClaudeHookServer] UserPromptSubmit binding verification failed, skipping",
                level: .warn,
                fields: [
                    "sessionID": payload.sessionID,
                    "windowID": String(binding.windowIdentity.windowID),
                    "pid": String(binding.windowIdentity.pid)
                ]
            )
            handledRequestCount += 1
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "binding_verification_failed",
                    message: "Binding verification failed, skipping restore",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        let targetWindowID = binding.windowIdentity.windowID
        let targetPID = binding.windowIdentity.pid
        let wm = WindowManager.shared

        log(
            "[ClaudeHookServer] UserPromptSubmit searching saved state (session-scoped)",
            fields: [
                "sessionID": payload.sessionID,
                "bindingWindowID": String(targetWindowID),
                "bindingPID": String(targetPID),
                "savedStatesCount": String(wm.savedWindowStates.count)
            ]
        )

        // 优先级 1: windowID + pid 精确匹配（限当前会话）
        if let matchedState = wm.savedWindowStates.reversed().first(where: { state in
            state.windowID == targetWindowID
                && state.pid == targetPID
                && state.sessionID == payload.sessionID
                && !wm.isSavedStateCorrupted(state)
        }) {
            return performRestore(
                payload: payload, matchedState: matchedState,
                matchLevel: "exact_binding_match_session_scoped"
            )
        }

        // 优先级 2: 仅 windowID 匹配（限当前会话）
        if let matchedState = wm.savedWindowStates.reversed().first(where: { state in
            state.windowID == targetWindowID
                && state.sessionID == payload.sessionID
                && !wm.isSavedStateCorrupted(state)
        }) {
            log(
                "[ClaudeHookServer] UserPromptSubmit session-scoped windowID fallback",
                fields: [
                    "sessionID": payload.sessionID,
                    "stateWindowID": String(matchedState.windowID ?? 0),
                    "bindingPID": String(targetPID)
                ]
            )
            return performRestore(
                payload: payload, matchedState: matchedState,
                matchLevel: "windowid_session_scoped"
            )
        }

        // 优先级 3: 窗口在主屏 + 同会话同 app 的 saved state
        let isOnMain = wm.isWindowOnMainScreen(windowID: targetWindowID)
        if isOnMain {
            if let appState = wm.savedWindowStates.reversed().first(where: { state in
                state.appName == binding.windowIdentity.appName
                    && state.sessionID == payload.sessionID
                    && !wm.isSavedStateCorrupted(state)
            }) {
                log(
                    "[ClaudeHookServer] UserPromptSubmit session-scoped app fallback",
                    fields: [
                        "sessionID": payload.sessionID,
                        "stateApp": appState.appName ?? "unknown",
                        "bindingWindowID": String(targetWindowID)
                    ]
                )
                return performRestore(
                    payload: payload, matchedState: appState,
                    matchLevel: "app_fallback_session_scoped"
                )
            }
        }

        // 无精确匹配的 saved state → 不做任何操作（不猜测窗口目标位置）
        log(
            "[ClaudeHookServer] UserPromptSubmit window not on main screen and no session-scoped saved state, skipping",
            fields: [
                "sessionID": payload.sessionID,
                "windowOnMainScreen": String(isOnMain)
            ]
        )
        handledRequestCount += 1
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "no_action_needed",
                message: "Window not on main screen and no session-scoped state to restore",
                sessionID: payload.sessionID, handled: false
            )
        )
    }

    private func performRestore(
        payload: ClaudeHookPayload,
        matchedState: WindowManager.SavedWindowState,
        matchLevel: String
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        WindowManager.shared.hydrateMemory(from: matchedState, window: nil)

        log(
            "[ClaudeHookServer] UserPromptSubmit restoring window",
            fields: [
                "sessionID": payload.sessionID,
                "matchLevel": matchLevel,
                "stateID": matchedState.id,
                "app": matchedState.appName ?? "unknown",
                "windowID": String(describing: matchedState.windowID),
                "originalFrame": String(describing: matchedState.originalFrame.cgRect),
                "targetFrame": String(describing: matchedState.targetFrame.cgRect)
            ]
        )

        WindowManager.shared.restore(
            operationID: makeOperationID(prefix: "hook-restore"),
            triggerSource: "user_prompt_submit"
        )

        SessionWindowRegistry.shared.reactivate(sessionID: payload.sessionID)

        handledRequestCount += 1
        SessionWindowRegistry.shared.setLastEventDescription(
            "UserPromptSubmit 恢复窗口（\(matchLevel)）：\(matchedState.appName ?? "Unknown")"
        )
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "window_restored",
                message: "Window restored to original position",
                sessionID: payload.sessionID, handled: true
            )
        )
    }

    private func handleStop(
        payload: ClaudeHookPayload
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        // 防抖：如果 session 最近有 UserPromptSubmit，Stop 是中间态不是真正结束
        if let lastActivity = lastActivityBySession[payload.sessionID] {
            let elapsed = Date().timeIntervalSince(lastActivity)
            if elapsed < stopDebounceInterval {
                log(
                    "[ClaudeHookServer] Stop debounced — session was active \(String(format: "%.1f", elapsed))s ago (threshold: \(String(format: "%.0f", stopDebounceInterval))s)",
                    fields: [
                        "sessionID": payload.sessionID,
                        "elapsedSinceActivity": String(format: "%.1f", elapsed),
                        "debounceThreshold": String(format: "%.0f", stopDebounceInterval)
                    ]
                )
                SessionWindowRegistry.shared.touch(
                    sessionID: payload.sessionID,
                    message: "Stop 收到（防抖中：会话仍活跃）"
                )
                handledRequestCount += 1
                return (
                    200,
                    ClaudeHookResponse(
                        ok: true, code: "stop_debounced",
                        message: "Stop debounced — session still active",
                        sessionID: payload.sessionID, handled: false
                    )
                )
            }
        }

        guard ClaudeHookPreferences.triggerOnStop else {
            SessionWindowRegistry.shared.touch(
                sessionID: payload.sessionID,
                message: "Stop 收到（Stop 触发已关闭）"
            )
            handledRequestCount += 1
            log(
                "[ClaudeHookServer] Stop received but trigger disabled",
                fields: ["sessionID": payload.sessionID]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "stop_trigger_disabled",
                    message: "Stop received, trigger disabled",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 防抖通过 + trigger 已启用 → 清理活动记录
        lastActivityBySession.removeValue(forKey: payload.sessionID)
        return handleWindowMoveTrigger(payload: payload, triggerName: "Stop")
    }

    /// Stop/SessionEnd 共用的窗口移动逻辑
    private func handleWindowMoveTrigger(
        payload: ClaudeHookPayload,
        triggerName: String
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        log(
            "[ClaudeHookServer] \(triggerName) triggered",
            fields: [
                "sessionID": payload.sessionID,
                "autoFocusEnabled": String(ClaudeHookPreferences.autoFocusOnSessionEnd),
                "cwd": payload.cwd ?? "nil"
            ]
        )

        guard ClaudeHookPreferences.autoFocusOnSessionEnd else {
            SessionWindowRegistry.shared.touch(
                sessionID: payload.sessionID,
                message: "\(triggerName) 收到（自动聚焦已关闭）"
            )
            handledRequestCount += 1
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "auto_focus_disabled",
                    message: "\(triggerName) received, auto focus disabled",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 严格检查：必须有 binding 且通过验证
        guard let binding = SessionWindowRegistry.shared.binding(for: payload.sessionID) else {
            unmatchedSessionCount += 1
            log(
                "[ClaudeHookServer] \(triggerName) no binding found, skipping",
                level: .warn,
                fields: ["sessionID": payload.sessionID]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "no_binding_skip",
                    message: "No session binding, skipping window move",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        guard SessionWindowRegistry.shared.verifyBinding(binding) else {
            log(
                "[ClaudeHookServer] \(triggerName) binding verification failed, skipping",
                level: .warn,
                fields: [
                    "sessionID": payload.sessionID,
                    "windowID": String(binding.windowIdentity.windowID),
                    "pid": String(binding.windowIdentity.pid)
                ]
            )
            handledRequestCount += 1
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "binding_verification_failed",
                    message: "Binding verification failed, skipping window move",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        return moveBindingToMainScreen(binding: binding, payload: payload, triggerName: triggerName)
    }

    // MARK: - Response Helpers

    private static let terminalAppNames: Set<String> = [
        "Terminal", "iTerm2", "Warp", "Ghostty", "Alacritty", "kitty",
        "Cursor", "Code", "Visual Studio Code",
        "com.apple.Terminal", "com.googlecode.iterm2",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"
    ]

    static func isTerminalOrIDEApp(appName: String?, bundleIdentifier: String?) -> Bool {
        if let appName, terminalAppNames.contains(appName) { return true }
        if let bundleIdentifier, terminalAppNames.contains(bundleIdentifier) { return true }
        return false
    }

    /// 执行窗口移动：将绑定窗口移到主屏幕并最大化
    private func moveBindingToMainScreen(
        binding: SessionWindowBinding,
        payload: ClaudeHookPayload,
        triggerName: String
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        if binding.isCompleted {
            handledRequestCount += 1
            log(
                "[ClaudeHookServer] \(triggerName) already completed",
                fields: ["sessionID": payload.sessionID]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "already_completed",
                    message: "Session already completed",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 预检：如果窗口已在主屏幕上，跳过移动
        // 防止对已在主屏的窗口执行无意义移动，避免保存错误状态
        if WindowManager.shared.isWindowOnMainScreen(windowID: binding.windowIdentity.windowID) {
            handledRequestCount += 1
            SessionWindowRegistry.shared.setLastEventDescription(
                "\(triggerName) 窗口已在主屏幕，跳过移动"
            )
            log(
                "[ClaudeHookServer] \(triggerName) window already on main screen, skipping move",
                fields: [
                    "sessionID": payload.sessionID,
                    "windowID": String(binding.windowIdentity.windowID),
                    "app": binding.windowIdentity.appName ?? "unknown"
                ]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "already_on_main_screen",
                    message: "Window already on main screen, no action needed",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 安全检查：确保绑定的是终端/IDE 窗口
        // SessionStart 可能绑定到非终端窗口（Chrome、飞书等），这类窗口不应被自动移动
        let terminalAppNames: Set<String> = [
            "Terminal", "iTerm2", "Warp", "Ghostty", "Alacritty", "kitty",
            "Cursor", "Code", "Visual Studio Code",
            "com.apple.Terminal", "com.googlecode.iterm2",
            "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"
        ]
        let isTerminalBinding: Bool = {
            if let appName = binding.windowIdentity.appName, terminalAppNames.contains(appName) {
                return true
            }
            if let bundleID = binding.windowIdentity.bundleIdentifier, terminalAppNames.contains(bundleID) {
                return true
            }
            return false
        }()

        if !isTerminalBinding {
            handledRequestCount += 1
            SessionWindowRegistry.shared.setLastEventDescription(
                "\(triggerName) 绑定窗口非终端应用：\(binding.windowIdentity.appName ?? "Unknown")"
            )
            log(
                "[ClaudeHookServer] \(triggerName) bound window is non-terminal app, skipping",
                level: .warn,
                fields: [
                    "sessionID": payload.sessionID,
                    "app": binding.windowIdentity.appName ?? "unknown",
                    "bundleID": binding.windowIdentity.bundleIdentifier ?? "nil",
                    "windowID": String(binding.windowIdentity.windowID)
                ]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "non_terminal_binding",
                    message: "Bound window is not a terminal/IDE app, skipping",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        log(
            "[ClaudeHookServer] \(triggerName) moving window",
            fields: [
                "sessionID": payload.sessionID,
                "app": binding.windowIdentity.appName ?? "unknown",
                "title": binding.windowIdentity.title ?? "untitled",
                "windowID": String(binding.windowIdentity.windowID),
                "pid": String(binding.windowIdentity.pid)
            ]
        )

        let moved = WindowManager.shared.moveWindowToMainScreen(
            identity: binding.windowIdentity,
            reason: .claudeSessionEnd,
            sessionID: payload.sessionID
        )
        if moved {
            SessionWindowRegistry.shared.markCompleted(sessionID: payload.sessionID)
            handledRequestCount += 1
            log(
                "[ClaudeHookServer] \(triggerName) window moved successfully",
                fields: [
                    "sessionID": payload.sessionID,
                    "app": binding.windowIdentity.appName ?? "unknown",
                    "title": binding.windowIdentity.title ?? "untitled"
                ]
            )
            Task { @MainActor in
                SoundManager.shared.playCompletionSound()
            }
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "window_focused",
                    message: "Window moved to main screen and maximized",
                    sessionID: payload.sessionID, handled: true
                )
            )
        }

        SessionWindowRegistry.shared.touch(
            sessionID: payload.sessionID,
            message: "\(triggerName) 命中绑定，但移动窗口失败"
        )
        log(
            "[ClaudeHookServer] \(triggerName) window move failed",
            level: .error,
            fields: [
                "sessionID": payload.sessionID,
                "app": binding.windowIdentity.appName ?? "unknown",
                "windowID": String(binding.windowIdentity.windowID)
            ]
        )
        return (
            409,
            ClaudeHookResponse(
                ok: false, code: "window_move_failed",
                message: "Found session binding but failed to move window",
                sessionID: payload.sessionID, handled: false
            )
        )
    }

    /// Case-insensitive header lookup — GCDWebServer preserves original HTTP header casing
    private func headerValue(from headers: [String: String], forKey key: String) -> String? {
        if let value = headers[key] { return value }
        let lowerKey = key.lowercased()
        for (k, v) in headers where k.lowercased() == lowerKey {
            return v
        }
        return nil
    }

    private func makeJSONResponse(statusCode: Int, response: ClaudeHookResponse) -> GCDWebServerDataResponse {
        log(
            "[ClaudeHookServer] makeJSONResponse",
            level: .debug,
            fields: [
                "statusCode": String(statusCode),
                "code": response.code,
                "ok": String(response.ok),
                "sessionID": response.sessionID ?? "nil",
                "handled": String(response.handled)
            ]
        )
        let encoder = JSONEncoder()
        let bodyData = (try? encoder.encode(response)) ?? Data("{\"ok\":false}".utf8)
        let httpResponse = GCDWebServerDataResponse(data: bodyData, contentType: "application/json")
        httpResponse.statusCode = statusCode
        return httpResponse
    }
}
