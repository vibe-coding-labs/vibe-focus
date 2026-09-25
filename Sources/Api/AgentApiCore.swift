import Foundation

// Agent 接入纯判定层（design-agent-access.md §3~§5 的可测内核）：
// 分级授权矩阵 / 端点路由表 / 请求参数解码 / 响应信封。零 IO——
// HTTP 壳（ClaudeHookServer+API）、CLI（AgentCLI）、MCP 桥（MCPProtocol）
// 都骑在这一层上，保证三个通道同一套语义。

// MARK: - 偏好

/// Agent 接入偏好（设计 §5：总开关默认关；L1/L2 子开关默认全关）。
/// 读写与 ClaudeHookPreferences 同域（UserDefaults.standard / AppIdentity.bundleID）。
enum AgentAccessPreferences {
    static let enabledKey = "agentAccessEnabled"
    static let allowWindowOpsKey = "agentAllowWindowOps"
    static let allowCreateWindowsKey = "agentAllowCreateWindows"
    static let allowSettingsWriteKey = "agentAllowSettingsWrite"

    static let defaultEnabled = false
    static let defaultAllowWindowOps = false
    static let defaultAllowCreateWindows = false
    static let defaultAllowSettingsWrite = false

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var allowWindowOps: Bool {
        get { UserDefaults.standard.object(forKey: allowWindowOpsKey) as? Bool ?? defaultAllowWindowOps }
        set { UserDefaults.standard.set(newValue, forKey: allowWindowOpsKey) }
    }

    static var allowCreateWindows: Bool {
        get { UserDefaults.standard.object(forKey: allowCreateWindowsKey) as? Bool ?? defaultAllowCreateWindows }
        set { UserDefaults.standard.set(newValue, forKey: allowCreateWindowsKey) }
    }

    static var allowSettingsWrite: Bool {
        get { UserDefaults.standard.object(forKey: allowSettingsWriteKey) as? Bool ?? defaultAllowSettingsWrite }
        set { UserDefaults.standard.set(newValue, forKey: allowSettingsWriteKey) }
    }

    struct Snapshot: Equatable {
        var enabled: Bool
        var allowWindowOps: Bool
        var allowCreateWindows: Bool
    }

    static func snapshot() -> Snapshot {
        Snapshot(
            enabled: isEnabled,
            allowWindowOps: allowWindowOps,
            allowCreateWindows: allowCreateWindows
        )
    }
}

// MARK: - 操作分级

/// 操作分级（设计 §5）：L0 读 / L1 布局写 / L2 建窗改局。
enum AgentApiTier: Int, Equatable {
    /// L0：只读感知（status/windows/sessions/snapshots 列表）。
    case read = 0
    /// L1：布局写（move-main/float/focus/layout/notify/space 切换/快照捕获）。
    case windowOps = 1
    /// L2：建窗改局（grid create / snapshot restore——真开终端窗、真重排现有窗）。
    case createWindows = 2
}

/// 授权判定（纯函数）：总开关关闭一律拒绝；L0 随总开关放行；
/// L1/L2 需各自子开关。拒绝码区分「总开关」与「子开关」两种拒绝。
enum AgentAccessGate {
    static func isTierAllowed(_ tier: AgentApiTier, prefs: AgentAccessPreferences.Snapshot) -> Bool {
        guard prefs.enabled else { return false }
        switch tier {
        case .read: return true
        case .windowOps: return prefs.allowWindowOps
        case .createWindows: return prefs.allowCreateWindows
        }
    }

    /// 仅在 isTierAllowed == false 时调用；返回 403 响应的稳定错误码。
    static func denialCode(prefs: AgentAccessPreferences.Snapshot) -> String {
        if !prefs.enabled { return "agent_access_disabled" }
        if !prefs.allowWindowOps && !prefs.allowCreateWindows { return "agent_writes_disabled" }
        return prefs.allowWindowOps ? "create_windows_disabled" : "window_ops_disabled"
    }
}

// MARK: - 端点路由表

