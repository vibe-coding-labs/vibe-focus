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
        let bodyString = String(data: body, encoding: .utf8) ?? "non-utf8"
        updateCrashSnapshotFromRuntime()
        logRuntimeStateSnapshot(context: "hook_request")

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

        return result
    }

    // MARK: - Response Helpers

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
