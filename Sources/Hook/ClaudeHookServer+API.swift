import AppKit
import Foundation
@preconcurrency import GCDWebServer

// Agent 命令 API（design-agent-access.md 通道②）：与 /claude/hook 并列挂在同一
// GCDWebServer 上，复用同一 token 门与绑定面（恒 127.0.0.1，不随 LAN 模式开放）。
// 判定全部在 AgentApiCore 纯函数层；本文件只做 HTTP 壳编排：
// token 门 → 端点匹配 → 分级授权门 → 参数解码 → 能力层调用 → 信封响应。
// 归因：所有写操作走 triggerSource="agent" / reason=.agentCommand，落既有审计链。

@MainActor
extension ClaudeHookServer {

    /// 注册全部 /api/v1/* 端点（静态路径，逐条 addHandler——无路径变量）。
    func registerAgentAPIRoutes(on webServer: GCDWebServer) {
        for endpoint in AgentApiEndpoint.all {
            webServer.addHandler(
                forMethod: endpoint.method,
                path: endpoint.path,
                request: GCDWebServerDataRequest.self,
                asyncProcessBlock: { [weak self] request, completionBlock in
                    Task { @MainActor in
                        guard let self else {
                            let r = GCDWebServerDataResponse(
                                data: AgentApiResponseBuilder.body(ok: false, code: "server_error", message: "server gone"),
                                contentType: "application/json"
                            )
                            r.statusCode = 500
                            completionBlock(r)
                            return
                        }
                        let bodyData = (request as? GCDWebServerDataRequest)?.data
                        let result = await self.handleAgentAPIRequest(
                            method: (request.method as NSString) as String,
                            path: request.path,
                            body: bodyData,
                            query: request.query ?? [:],
                            headers: request.headers
                        )
                        let response = GCDWebServerDataResponse(data: result.body, contentType: "application/json")
                        response.statusCode = result.statusCode
                        completionBlock(response)
                    }
                }
            )
        }
    }

    /// Agent API 总分发。返回 (HTTP 状态码, JSON body)。
    func handleAgentAPIRequest(
        method: String,
        path: String,
        body: Data?,
        query: [String: String],
        headers: [String: String]
    ) async -> (statusCode: Int, body: Data) {
        // 与 hook 同一门：query token 或 X-VibeFocus-Token header。
        if Self.tokenGateRejected(query: query, headers: headers, expectedToken: configuredToken) {
            return (401, AgentApiResponseBuilder.body(ok: false, code: "unauthorized", message: "Missing or invalid API token"))
        }
        guard let endpoint = AgentApiEndpoint.match(method: method, path: path) else {
            return (404, AgentApiResponseBuilder.body(ok: false, code: "not_found", message: "Unknown API endpoint"))
        }
        let prefs = AgentAccessPreferences.snapshot()
        guard AgentAccessGate.isTierAllowed(endpoint.tier, prefs: prefs) else {
            return (403, AgentApiResponseBuilder.body(ok: false, code: AgentAccessGate.denialCode(prefs: prefs), message: "Agent access tier not enabled"))
        }
        let json = AgentApiRequestDecoder.parseJSONObject(body) ?? [:]

        switch endpoint.path {
        case "\(AgentApiEndpoint.apiPrefix)/status":
            return (200, Self.buildStatusBody(prefs: prefs))
        case "\(AgentApiEndpoint.apiPrefix)/settings" where method == "GET":
            return (200, AgentApiResponseBuilder.body(ok: true, code: "ok", message: "",
                                                     data: AgentSettingsCatalog.readAll()))
        case "\(AgentApiEndpoint.apiPrefix)/settings" where method == "POST":
            return Self.handleSettingsWrite(json: json)
        case "\(AgentApiEndpoint.apiPrefix)/windows":
            return (200, Self.buildWindowsBody())
        case "\(AgentApiEndpoint.apiPrefix)/sessions":
            return (200, Self.buildSessionsBody())
        case "\(AgentApiEndpoint.apiPrefix)/snapshots":
            return (200, Self.buildSnapshotsBody())
        case "\(AgentApiEndpoint.apiPrefix)/windows/move-main":
            return await handleMoveMain(json: json)
        case "\(AgentApiEndpoint.apiPrefix)/windows/float":
            return handleFloat(json: json)
        case "\(AgentApiEndpoint.apiPrefix)/windows/focus":
            return handleFocus(json: json)
        case "\(AgentApiEndpoint.apiPrefix)/windows/layout":
            return handleLayout(json: json)
        case "\(AgentApiEndpoint.apiPrefix)/notify":
            return await handleNotify(json: json)
        case "\(AgentApiEndpoint.apiPrefix)/space/switch":
            return handleSpaceSwitch(json: json)
        case "\(AgentApiEndpoint.apiPrefix)/snapshots/capture":
            return await handleSnapshotCapture(json: json)
        case "\(AgentApiEndpoint.apiPrefix)/grid/create":
            return await handleGridCreate(json: json)
        case "\(AgentApiEndpoint.apiPrefix)/snapshots/restore":
            return await handleSnapshotRestore(json: json)
        default:
            return (404, AgentApiResponseBuilder.body(ok: false, code: "not_found", message: "Unknown API endpoint"))
        }
    }

