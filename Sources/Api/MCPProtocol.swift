import Foundation

// MCP stdio 桥的协议纯逻辑（design-agent-access.md 通道③）。
// 桥进程（VibeFocusMCP target）由 agent host（claude code / codex / ZCode）拉起，
// 本模块把 JSON-RPC 消息翻译成对 App 命令 API（/api/v1/*）的调用——IO（HTTP/stdio）
// 全部注入：performAPI 闭包传 (method, path, body) 返回 (httpStatus, body)，
// Runner 用假 performer 直测路由与响应形状，真身只做 stdio 循环 + curl。

public enum MCPProtocol {
    public static let protocolVersion = "2024-11-05"
    public static let serverName = "vibefocus"
    public static let serverVersion = "0.1.0"

    // MARK: - 工具目录

    struct Tool: @unchecked Sendable {
        let name: String
        let description: String
        let properties: [String: [String: Any]]
        let required: [String]
        let method: String
        let path: String
        /// 参数键白名单：arguments 里只放行这些键（值透传给 API 层再校验钳制）。
        let argKeys: [String]
    }

    static let tools: [Tool] = [
        Tool(name: "vibefocus_status", description: "VibeFocus 状态总览：版本、Agent 接入开关、hook 服务、AX 授权、live 会话数",
             properties: [:], required: [], method: "GET", path: "/api/v1/status", argKeys: []),
        Tool(name: "vibefocus_settings", description: "读取用户行为偏好快照（免打扰时段/提示音/语音播报模式/网格行列等，绝无密钥）——Agent 用它自适应自身行为（如免打扰时段保持安静）",
             properties: [:], required: [], method: "GET", path: "/api/v1/settings", argKeys: []),
        Tool(name: "vibefocus_settings_set", description: "修改一项用户设置（白名单内，见 vibefocus_settings 目录；安全/凭据/热键/授权类只读不可改）",
             properties: ["key": ["type": "string", "description": "设置键（settings 目录里的 writable 项）"],
                          "value": ["description": "新值（bool/int/double/string 视键而定）"]],
             required: ["key", "value"], method: "POST", path: "/api/v1/settings", argKeys: ["key", "value"]),
        Tool(name: "vibefocus_windows_list", description: "列出屏幕上的常规窗口（id/pid/应用/标题/frame/是否主屏/绑定会话）——给 agent 一双眼睛",
             properties: [:], required: [], method: "GET", path: "/api/v1/windows", argKeys: []),
        Tool(name: "vibefocus_sessions_list", description: "列出 live 会话（session_id、最后事件、绑定窗口）",
             properties: [:], required: [], method: "GET", path: "/api/v1/sessions", argKeys: []),
        Tool(name: "vibefocus_snapshots_list", description: "列出已捕获的布局快照",
             properties: [:], required: [], method: "GET", path: "/api/v1/snapshots", argKeys: []),
        Tool(name: "vibefocus_window_move_main", description: "把指定窗口拉回主屏（含回滚管线，落审计）",
             properties: ["windowId": ["type": "integer", "description": "CGWindowID（windows_list 里取）"]],
             required: ["windowId"], method: "POST", path: "/api/v1/windows/move-main", argKeys: ["windowId"]),
        Tool(name: "vibefocus_window_float", description: "窗口浮动开/关（yabai）",
             properties: ["windowId": ["type": "integer"], "on": ["type": "boolean", "description": "true=浮动 false=平铺"]],
             required: ["windowId", "on"], method: "POST", path: "/api/v1/windows/float", argKeys: ["windowId", "on"]),
        Tool(name: "vibefocus_window_focus", description: "聚焦指定窗口",
             properties: ["windowId": ["type": "integer"]],
             required: ["windowId"], method: "POST", path: "/api/v1/windows/focus", argKeys: ["windowId"]),
        Tool(name: "vibefocus_window_layout", description: "前台窗口摆位（Rectangle 语义：leftHalf/rightHalf/topHalf/bottomHalf/topLeftQuarter/topRightQuarter/bottomLeftQuarter/bottomRightQuarter/maximize/center/nextDisplay）",
             properties: ["preset": ["type": "string", "description": "摆位名称，如 leftHalf"]],
             required: ["preset"], method: "POST", path: "/api/v1/windows/layout", argKeys: ["preset"]),
        Tool(name: "vibefocus_notify", description: "向人发一条 macOS 通知（agent 对人说话的通道：要确认、报进度）",
             properties: ["text": ["type": "string"], "title": ["type": "string"]],
             required: ["text"], method: "POST", path: "/api/v1/notify", argKeys: ["text", "title"]),
        Tool(name: "vibefocus_space_switch", description: "切到指定 yabai space（1 起序号，minimap 胶囊的 agent 版）",
             properties: ["space": ["type": "integer"]],
             required: ["space"], method: "POST", path: "/api/v1/space/switch", argKeys: ["space"]),
        Tool(name: "vibefocus_snapshot_capture", description: "捕获当前终端布局为快照（危险操作前先存档=给 agent 的 undo 点）",
             properties: ["name": ["type": "string"]],
             required: [], method: "POST", path: "/api/v1/snapshots/capture", argKeys: ["name"]),
        Tool(name: "vibefocus_grid_create", description: "创建终端网格（真开终端窗并执行启动命令；行列缺省=用户设置页当前值）",
             properties: ["rows": ["type": "integer", "description": "1...8"], "cols": ["type": "integer", "description": "1...8"]],
             required: [], method: "POST", path: "/api/v1/grid/create", argKeys: ["rows", "cols"]),
        Tool(name: "vibefocus_snapshot_restore", description: "恢复布局快照（缺省=最近一份；会重排/重建终端窗）",
             properties: ["id": ["type": "string"]],
             required: [], method: "POST", path: "/api/v1/snapshots/restore", argKeys: ["id"])
    ]

