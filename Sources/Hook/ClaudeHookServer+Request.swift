import Foundation
@preconcurrency import GCDWebServer

// Sources/Hook/ClaudeHookServer+Request.swift — B156 自 ClaudeHookServer.swift 按域拆出
// （逐字搬移零行为变更）：hook 请求编排（token 门→解码→事件分发→计数→响应构造）。
// HTTP 壳回环直测：RunnerHookWalkTests B154 hookSrv 块。

extension ClaudeHookServer {

    // MARK: - Request Handling

    func handleHookRequest(
        body: Data,
        query: [String: String],
        headers: [String: String],
        peerAddress: String? = nil
    ) async -> (statusCode: Int, response: ClaudeHookResponse) {
        // P-INST-71: hook 请求端到端总耗时（token 验证 + JSON decode + eventHandler 处理 + 响应构造；hook 路径顶层归因，配合子阶段 P-INST-38/47/54/55/56）。
        let hhrStart = Date()
        // B178 常开埋点：hook 处理全程占主线程（窗口作业同步执行），停顿看门狗
        // 依赖区间栈归因「卡在哪个事件」。外层 hook.request 记全程，事件级
        // hook.<event> 在分发处再套一层（嵌套区间，看门狗日志父子链可见）。
        PerfMonitor.shared.beginSection("hook.request")
        defer { PerfMonitor.shared.endSection() }
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

        // B171: 直投可达时顺路自注册 spool 拉取主机。注册决策要求事件 TCP 对端
        // == forwarder 上报的 ssh_server_ip（防伪造），对端 nil（spool 回灌通道）
        // 自然不注册——那时主机清单来自设置页手动添加/装机预置。
        if let ctx = payload.terminalCtx {
            let target = RemoteSpoolDrainLogic.registrationTarget(
                machineLabel: ctx.machineLabel,
                sshUser: ctx.sshUser,
                sshServerIP: ctx.sshServerIP,
                peerIP: RemoteSpoolDrainLogic.peerIP(fromRemoteAddress: peerAddress)
            )
            if let target, RemoteSpoolHosts.registerHost(target) {
                log("[ClaudeHookServer] spool drain host auto-registered", fields: [
                    "host": target,
                    "machineLabel": ctx.machineLabel ?? "nil"
                ])
            }
        }

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

        // B178 事件级区间：UPS 归位/Stop 移动都在此段同步占主线程（实测归位
        // 34/35 次 >200ms、Stop 移动 16/16 次 >200ms），看门狗停顿日志靠它归因。
        PerfMonitor.shared.beginSection("hook.\(payload.event.rawValue)", fields: [
            "session": String(payload.sessionID.prefix(8)),
            "src": isRemote ? "remote" : "local"
        ])
        defer { PerfMonitor.shared.endSection() }

        switch payload.event {
        case .sessionStart:
            result = eventHandler.handleSessionStart(payload: payload)
        case .stop:
            result = await eventHandler.handleStop(payload: payload)
            // 语音播报：与移窗逻辑解耦，无条件异步触发（不阻塞 hook 响应）。
            // 窗口已在主屏（handleStop 早返回）时语音仍触发，避免依赖 moved 标志。
            Task { @MainActor in
                VoiceAnnouncementManager.shared.announceCompletion(payload: payload)
            }
        case .sessionEnd:
            result = await eventHandler.handleWindowMoveTrigger(payload: payload, triggerName: "SessionEnd")
        case .userPromptSubmit:
            result = await eventHandler.handleUserPromptSubmit(payload: payload)
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

    func makeJSONResponse(statusCode: Int, response: ClaudeHookResponse) -> GCDWebServerDataResponse {
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