    // MARK: - L0 读 + 设置写

    /// GET 全量读已上收 AgentSettingsCatalog.readAll()（目录=唯一事实源）。

    /// POST /api/v1/settings —— 白名单设置写（独立授权 agentAllowSettingsWrite，默认关）。
    /// body：{"key":"...","value":...} 或 {"updates":[{...}, ...]}（1...50 项）。
    /// 每项独立成败：目录外键 400 settings_key_unknown、人属键 403 settings_key_readonly、
    /// 值非法 400 settings_value_invalid、未授权 403 settings_write_disabled。
    /// 应用统一走 AgentSettingsCatalog.apply（复用既有 update 链 + agent 归因日志）。
    static func handleSettingsWrite(json: [String: Any]) -> (statusCode: Int, body: Data) {
        guard AgentAccessPreferences.allowSettingsWrite else {
            return (403, AgentApiResponseBuilder.body(
                ok: false, code: "settings_write_disabled",
                message: "「允许 Agent 修改设置」开关未开启（设置页 Agent 接入）"))
        }
        var items: [[String: Any]] = []
        if let updates = json["updates"] as? [[String: Any]] {
            items = updates
        } else if let key = json["key"] as? String, let value = json["value"] {
            items = [["key": key, "value": value]]
        } else {
            return (400, AgentApiResponseBuilder.body(
                ok: false, code: "bad_request", message: "需要 key/value 或 updates 数组"))
        }
        guard !items.isEmpty, items.count <= 50 else {
            return (400, AgentApiResponseBuilder.body(
                ok: false, code: "bad_request", message: "updates 需 1...50 项"))
        }
        var results: [[String: Any]] = []
        var allOK = true
        var sawReadonly = false
        for item in items {
            guard let key = item["key"] as? String, item["value"] != nil else {
                allOK = false
                results.append(["key": "?", "ok": false, "error": "bad_request"])
                continue
            }
            var row: [String: Any] = ["key": key]
            if let error = AgentSettingsCatalog.apply(key: key, raw: item["value"]!) {
                allOK = false
                if error == "settings_key_readonly" { sawReadonly = true }
                row["ok"] = false
                row["error"] = error
            } else {
                row["ok"] = true
            }
            results.append(row)
        }
        let status = allOK ? 200 : (sawReadonly ? 403 : 400)
        let data: [String: Any] = ["results": results]
        return (status, AgentApiResponseBuilder.body(ok: allOK, code: allOK ? "applied" : "rejected",
                                                     message: "", data: data))
    }

    static func buildStatusBody(prefs: AgentAccessPreferences.Snapshot) -> Data {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let sessions = SessionActivityTracker.shared.activities.count
        let data: [String: Any] = [
            "version": version ?? "unknown",
            "agentAccess": [
                "enabled": prefs.enabled,
                "allowWindowOps": prefs.allowWindowOps,
                "allowCreateWindows": prefs.allowCreateWindows
            ],
            "hookServer": [
                "running": ClaudeHookServer.shared.isRunning,
                "port": ClaudeHookServer.shared.activePort ?? 0
            ],
            "accessibilityGranted": WindowManager.shared.hasAccessibilityPermission(),
            "sessionCount": sessions
        ]
        return AgentApiResponseBuilder.body(ok: true, code: "ok", message: "", data: data)
    }

    static func buildWindowsBody() -> Data {
        let mainScreen = NSScreen.screens.first { $0.frame.origin == .zero }?.frame
            ?? NSScreen.main?.frame
        let summaries = AgentWindowListing.summaries(
            from: cgWindowListAll(),
            mainScreenFrame: mainScreen,
            sessionLookup: { windowID in SessionWindowRegistry.shared.findState(windowID: windowID)?.sessionID }
        )
        let data: [String: Any] = [
            "count": summaries.count,
            "windows": summaries.map(AgentWindowListing.dictionary)
        ]
        return AgentApiResponseBuilder.body(ok: true, code: "ok", message: "", data: data)
    }

