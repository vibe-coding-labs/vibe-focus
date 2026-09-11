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
    /// 当前监听实例的绑定模式（true=仅本机）。纳入重启判定：运行中翻转「局域网模式」
    /// 必须重绑定，否则开 LAN 无效、关 LAN 继续暴露 0.0.0.0（2026-09-10 模块审计实锤）。
    private var configuredBindToLocalhost: Bool?

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
            _ = ClaudeHookPreferences.installHookToClaudeSettings()
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
        configuredBindToLocalhost = nil
        statusDescription = "未启动"
    }

    /// 测试注入缝（B154）：HTTP 壳回环直测须显式起服。⚠️ 生产入口是 applyPreferences()；
    /// 测试严禁调用 applyPreferences——它会写真实 ~/.vibefocus 配置与 settings.json。
    func startIfNeeded(port: Int, token: String?) {
        let bindToLocalhost = !LANHookPreferences.lanMode
        if !Self.serverNeedsRestart(
            isRunning: isRunning,
            activePort: activePort,
            configuredToken: configuredToken,
            configuredBindToLocalhost: configuredBindToLocalhost,
            port: port,
            token: token,
            bindToLocalhost: bindToLocalhost
        ) {
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
                        headers: request.headers,
                        peerAddress: request.remoteAddressString as String?
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
                GCDWebServerOption_BindToLocalhost: bindToLocalhost
            ])
            self.server = webServer
            self.activePort = port
            self.configuredToken = token
            self.configuredBindToLocalhost = bindToLocalhost
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
        headers: [String: String],
        peerAddress: String? = nil
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        // P-INST-71: hook 请求端到端总耗时（token 验证 + JSON decode + eventHandler 处理 + 响应构造；hook 路径顶层归因，配合子阶段 P-INST-38/47/54/55/56）。
        let hhrStart = Date()
        let bodyString = String(data: body, encoding: .utf8) ?? "non-utf8"
        updateCrashSnapshotFromRuntime()
        logRuntimeStateSnapshot(context: "hook_request")

        // token 验证：provided 取值与判定走纯函数（2.16a 第十六刀影子接线——
        // 此前生产内联同一逻辑、纯函数零调用，两份语义漂移风险）。
        let providedToken = Self.resolveProvidedToken(query: query, headers: headers)
        if Self.tokenGateRejected(query: query, headers: headers, expectedToken: configuredToken) {
            let headerToken = Self.resolveHeaderValue(from: headers, forKey: "X-VibeFocus-Token")?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            log(
                "[ClaudeHookServer] token validation failed",
                level: .warn,
                fields: [
                    "hasQueryToken": String(query["token"] != nil),
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

        totalRequestCount += 1

        guard let payload = Self.decodePayload(from: body) else {
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

        // 来源分类（B89）：代理头优先（反代部署取真实客户端）→ TCP 对端地址
        // （loopback=本机，其它=远程直连）→ local。旧行为只看代理头——直连 LAN
        // 请求（本应用的主要远程场景）没有这些头，全被误记为 local。
        let proxyIP = Self.resolveHeaderValue(from: headers, forKey: "X-Forwarded-For")
            ?? Self.resolveHeaderValue(from: headers, forKey: "X-Real-IP")
        let sourceInfo = Self.classifyRequestSource(peerAddress: peerAddress, proxyIP: proxyIP)
        let sourceIP = sourceInfo.source
        let isRemote = sourceInfo.isRemote
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
            // 语音播报：与移窗逻辑解耦，无条件异步触发（不阻塞 hook 响应）。
            // 窗口已在主屏（handleStop 早返回）时语音仍触发，避免依赖 moved 标志。
            Task { @MainActor in
                VoiceAnnouncementManager.shared.announceCompletion(payload: payload)
            }
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

    /// 服务器是否需要（重）启动的纯判定：未运行，或端口/token/绑定模式任一配置变化。
    /// 绑定模式曾是判定盲区——服务运行中翻转「局域网模式」触发 applyPreferences 却
    /// 早退返回，开 LAN 不重绑定（远程机连不上）、关 LAN 不收回 0.0.0.0（继续暴露
    /// 局域网直到重启 app）。Runner 真身直测锁定。
    static func serverNeedsRestart(
        isRunning: Bool,
        activePort: Int?,
        configuredToken: String?,
        configuredBindToLocalhost: Bool?,
        port: Int,
        token: String?,
        bindToLocalhost: Bool
    ) -> Bool {
        guard isRunning else { return true }
        return activePort != port
            || configuredToken != token
            || configuredBindToLocalhost != bindToLocalhost
    }

    /// Case-insensitive header lookup — GCDWebServer preserves original HTTP header casing
    static func resolveHeaderValue(from headers: [String: String], forKey key: String) -> String? {
        if let value = headers[key] { return value }
        let lowerKey = key.lowercased()
        for (k, v) in headers where k.lowercased() == lowerKey {
            return v
        }
        return nil
    }

    /// loopback 判定（纯函数）：IPv4 127/8 前缀、IPv6 ::1、IPv4-mapped ::ffff:127.*。
    static func isLoopbackAddress(_ address: String) -> Bool {
        let lower = address.lowercased()
        return lower.hasPrefix("127.") || lower == "::1" || lower.hasPrefix("::ffff:127.") || lower == "::"
    }

    /// hook 请求来源分类（纯函数，B89）：代理头优先（反代部署取真实客户端）→
    /// TCP 对端地址（loopback=本机调用；其它=局域网/远程直连）→ 未知回退 local。
    /// 旧行为只认 X-Forwarded-For/X-Real-IP 代理头——直连 LAN 请求（本应用的主要
    /// 远程场景）不带这些头，日志里真实远程来源全被误记为 local。
    static func classifyRequestSource(peerAddress: String?, proxyIP: String?) -> (source: String, isRemote: Bool) {
        if let proxy = proxyIP, !proxy.isEmpty {
            return (proxy, !isLoopbackAddress(proxy))
        }
        guard let peer = peerAddress, !peer.isEmpty else {
            return ("local", false)
        }
        if isLoopbackAddress(peer) {
            return ("local", false)
        }
        return (peer, true)
    }

    /// Pure token validation — extracted for testability.
    /// Returns the effective token from query params or headers (empty string when absent — never nil).
    static func resolveProvidedToken(query: [String: String], headers: [String: String]) -> String {
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

    /// token 门判定（B141 提纯）：true = 拒绝（401）。
    /// 语义 = !(resolveProvidedToken → isTokenValid)，拒绝时未计数（totalRequestCount
    /// 只统计通过 token 门的请求——401 不计入总量，与历史口径一致）。
    static func tokenGateRejected(query: [String: String], headers: [String: String], expectedToken: String?) -> Bool {
        let provided = resolveProvidedToken(query: query, headers: headers)
        return !isTokenValid(expectedToken: expectedToken, providedToken: provided)
    }

    /// payload 解码门（B141 提纯）：非法/缺失 event+session_id → nil（调用方回 400）。
    static func decodePayload(from body: Data) -> ClaudeHookPayload? {
        try? JSONDecoder().decode(ClaudeHookPayload.self, from: body)
    }

    private func makeJSONResponse(statusCode: Int, response: ClaudeHookResponse) -> GCDWebServerDataResponse {
        // P-INST-213: hook 响应 JSON 编码耗时（JSONEncoder.encode + GCDWebServerDataResponse 构造；每个 hook 请求响应路径调用，encode 通常 <1ms 但归因 hook 响应延迟；slow-op ≥5ms warn）。
        #if PERF_INSTRUMENT
        let mjrStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: mjrStart)
            if durMs >= 5 { log("[HookServer] makeJSONResponse slow", level: .warn, fields: ["statusCode": String(statusCode), "durationMs": String(durMs)]) }
        }
        #endif
        let encoder = JSONEncoder()
        let bodyData = (try? encoder.encode(response)) ?? Data("{\"ok\":false}".utf8)
        let httpResponse = GCDWebServerDataResponse(data: bodyData, contentType: "application/json")
        httpResponse.statusCode = statusCode
        return httpResponse
    }
}