    // MARK: - JSON-RPC 消息处理

    enum JSONRPCError: Int {
        case parseError = -32700
        case methodNotFound = -32601
        case invalidParams = -32602
        case internalError = -32603
    }

    /// 处理一条 stdio JSON-RPC 消息。通知类消息（无 id）返回 nil（不回包）。
    /// performAPI：对 App 命令 API 的同步调用缝（测试注入假实现）。
    public static func handleMessage(
        _ data: Data,
        performAPI: (String, String, Data?) -> (httpStatus: Int, body: Data)
    ) -> Data? {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return errorResponse(id: NSNull(), code: JSONRPCError.parseError.rawValue, message: "Parse error")
        }
        let method = message["method"] as? String ?? ""
        let id: Any = message["id"] ?? NSNull()
        let isNotification = message["id"] == nil

        switch method {
        case "initialize":
            let result: [String: Any] = [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": serverName, "version": serverVersion]
            ]
            return resultResponse(id: id, result: result)
        case "notifications/initialized", "initialized":
            return nil
        case "ping":
            return isNotification ? nil : resultResponse(id: id, result: [:])
        case "tools/list":
            let result: [String: Any] = ["tools": toolCatalog()]
            return resultResponse(id: id, result: result)
        case "tools/call":
            let params = message["params"] as? [String: Any] ?? [:]
            let outcome = handleToolCall(params: params, performAPI: performAPI)
            let result: [String: Any] = [
                "content": [["type": "text", "text": outcome.text]],
                "isError": outcome.isError
            ]
            return resultResponse(id: id, result: result)
        default:
            return isNotification
                ? nil
                : errorResponse(id: id, code: JSONRPCError.methodNotFound.rawValue, message: "Method not found: \(method)")
        }
    }

    public static func toolCatalog() -> [[String: Any]] {
        tools.map { tool in
            var schema: [String: Any] = ["type": "object", "properties": tool.properties]
            if !tool.required.isEmpty { schema["required"] = tool.required }
            return [
                "name": tool.name,
                "description": tool.description,
                "inputSchema": schema
            ]
        }
    }

    /// tools/call → API 调用 → MCP 结果。
    public static func handleToolCall(
        params: [String: Any],
        performAPI: (String, String, Data?) -> (httpStatus: Int, body: Data)
    ) -> (text: String, isError: Bool) {
        guard let name = params["name"] as? String,
              let tool = tools.first(where: { $0.name == name }) else {
            return ("Unknown tool", true)
        }
        let args = params["arguments"] as? [String: Any] ?? [:]
        // 参数键白名单 + 值类型透传（数值钳制/必填校验归 App 端 AgentApiRequestDecoder）。
        var body: [String: Any] = [:]
        for key in tool.argKeys {
            if let value = args[key] { body[key] = value }
        }
        // 必填参数缺失在本地即拒（省一次 HTTP 往返；App 端仍会再校验）。
        for key in tool.required where body[key] == nil {
            return ("Missing required argument: \(key)", true)
        }
        let bodyData = body.isEmpty ? nil : (try? JSONSerialization.data(withJSONObject: body))
        let result = performAPI(tool.method, tool.path, bodyData)
        let text = String(data: result.body, encoding: .utf8) ?? "{\"ok\":false}"
        // 传输层失败（App 不在跑）与业务失败（ok:false）都标 isError，
        // 让 agent host 把它当工具错误呈现给模型。
        let apiOK = (try? JSONSerialization.jsonObject(with: result.body) as? [String: Any])
            .flatMap { $0 }?["ok"] as? Bool
        let isError = result.httpStatus != 200 || apiOK == false
        return (text, isError)
    }

    // MARK: - 响应构造

    static func resultResponse(id: Any, result: [String: Any]) -> Data {
        serialize(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func errorResponse(id: Any, code: Int, message: String) -> Data {
        serialize(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func serialize(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"internal\"}}".utf8)
    }
}