    static func buildSessionsBody() -> Data {
        let activities = SessionActivityTracker.shared.activities
        let rows: [[String: Any]] = activities
            .map { sessionID, activity -> [String: Any] in
                var row: [String: Any] = [
                    "sessionId": sessionID,
                    "lastEvent": activity.lastEvent.rawValue,
                    "lastAt": ISO8601DateFormatter().string(from: activity.at)
                ]
                if let state = SessionWindowRegistry.shared.binding(for: sessionID) {
                    row["windowId"] = state.windowID
                    if let app = state.appName { row["app"] = app }
                    if let title = state.title { row["title"] = title }
                    row["completed"] = state.isCompleted
                }
                return row
            }
            .sorted { ($0["lastAt"] as? String ?? "") > ($1["lastAt"] as? String ?? "") }
        let data: [String: Any] = ["count": rows.count, "sessions": rows]
        return AgentApiResponseBuilder.body(ok: true, code: "ok", message: "", data: data)
    }

    static func buildSnapshotsBody() -> Data {
        let snapshots = SessionRestoreController.shared.snapshotsForRefresh()
        let rows: [[String: Any]] = snapshots.map { snap in
            [
                "id": snap.id,
                "name": snap.name,
                "capturedAt": ISO8601DateFormatter().string(from: snap.capturedAt),
                "windowCount": snap.windows.count
            ]
        }
        let data: [String: Any] = ["count": rows.count, "snapshots": rows]
        return AgentApiResponseBuilder.body(ok: true, code: "ok", message: "", data: data)
    }

    // MARK: - L1 布局写

    func handleMoveMain(json: [String: Any]) async -> (Int, Data) {
        guard let windowID = AgentApiRequestDecoder.decodeWindowID(json) else {
            return (400, AgentApiResponseBuilder.body(ok: false, code: "bad_request", message: "windowId required"))
        }
        guard let identity = WindowManager.shared.findWindowByCGWindowID(windowID) else {
            return (404, AgentApiResponseBuilder.body(ok: false, code: "window_not_found", message: "No window with id \(windowID)"))
        }
        let moved = await WindowWorkExecutor.run {
            WindowManager.shared.moveWindowToMainScreen(
                identity: identity,
                reason: .agentCommand,
                sessionID: nil
            )
        }
        if moved {
            return (200, AgentApiResponseBuilder.body(ok: true, code: "moved", message: "Window moved to main screen", data: ["windowId": windowID]))
        }
        return (409, AgentApiResponseBuilder.body(ok: false, code: "window_move_failed", message: "Failed to move window to main screen"))
    }

    func handleFloat(json: [String: Any]) -> (Int, Data) {
        guard let (windowID, on) = AgentApiRequestDecoder.decodeFloat(json) else {
            return (400, AgentApiResponseBuilder.body(ok: false, code: "bad_request", message: "windowId and boolean on required"))
        }
        // 显式 on/off 语义：query 当前态，已一致则 no-op；否则 toggle 一次。
        let info = SpaceController.shared.queryWindow(windowID: windowID)
        let currentlyFloating = info?.isFloating ?? false
        if currentlyFloating == on {
            return (200, AgentApiResponseBuilder.body(ok: true, code: "no_op", message: "Window already \(on ? "floating" : "tiled")", data: ["windowId": windowID, "floating": on]))
        }
        let outcome = SpaceController.shared.setWindowFloat(windowID, operationID: "agent-float-\(windowID)", knownWindowInfo: info)
        if outcome == .toggled {
            return (200, AgentApiResponseBuilder.body(ok: true, code: "toggled", message: "Window float \(on ? "on" : "off")", data: ["windowId": windowID, "floating": on]))
        }
        return (409, AgentApiResponseBuilder.body(ok: false, code: "float_failed", message: "Window not manageable by yabai (no AX reference or query failed)"))
    }

    func handleFocus(json: [String: Any]) -> (Int, Data) {
        guard let windowID = AgentApiRequestDecoder.decodeWindowID(json) else {
            return (400, AgentApiResponseBuilder.body(ok: false, code: "bad_request", message: "windowId required"))
        }
        let focused = SpaceController.shared.focusWindow(windowID, operationID: "agent-focus-\(windowID)")
        if focused {
            return (200, AgentApiResponseBuilder.body(ok: true, code: "focused", message: "Window focused", data: ["windowId": windowID]))
        }
        return (409, AgentApiResponseBuilder.body(ok: false, code: "focus_failed", message: "Failed to focus window"))
    }