/// 静态端点表（设计 §3 通道②）：无路径变量——带 ID 的操作一律走 JSON body，
/// 与既有 /claude/hook 单路由注册方式同构，不依赖 GCDWebServer 的路径匹配扩展。
struct AgentApiEndpoint: Equatable {
    let method: String
    let path: String
    let tier: AgentApiTier

    static let apiPrefix = "/api/v1"

    static let all: [AgentApiEndpoint] = [
        AgentApiEndpoint(method: "GET", path: "\(apiPrefix)/status", tier: .read),
        AgentApiEndpoint(method: "GET", path: "\(apiPrefix)/settings", tier: .read),
        AgentApiEndpoint(method: "GET", path: "\(apiPrefix)/windows", tier: .read),
        AgentApiEndpoint(method: "GET", path: "\(apiPrefix)/sessions", tier: .read),
        AgentApiEndpoint(method: "GET", path: "\(apiPrefix)/snapshots", tier: .read),
        AgentApiEndpoint(method: "POST", path: "\(apiPrefix)/windows/move-main", tier: .windowOps),
        AgentApiEndpoint(method: "POST", path: "\(apiPrefix)/windows/float", tier: .windowOps),
        AgentApiEndpoint(method: "POST", path: "\(apiPrefix)/windows/focus", tier: .windowOps),
        AgentApiEndpoint(method: "POST", path: "\(apiPrefix)/windows/layout", tier: .windowOps),
        AgentApiEndpoint(method: "POST", path: "\(apiPrefix)/notify", tier: .windowOps),
        AgentApiEndpoint(method: "POST", path: "\(apiPrefix)/space/switch", tier: .windowOps),
        AgentApiEndpoint(method: "POST", path: "\(apiPrefix)/snapshots/capture", tier: .windowOps),
        AgentApiEndpoint(method: "POST", path: "\(apiPrefix)/grid/create", tier: .createWindows),
        AgentApiEndpoint(method: "POST", path: "\(apiPrefix)/snapshots/restore", tier: .createWindows),
        // settings 写：过总开关门（.read tier 语义）后由 handler 独立校验
        // allowSettingsWrite——支持「只开设置写、不开窗口操作」的授权组合。
        AgentApiEndpoint(method: "POST", path: "\(apiPrefix)/settings", tier: .read)
    ]

    static func match(method: String, path: String) -> AgentApiEndpoint? {
        all.first { $0.method == method && $0.path == path }
    }
}

// MARK: - 请求参数解码（纯函数）

/// body JSON → 操作参数。返回 nil = 参数缺失/非法（调用方回 400 bad_request）。
enum AgentApiRequestDecoder {
    static func parseJSONObject(_ data: Data?) -> [String: Any]? {
        guard let data, !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func decodeWindowID(_ json: [String: Any]) -> UInt32? {
        guard let value = json["windowId"] else { return nil }
        if let n = value as? UInt32, n > 0 { return n }
        if let n = value as? Int { return (n > 0 && n <= Int(UInt32.max)) ? UInt32(n) : nil }
        // JSON number 走 NSNumber 桥接；显式排除 Bool（true 会桥成 1 被误收）与负数
        // （-5 的 uint32Value 回绕成巨正数）——两者都是 Agent 消息常见手误。
        if let n = value as? NSNumber, !(value is Bool) {
            let i = n.intValue
            return (i > 0 && i <= Int(UInt32.max)) ? UInt32(i) : nil
        }
        return nil
    }

    static func decodeFloat(_ json: [String: Any]) -> (windowID: UInt32, on: Bool)? {
        guard let windowID = decodeWindowID(json) else { return nil }
        guard let on = json["on"] as? Bool else { return nil }
        return (windowID, on)
    }

    static func decodeLayout(_ json: [String: Any]) -> LayoutAction? {
        guard let raw = json["preset"] as? String else { return nil }
        return LayoutAction(rawValue: raw)
    }

    static func decodeNotify(_ json: [String: Any]) -> (text: String, title: String?)? {
        guard let text = json["text"] as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2000 else { return nil }
        let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed, (title?.isEmpty ?? true) ? nil : title)
    }

