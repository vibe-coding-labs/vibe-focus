import Foundation
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

    private init() {}

    func applyPreferences() {
        if ClaudeHookPreferences.isEnabled {
            startIfNeeded(port: ClaudeHookPreferences.listenPort, token: ClaudeHookPreferences.authToken)
        } else {
            stop()
        }
    }

    func stop() {
        server?.stop()
        server = nil
        isRunning = false
        activePort = nil
        configuredToken = nil
        statusDescription = "未启动"
    }

    private func startIfNeeded(port: Int, token: String?) {
        if isRunning, activePort == port, configuredToken == token {
            return
        }
        stop()

        guard port >= 1024, port <= 65535 else {
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
        log(
            "[ClaudeHookServer] request received",
            fields: [
                "bodySize": String(body.count),
                "contentType": headerValue(from: headers, forKey: "Content-Type") ?? "nil"
            ]
        )

        if let expectedToken = configuredToken, !expectedToken.isEmpty {
            let queryToken = query["token"]
            let headerToken = headerValue(from: headers, forKey: "X-VibeFocus-Token")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let providedToken = queryToken ?? headerToken
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

        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(ClaudeHookPayload.self, from: body) else {
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
        switch payload.event {
        case .sessionStart:
            return handleSessionStart(payload: payload)
        case .stop:
            return handleStop(payload: payload)
        case .sessionEnd:
            return handleWindowMoveTrigger(payload: payload, triggerName: "SessionEnd")
        case .userPromptSubmit:
            return handleUserPromptSubmit(payload: payload)
        }
    }

    private func handleSessionStart(
        payload: ClaudeHookPayload
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        guard let identity = WindowManager.shared.captureFocusedWindowIdentity() else {
            SessionWindowRegistry.shared.setLastEventDescription("SessionStart 失败：当前无可绑定窗口")
            return (
                409,
                ClaudeHookResponse(
                    ok: false, code: "window_not_found",
                    message: "No focused window available for session binding",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }
        SessionWindowRegistry.shared.bind(sessionID: payload.sessionID, windowIdentity: identity)
        handledRequestCount += 1
        log(
            "[ClaudeHookServer] SessionStart bound",
            fields: [
                "sessionID": payload.sessionID,
                "app": identity.appName ?? "unknown",
                "title": identity.title ?? "untitled",
                "windowID": String(identity.windowID),
                "cwd": payload.cwd ?? "nil",
                "model": payload.model ?? "nil"
            ]
        )
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "session_bound",
                message: "Session bound to focused window",
                sessionID: payload.sessionID, handled: true
            )
        )
    }

    private func handleUserPromptSubmit(
        payload: ClaudeHookPayload
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
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

        // 优先级 1: 按 sessionID 查找对应的 saved state
        let matchedState = WindowManager.shared.savedWindowStates.reversed().first { state in
            state.sessionID == payload.sessionID && !WindowManager.shared.isSavedStateCorrupted(state)
        }

        if let savedState = matchedState {
            // 从 saved state 恢复到内存
            WindowManager.shared.hydrateMemory(from: savedState, window: nil)

            log(
                "[ClaudeHookServer] UserPromptSubmit restoring window",
                fields: [
                    "sessionID": payload.sessionID,
                    "stateID": savedState.id,
                    "app": savedState.appName ?? "unknown",
                    "windowID": String(describing: savedState.windowID),
                    "originalFrame": String(describing: savedState.originalFrame.cgRect)
                ]
            )

            // 执行恢复
            WindowManager.shared.restore(
                operationID: makeOperationID(prefix: "hook-restore"),
                triggerSource: "user_prompt_submit"
            )

            // 重新激活绑定，使下一个 Stop 事件能再次触发窗口移动
            SessionWindowRegistry.shared.reactivate(sessionID: payload.sessionID)

            handledRequestCount += 1
            SessionWindowRegistry.shared.setLastEventDescription(
                "UserPromptSubmit 恢复窗口：\(savedState.appName ?? "Unknown")"
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

        // 优先级 2: sessionID 无匹配时，回退到 shouldRestoreCurrentWindow 逻辑
        // 复用 hotkey 路径的匹配机制（windowID / PID+title+position）
        log(
            "[ClaudeHookServer] UserPromptSubmit no sessionID match, trying shouldRestoreCurrentWindow fallback",
            level: .info,
            fields: [
                "sessionID": payload.sessionID,
                "savedStatesCount": String(WindowManager.shared.savedWindowStates.count)
            ]
        )

        if WindowManager.shared.shouldRestoreCurrentWindow() {
            log(
                "[ClaudeHookServer] UserPromptSubmit fallback: shouldRestoreCurrentWindow matched",
                fields: [
                    "sessionID": payload.sessionID
                ]
            )

            WindowManager.shared.restore(
                operationID: makeOperationID(prefix: "hook-restore-fallback"),
                triggerSource: "user_prompt_submit_fallback"
            )

            SessionWindowRegistry.shared.reactivate(sessionID: payload.sessionID)

            handledRequestCount += 1
            SessionWindowRegistry.shared.setLastEventDescription(
                "UserPromptSubmit 回退恢复窗口"
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "window_restored_fallback",
                    message: "Window restored via fallback matching",
                    sessionID: payload.sessionID, handled: true
                )
            )
        }

        // 无匹配
        log(
            "[ClaudeHookServer] UserPromptSubmit no matching saved state",
            level: .warn,
            fields: [
                "sessionID": payload.sessionID,
                "savedStatesCount": String(WindowManager.shared.savedWindowStates.count)
            ]
        )
        return (
            404,
            ClaudeHookResponse(
                ok: false, code: "no_saved_state",
                message: "No saved window state found for session",
                sessionID: payload.sessionID, handled: false
            )
        )
    }

    private func handleStop(
        payload: ClaudeHookPayload
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
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

        // 尝试从 SessionStart 绑定中找窗口
        // 如果找不到（SessionStart HTTP hook 是 Claude Code 已知 bug，可能不触发），
        // 尝试通过终端上下文精确定位，最后回退到 cwd 匹配
        let binding: SessionWindowBinding
        if let existingBinding = SessionWindowRegistry.shared.binding(for: payload.sessionID) {
            binding = existingBinding
        } else if let terminalCtx = payload.terminalCtx, terminalCtx.hasUsefulContext {
            // 新路径：通过 hook 辅助脚本捕获的终端上下文（TTY/PPID）精确定位窗口
            log(
                "[ClaudeHookServer] \(triggerName) no binding, trying terminal context",
                fields: [
                    "sessionID": payload.sessionID,
                    "tty": terminalCtx.tty ?? "nil",
                    "ppid": terminalCtx.ppid ?? "nil",
                    "termSessionID": terminalCtx.termSessionID ?? "nil"
                ]
            )
            guard let ctxIdentity = WindowManager.shared.findWindowByTerminalContext(terminalCtx) else {
                unmatchedSessionCount += 1
                SessionWindowRegistry.shared.setLastEventDescription(
                    "\(triggerName) 终端上下文匹配失败：\(payload.sessionID)"
                )
                log(
                    "[ClaudeHookServer] \(triggerName) terminal context match failed",
                    level: .warn,
                    fields: ["sessionID": payload.sessionID]
                )
                // 回退到 cwd 匹配
                return fallbackToCWDMatching(payload: payload, triggerName: triggerName)
            }

            log(
                "[ClaudeHookServer] \(triggerName) matched via terminal context",
                fields: [
                    "sessionID": payload.sessionID,
                    "app": ctxIdentity.appName ?? "unknown",
                    "title": ctxIdentity.title ?? "untitled",
                    "windowID": String(ctxIdentity.windowID)
                ]
            )

            let now = Date()
            binding = SessionWindowBinding(
                sessionID: payload.sessionID,
                windowIdentity: ctxIdentity,
                createdAt: now,
                lastSeenAt: now,
                isCompleted: false,
                completedAt: nil
            )
        } else {
            // 回退：通过 cwd 项目名匹配窗口（旧路径，保留兼容）
            return fallbackToCWDMatching(payload: payload, triggerName: triggerName)
        }

        // 有 binding（来自 SessionStart 绑定或终端上下文匹配），执行窗口移动
        return moveBindingToMainScreen(binding: binding, payload: payload, triggerName: triggerName)
    }

    // MARK: - Response Helpers

    /// cwd 匹配回退：当没有 SessionStart 绑定也没有终端上下文时，通过 cwd 项目名匹配窗口
    private func fallbackToCWDMatching(
        payload: ClaudeHookPayload,
        triggerName: String
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        log(
            "[ClaudeHookServer] \(triggerName) no binding found, falling back to cwd matching",
            fields: [
                "sessionID": payload.sessionID,
                "cwd": payload.cwd ?? "nil"
            ]
        )
        guard let focusedIdentity = WindowManager.shared.findClaudeCodeWindow(cwd: payload.cwd) else {
            unmatchedSessionCount += 1
            SessionWindowRegistry.shared.setLastEventDescription(
                "\(triggerName) 未命中绑定且无前台窗口：\(payload.sessionID)"
            )
            log(
                "[ClaudeHookServer] \(triggerName) no binding and no focused window",
                level: .warn,
                fields: ["sessionID": payload.sessionID]
            )
            return (
                404,
                ClaudeHookResponse(
                    ok: false, code: "binding_not_found",
                    message: "No bound window for session and no focused window available",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 安全检查：findClaudeCodeWindow 的 Strategy 4（焦点窗口回退）
        // 可能返回非终端/IDE 窗口（Chrome、飞书等），这类窗口不应被自动移动
        let terminalAppNames: Set<String> = [
            "Terminal", "iTerm2", "Warp", "Ghostty", "Alacritty", "kitty",
            "Cursor", "Code", "Visual Studio Code",
            "com.apple.Terminal", "com.googlecode.iterm2",
            "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"
        ]
        let isTerminalApp: Bool = {
            if let appName = focusedIdentity.appName, terminalAppNames.contains(appName) {
                return true
            }
            if let bundleID = focusedIdentity.bundleIdentifier, terminalAppNames.contains(bundleID) {
                return true
            }
            return false
        }()

        // 如果 cwd 匹配到了非终端窗口（如 Chrome），检查窗口标题是否包含 cwd 项目名
        // 只有标题明确包含项目名时才认为是 Claude Code 相关窗口
        if !isTerminalApp {
            let projectName = payload.cwd?
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .components(separatedBy: "/")
                .last?
                .lowercased()
            let titleContainsProject = projectName.map { p in
                (focusedIdentity.title ?? "").lowercased().contains(p)
            } ?? false

            if !titleContainsProject {
                unmatchedSessionCount += 1
                log(
                    "[ClaudeHookServer] \(triggerName) cwd fallback matched non-terminal app without project name in title, skipping",
                    level: .warn,
                    fields: [
                        "sessionID": payload.sessionID,
                        "app": focusedIdentity.appName ?? "unknown",
                        "title": focusedIdentity.title ?? "untitled",
                        "windowID": String(focusedIdentity.windowID)
                    ]
                )
                return (
                    404,
                    ClaudeHookResponse(
                        ok: false, code: "non_terminal_window",
                        message: "Matched non-terminal window without project name correlation",
                        sessionID: payload.sessionID, handled: false
                    )
                )
            }
        }

        log(
            "[ClaudeHookServer] \(triggerName) using cwd fallback",
            fields: [
                "sessionID": payload.sessionID,
                "app": focusedIdentity.appName ?? "unknown",
                "title": focusedIdentity.title ?? "untitled",
                "windowID": String(focusedIdentity.windowID),
                "isTerminalApp": String(isTerminalApp)
            ]
        )

        let now = Date()
        let binding = SessionWindowBinding(
            sessionID: payload.sessionID,
            windowIdentity: focusedIdentity,
            createdAt: now,
            lastSeenAt: now,
            isCompleted: false,
            completedAt: nil
        )

        return moveBindingToMainScreen(binding: binding, payload: payload, triggerName: triggerName)
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
        let encoder = JSONEncoder()
        let bodyData = (try? encoder.encode(response)) ?? Data("{\"ok\":false}".utf8)
        let httpResponse = GCDWebServerDataResponse(data: bodyData, contentType: "application/json")
        httpResponse.statusCode = statusCode
        return httpResponse
    }
}