    func handleLayout(json: [String: Any]) -> (Int, Data) {
        guard let action = AgentApiRequestDecoder.decodeLayout(json) else {
            let valid = LayoutAction.allCases.map(\.rawValue).joined(separator: ",")
            return (400, AgentApiResponseBuilder.body(ok: false, code: "bad_request", message: "preset must be one of: \(valid)"))
        }
        // 摆位语义作用于前台焦点窗（Rectangle 惯例，与热键/菜单一致）。
        let ok = WindowManager.shared.applyLayoutAction(action, triggerSource: "agent")
        if ok {
            return (200, AgentApiResponseBuilder.body(ok: true, code: "applied", message: "Layout \(action.rawValue) applied to focused window"))
        }
        return (409, AgentApiResponseBuilder.body(ok: false, code: "layout_failed", message: "Failed to apply layout (no focusable window or accessibility not granted)"))
    }

    func handleNotify(json: [String: Any]) async -> (Int, Data) {
        guard let (text, title) = AgentApiRequestDecoder.decodeNotify(json) else {
            return (400, AgentApiResponseBuilder.body(ok: false, code: "bad_request", message: "non-empty text (≤2000 chars) required"))
        }
        let content = HookNotificationContent(
            identifier: "agent-notify-\(UUID().uuidString.prefix(8))",
            title: title ?? "VibeFocus Agent",
            body: text
        )
        let posted = await UserNotificationPoster.shared.post(content)
        if posted {
            return (200, AgentApiResponseBuilder.body(ok: true, code: "posted", message: "Notification delivered"))
        }
        return (409, AgentApiResponseBuilder.body(ok: false, code: "notify_failed", message: "Notification not delivered (center unavailable or denied)"))
    }

    func handleSpaceSwitch(json: [String: Any]) -> (Int, Data) {
        guard let space = AgentApiRequestDecoder.decodeSpaceSwitch(json) else {
            return (400, AgentApiResponseBuilder.body(ok: false, code: "bad_request", message: "space (yabai index, 1-based int) required"))
        }
        let result = SpaceController.shared.switchToSpace(space, operationID: "agent-space-\(space)")
        switch result.outcome {
        case .noDrift:
            // 视角本就未被拖走 = 目标 space 已在前台（或查询失败保守放行）。
            return (200, AgentApiResponseBuilder.body(ok: true, code: "switched", message: "Space switch done", data: ["space": space]))
        case .refocused:
            return (200, AgentApiResponseBuilder.body(ok: true, code: "switched", message: "Space switched", data: ["space": space]))
        case .failed:
            return (409, AgentApiResponseBuilder.body(ok: false, code: "space_switch_failed", message: "Space switch failed (yabai unavailable or space not found)"))
        }
    }

    // MARK: - L2 建窗改局（capture 归 L1，restore 归 L2）

    func handleSnapshotCapture(json: [String: Any]) async -> (Int, Data) {
        let name = AgentApiRequestDecoder.decodeSnapshotCapture(json)
        let result = await SessionRestoreController.shared.captureCurrentLayout(name: name)
        if result.ok {
            return (200, AgentApiResponseBuilder.body(ok: true, code: "captured", message: result.message))
        }
        return (409, AgentApiResponseBuilder.body(ok: false, code: "capture_failed", message: result.message))
    }

    func handleGridCreate(json: [String: Any]) async -> (Int, Data) {
        let params = AgentApiRequestDecoder.decodeGridCreate(json) ?? (nil, nil)
        let result = await TerminalGridController.shared.createGrid(rowsOverride: params.0, colsOverride: params.1)
        if result.ok {
            return (200, AgentApiResponseBuilder.body(ok: true, code: "grid_created", message: result.message))
        }
        return (409, AgentApiResponseBuilder.body(ok: false, code: "grid_create_failed", message: result.message))
    }

    func handleSnapshotRestore(json: [String: Any]) async -> (Int, Data) {
        let id = AgentApiRequestDecoder.decodeSnapshotRestore(json)
        let result = await SessionRestoreController.shared.restoreLayout(snapshotID: id)
        if result.ok {
            return (200, AgentApiResponseBuilder.body(ok: true, code: "restored", message: result.message))
        }
        return (409, AgentApiResponseBuilder.body(ok: false, code: "restore_failed", message: result.message))
    }
}
