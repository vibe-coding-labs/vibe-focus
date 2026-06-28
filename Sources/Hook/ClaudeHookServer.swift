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

    private init() {}

    func applyPreferences() {
        // P-INST-77: hook 配置同步总耗时（启动 AppDelegate:71 + hook 偏好变更时；含 writeConfigFile + installHelperScript + installHookToClaudeSettings 三文件 I/O + server start；@MainActor 同步阻塞 UI；memory feedback_hook_toggle_sync 铁律要求 hook toggle 同步 settings.json）。
        let startedAt = Date()
        if ClaudeHookPreferences.isEnabled {
            ClaudeHookPreferences.ensureTokenGenerated()
            startIfNeeded(port: ClaudeHookPreferences.listenPort, token: ClaudeHookPreferences.authToken)
            // 确保辅助脚本的配置文件（端口 + token）与当前 UserDefaults 同步
            // 防止 app 重启后 token 重新生成导致 hook-config.json 中的旧 token 失效
            ClaudeHookPreferences.writeConfigFile()
            ClaudeHookPreferences.installHelperScript()
            ClaudeHookPreferences.installHookToClaudeSettings()
        } else {
            stop()
        }
        logOperationDuration("[ClaudeHookServer] applyPreferences finished", startedAt: startedAt, warnThresholdMs: 200)
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
            let bindToLocalhost = !LANHookPreferences.lanMode
            try webServer.start(options: [
                GCDWebServerOption_Port: UInt(port),
                GCDWebServerOption_BindToLocalhost: bindToLocalhost
            ])
            self.server = webServer
            self.activePort = port
            self.configuredToken = token
            self.isRunning = true
            let bindAddr = bindToLocalhost ? "127.0.0.1" : "0.0.0.0"
            self.statusDescription = "监听中 \(bindAddr):\(port)"
            self.lastErrorMessage = nil
            log("[ClaudeHookServer] listening on \(bindAddr):\(port)")
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
        // P-INST-71: hook 请求端到端总耗时（token 验证 + JSON decode + eventHandler 处理 + 响应构造；hook 路径顶层归因，配合子阶段 P-INST-38/47/54/55/56）。
        let hhrStart = Date()
        let bodyString = String(data: body, encoding: .utf8) ?? "non-utf8"
        updateCrashSnapshotFromRuntime()
        logRuntimeStateSnapshot(context: "hook_request")

        if let expectedToken = configuredToken, !expectedToken.isEmpty {
            let queryToken = query["token"]
            let headerToken = Self.resolveHeaderValue(from: headers, forKey: "X-VibeFocus-Token")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
            log(
                "[ClaudeHookServer] payload decode failed",
                level: .warn,
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

        let sourceIP = Self.resolveHeaderValue(from: headers, forKey: "X-Forwarded-For")
            ?? Self.resolveHeaderValue(from: headers, forKey: "X-Real-IP")
            ?? "local"
        let isRemote = sourceIP != "local"
        log(
            "[ClaudeHookServer] request received",
            fields: [
                "event": payload.event.rawValue,
                "sessionID": payload.sessionID,
                "source": isRemote ? "remote(\(sourceIP))" : "local",
                "isRemote": String(isRemote),
                "hasTerminalCtx": String(payload.terminalCtx != nil),
                "machineLabel": payload.terminalCtx?.machineLabel ?? "nil"
            ]
        )

        let eventHandler = HookEventHandler.shared
        var result: (statusCode: Int, response: ClaudeHookResponse)

        switch payload.event {
        case .sessionStart:
            result = eventHandler.handleSessionStart(payload: payload)
        case .stop:
            result = eventHandler.handleStop(payload: payload)
        case .sessionEnd:
            result = eventHandler.handleWindowMoveTrigger(payload: payload, triggerName: "SessionEnd")
        case .userPromptSubmit:
            result = eventHandler.handleUserPromptSubmit(payload: payload)
        }

        // Track handled requests based on the response
        if result.response.handled {
            handledRequestCount += 1
        }
        // Track unmatched sessions for window move triggers
        if result.response.code == "no_binding_skip" {
            unmatchedSessionCount += 1
        }

        log(
            "[ClaudeHookServer] response sent",
            fields: [
                "event": payload.event.rawValue,
                "sessionID": payload.sessionID,
                "code": result.response.code,
                "handled": String(result.response.handled),
                "statusCode": String(result.statusCode),
                "durationMs": String(elapsedMilliseconds(since: hhrStart))
            ]
        )

        return result
    }

    // MARK: - Response Helpers

    /// Case-insensitive header lookup — GCDWebServer preserves original HTTP header casing
    static func resolveHeaderValue(from headers: [String: String], forKey key: String) -> String? {
        if let value = headers[key] { return value }
        let lowerKey = key.lowercased()
        for (k, v) in headers where k.lowercased() == lowerKey {
            return v
        }
        return nil
    }

    /// Pure token validation — extracted for testability.
    /// Returns the effective token from query params or headers, or nil if no token needed.
    static func resolveProvidedToken(query: [String: String], headers: [String: String]) -> String? {
        let queryToken = query["token"]
        let headerToken = resolveHeaderValue(from: headers, forKey: "X-VibeFocus-Token")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return queryToken ?? headerToken
    }

    /// Pure token validation decision — extracted for testability.
    static func isTokenValid(expectedToken: String?, providedToken: String?) -> Bool {
        guard let expectedToken, !expectedToken.isEmpty else {
            return true // No token configured → skip validation
        }
        return providedToken == expectedToken
    }

    private func makeJSONResponse(statusCode: Int, response: ClaudeHookResponse) -> GCDWebServerDataResponse {
        // P-INST-213: hook 响应 JSON 编码耗时（JSONEncoder.encode + GCDWebServerDataResponse 构造；每个 hook 请求响应路径调用，encode 通常 <1ms 但归因 hook 响应延迟；slow-op ≥5ms warn）。
        let mjrStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: mjrStart)
            if durMs >= 5 { log("[HookServer] makeJSONResponse slow", level: .warn, fields: ["statusCode": String(statusCode), "durationMs": String(durMs)]) }
        }
        let encoder = JSONEncoder()
        let bodyData = (try? encoder.encode(response)) ?? Data("{\"ok\":false}".utf8)
        let httpResponse = GCDWebServerDataResponse(data: bodyData, contentType: "application/json")
        httpResponse.statusCode = statusCode
        return httpResponse
    }
}