    /// yabai space 序号（1 起）。上界给宽（64）：真实上界由 SpaceController 执行期校验。
    static func decodeSpaceSwitch(_ json: [String: Any]) -> Int? {
        guard let space = json["space"] as? Int, (1...64).contains(space) else { return nil }
        return space
    }

    /// 行列覆盖（可缺省=用当前网格偏好）；钳制 1...8 防御 Agent 传 999 铺满桌面。
    static func decodeGridCreate(_ json: [String: Any]) -> (rows: Int?, cols: Int?)? {
        let rows = json["rows"] as? Int
        let cols = json["cols"] as? Int
        if rows == nil && cols == nil { return (nil, nil) }
        if let r = rows, !(1...8).contains(r) { return nil }
        if let c = cols, !(1...8).contains(c) { return nil }
        return (rows, cols)
    }

    static func decodeSnapshotCapture(_ json: [String: Any]) -> String? {
        guard let name = json["name"] as? String else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
    }

    static func decodeSnapshotRestore(_ json: [String: Any]) -> String? {
        guard let id = json["id"] as? String else { return nil }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - 响应信封

/// 统一 JSON 信封：{"ok":bool,"code":str,"message":str,"data":{...}?}
/// HTTP 状态码承载传输语义（200/400/401/403/404/409/500），code 承载业务语义。
enum AgentApiResponseBuilder {
    static func body(ok: Bool, code: String, message: String, data: [String: Any]? = nil) -> Data {
        var payload: [String: Any] = ["ok": ok, "code": code, "message": message]
        if let data { payload["data"] = data }
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    }
}

// MARK: - 读侧模型（windows 列表）

/// Agent 感知窗口列表行（设计 §4 首行：给 Agent 一双眼睛）。
struct AgentWindowSummary: Equatable {
    let windowID: UInt32
    let pid: Int32
    let app: String?
    let title: String?
    let x: Double?
    let y: Double?
    let width: Double?
    let height: Double?
    let isOnScreen: Bool
    let onMainScreen: Bool
    let sessionID: String?
}

enum AgentWindowListing {
    /// 构建感知列表（纯函数，屏幕框与会话绑定查法由调用方注入）：
    /// 只收 layer==0 的常规窗口（菜单栏/浮层/状态项排除，与 minimap 同口径）。
    static func summaries(
        from entries: [CGWindowEntry],
        mainScreenFrame: CGRect?,
        sessionLookup: (UInt32) -> String?
    ) -> [AgentWindowSummary] {
        entries
            .filter { $0.layer == 0 }
            .map { entry in
                let b = entry.bounds
                let onMain: Bool = {
                    guard let mainScreenFrame, let b else { return false }
                    return mainScreenFrame.contains(CGPoint(x: b.midX, y: b.midY))
                }()
                return AgentWindowSummary(
                    windowID: entry.windowID,
                    pid: entry.ownerPID,
                    app: entry.ownerName,
                    title: entry.name,
                    x: b.map { Double($0.origin.x) },
                    y: b.map { Double($0.origin.y) },
                    width: b.map { Double($0.width) },
                    height: b.map { Double($0.height) },
                    isOnScreen: entry.isOnScreen,
                    onMainScreen: onMain,
                    sessionID: sessionLookup(entry.windowID)
                )
            }
    }

    static func dictionary(_ s: AgentWindowSummary) -> [String: Any] {
        var d: [String: Any] = [
            "windowId": s.windowID,
            "pid": s.pid,
            "isOnScreen": s.isOnScreen,
            "onMainScreen": s.onMainScreen
        ]
        if let app = s.app { d["app"] = app }
        if let title = s.title { d["title"] = title }
        if let x = s.x { d["x"] = x }
        if let y = s.y { d["y"] = y }
        if let w = s.width { d["width"] = w }
        if let h = s.height { d["height"] = h }
        if let sessionID = s.sessionID { d["sessionId"] = sessionID }
        return d
    }
}
