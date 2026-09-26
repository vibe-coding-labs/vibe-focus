import Foundation
import ApplicationServices

// Agent CLI（design-agent-access.md 通道①）：同一二进制的即退式子命令面。
// 读类（status/windows/sessions）本地直读（CG 窗口列表 + session-activity.json，
// 不依赖 App 在跑——agent 排障场景的健壮性来源）；snapshots 列表与全部写类
// 转发常驻 App 的 /api/v1/*（写操作必须在 App 进程内走完整管线：回滚/收敛/审计）。
// 传输用 curl 子进程（与 hook-forwarder.sh 同款通道，无并发框架负担）。
// 退出码契约：0 成功 / 2 用法错 / 3 App 不可达 / 4 token 无效 / 5 授权门拒绝 / 6 操作失败。

// MARK: - 命令模型

public enum AgentCLICommand: Equatable, Sendable {
    case status
    case windowsList(includeAll: Bool)
    case sessionsList
    case snapshotsList
    case moveMain(windowID: UInt32)
    case float(windowID: UInt32, on: Bool)
    case focus(windowID: UInt32)
    case layout(preset: String)
    case notify(text: String, title: String?)
    case spaceSwitch(space: Int)
    case gridCreate(rows: Int?, cols: Int?)
    case snapshotCapture(name: String?)
    case snapshotRestore(id: String?)
    case settingsGet
    case settingsSet(key: String, value: String)

    /// 转发 App 的 API 端点；nil = 本地直读命令。
    var apiEndpoint: AgentApiEndpoint? {
        switch self {
        case .status:
            return AgentApiEndpoint.all.first { $0.path.hasSuffix("/status") }
        case .snapshotsList:
            return AgentApiEndpoint.all.first { $0.path.hasSuffix("/snapshots") }
        case .moveMain:
            return AgentApiEndpoint.all.first { $0.path.hasSuffix("/windows/move-main") }
        case .float:
            return AgentApiEndpoint.all.first { $0.path.hasSuffix("/windows/float") }
        case .focus:
            return AgentApiEndpoint.all.first { $0.path.hasSuffix("/windows/focus") }
        case .layout:
            return AgentApiEndpoint.all.first { $0.path.hasSuffix("/windows/layout") }
        case .notify:
            return AgentApiEndpoint.all.first { $0.path.hasSuffix("/notify") }
        case .spaceSwitch:
            return AgentApiEndpoint.all.first { $0.path.hasSuffix("/space/switch") }
        case .gridCreate:
            return AgentApiEndpoint.all.first { $0.path.hasSuffix("/grid/create") }
        case .snapshotCapture:
            return AgentApiEndpoint.all.first { $0.path.hasSuffix("/snapshots/capture") }
        case .snapshotRestore:
            return AgentApiEndpoint.all.first { $0.path.hasSuffix("/snapshots/restore") }
        case .settingsGet:
            // /settings 同时有 GET+POST 两条——suffix-first 会恒匹配到 GET
            // （实测：CLI 改设置静默无效果），必须按方法精确定位。
            return AgentApiEndpoint.match(method: "GET", path: "/api/v1/settings")
        case .settingsSet:
            return AgentApiEndpoint.match(method: "POST", path: "/api/v1/settings")
        case .windowsList, .sessionsList:
            return nil
        }
    }

    /// 转发请求的 JSON body（GET 为空）。
    var apiBody: [String: Any] {
        switch self {
        case .moveMain(let id): return ["windowId": Int(id)]
        case .float(let id, let on): return ["windowId": Int(id), "on": on]
        case .focus(let id): return ["windowId": Int(id)]
        case .layout(let preset): return ["preset": preset]
        case .notify(let text, let title):
            var d: [String: Any] = ["text": text]
            if let title { d["title"] = title }
            return d
        case .spaceSwitch(let space): return ["space": space]
        case .gridCreate(let rows, let cols):
            var d: [String: Any] = [:]
            if let rows { d["rows"] = rows }
            if let cols { d["cols"] = cols }
            return d
        case .snapshotCapture(let name):
            return name.map { ["name": $0] } ?? [:]
        case .snapshotRestore(let id):
            return id.map { ["id": $0] } ?? [:]
        case .settingsSet(let key, let value):
            return ["key": key, "value": AgentCLIRouter.parseCLIValue(value)]
        case .status, .windowsList, .sessionsList, .snapshotsList, .settingsGet:
            return [:]
        }
    }
}

// MARK: - 参数解析（纯函数，Runner 直测）

public enum AgentCLIParseOutcome: Equatable {
    /// 不是 CLI 调用形态 → App 正常启动。
    case notOurs
    case command(AgentCLICommand)
    /// 是 CLI 调用形态但语法错误 → 打印用法退 2。
    case invalid(String)
}

public enum AgentCLIRouter {
    public static let usage = """
    用法: VibeFocusHotkeys <命令> [参数]
      status                              App 与接入状态总览
      windows list [--all]                列出常规窗口（默认滤小窗，--all 全量；本地直读）
      windows move-main --id <N>          窗口拉回主屏
      windows float --id <N> --on|--off   浮动开/关（yabai）
      windows focus --id <N>              聚焦窗口
      windows layout --preset <名称>       前台窗口摆位（leftHalf/rightHalf/maximize/...）
      sessions list                       列出 live 会话与绑定（本地直读）
      snapshots list                      列出布局快照
      snapshots capture [--name <名>]      捕获当前布局
      snapshots restore [--id <ID>]       恢复快照（缺省=最近一份）
      grid create [--rows N] [--cols N]   创建终端网格（行列缺省=设置页当前值）
      notify --text <文本> [--title <题>]   向人发一条 macOS 通知
      space switch --space <N>            切到 yabai space N（1 起）
      settings get                        读取全部设置目录（含可写白名单）
      settings set --key K --value V      修改一项设置（需授权开关，白名单内）
    """

    static let topLevelVerbs: Set<String> = ["status", "windows", "sessions", "snapshots", "grid", "notify", "space", "settings"]

    /// args 不含 argv0。首 token 不是已知动词 → notOurs（App 正常启动）。
    public static func parse(_ args: [String]) -> AgentCLIParseOutcome {
        guard let verb = args.first else { return .notOurs }
        guard topLevelVerbs.contains(verb) else { return .notOurs }
        let rest = Array(args.dropFirst())

        switch verb {
        case "status":
            return rest.isEmpty ? .command(.status) : .invalid("status 不接受参数")
        case "windows":
            return parseWindows(rest)
        case "sessions":
            return rest == ["list"] ? .command(.sessionsList) : .invalid("用法: sessions list")
        case "snapshots":
            return parseSnapshots(rest)
        case "grid":
            return rest.first == "create" ? parseGridCreate(Array(rest.dropFirst())) : .invalid("用法: grid create [--rows N] [--cols N]")
        case "notify":
            return parseNotify(rest)
        case "space":
            return rest.first == "switch" ? parseSpaceSwitch(Array(rest.dropFirst())) : .invalid("用法: space switch --space N")
        case "settings":
            return parseSettings(rest)
        default:
            return .notOurs
        }
    }

    private static func parseWindows(_ rest: [String]) -> AgentCLIParseOutcome {
        switch rest.first {
        case "list":
            if rest.count == 1 { return .command(.windowsList(includeAll: false)) }
            if rest == ["list", "--all"] { return .command(.windowsList(includeAll: true)) }
            return .invalid("用法: windows list [--all]")
        case "move-main":
            let sub = Array(rest.dropFirst())
            guard let raw = flagValue(sub, "--id"), let id = UInt32(raw), id > 0 else {
                return .invalid("move-main 需要 --id <N>")
            }
            return .command(.moveMain(windowID: id))
        case "focus":
            let sub = Array(rest.dropFirst())
            guard let raw = flagValue(sub, "--id"), let id = UInt32(raw), id > 0 else {
                return .invalid("focus 需要 --id <N>")
            }
            return .command(.focus(windowID: id))
        case "float":
            let sub = Array(rest.dropFirst())
            guard let id = flagValue(sub, "--id"), let idNum = UInt32(id), idNum > 0 else {
                return .invalid("float 需要 --id <N>")
            }
            if sub.contains("--on") { return .command(.float(windowID: idNum, on: true)) }
            if sub.contains("--off") { return .command(.float(windowID: idNum, on: false)) }
            return .invalid("float 需要 --on 或 --off")
        case "layout":
            guard let preset = flagValue(Array(rest.dropFirst()), "--preset") else {
                return .invalid("layout 需要 --preset <名称>（leftHalf/rightHalf/topHalf/bottomHalf/maximize/center/nextDisplay/四分）")
            }
            return .command(.layout(preset: preset))
        default:
            return .invalid("未知 windows 子命令")
        }
    }

    private static func parseSnapshots(_ rest: [String]) -> AgentCLIParseOutcome {
        switch rest.first {
        case "list":
            return rest.count == 1 ? .command(.snapshotsList) : .invalid("用法: snapshots list")
        case "capture":
            let name = flagValue(Array(rest.dropFirst()), "--name")
            return .command(.snapshotCapture(name: name))
        case "restore":
            let id = flagValue(Array(rest.dropFirst()), "--id")
            return .command(.snapshotRestore(id: id))
        default:
            return .invalid("未知 snapshots 子命令")
        }
    }

    private static func parseGridCreate(_ rest: [String]) -> AgentCLIParseOutcome {
        let rows = flagValue(rest, "--rows").flatMap(Int.init)
        let cols = flagValue(rest, "--cols").flatMap(Int.init)
        if flagValue(rest, "--rows") != nil && rows == nil { return .invalid("--rows 必须是整数") }
        if flagValue(rest, "--cols") != nil && cols == nil { return .invalid("--cols 必须是整数") }
        return .command(.gridCreate(rows: rows, cols: cols))
    }

    private static func parseNotify(_ rest: [String]) -> AgentCLIParseOutcome {
        guard let text = flagValue(rest, "--text"), !text.isEmpty else {
            return .invalid("notify 需要 --text <文本>")
        }
        return .command(.notify(text: text, title: flagValue(rest, "--title")))
    }

    /// settings get | settings set --key K --value V
    private static func parseSettings(_ rest: [String]) -> AgentCLIParseOutcome {
        switch rest.first {
        case "get":
            return rest.count == 1 ? .command(.settingsGet) : .invalid("用法: settings get")
        case "set":
            guard let key = flagValue(Array(rest.dropFirst()), "--key"),
                  let value = flagValue(Array(rest.dropFirst()), "--value") else {
                return .invalid("用法: settings set --key <键> --value <值>（值按 true/false/整数/小数/字符串 解析）")
            }
            return .command(.settingsSet(key: key, value: value))
        default:
            return .invalid("未知 settings 子命令")
        }
    }

    /// CLI 值字面量 → JSON 值：true/false→Bool、整数→Int、小数→Double、其余字符串。
    static func parseCLIValue(_ raw: String) -> Any {
        if raw == "true" { return true }
        if raw == "false" { return false }
        if let n = Int(raw) { return n }
        if let d = Double(raw) { return d }
        return raw
    }

    private static func parseSpaceSwitch(_ rest: [String]) -> AgentCLIParseOutcome {
        guard let raw = flagValue(rest, "--space"), let space = Int(raw), space >= 1 else {
            return .invalid("space switch 需要 --space <N>（1 起）")
        }
        return .command(.spaceSwitch(space: space))
    }

    static func flagValue(_ args: [String], _ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), args.count > i + 1 else { return nil }
        return args[i + 1]
    }
}

// MARK: - 退出码映射（纯函数，Runner 直测）

enum AgentCLIExitCode {
    static let ok: Int32 = 0
    static let usage: Int32 = 2
    static let appUnreachable: Int32 = 3
    static let unauthorized: Int32 = 4
    static let forbidden: Int32 = 5
    static let operationFailed: Int32 = 6

    /// curl 执行结果 + HTTP 状态 → 退出码。
    static func resolve(transportFailed: Bool, httpStatus: Int) -> Int32 {
        if transportFailed { return appUnreachable }
        switch httpStatus {
        case 200: return ok
        case 401: return unauthorized
        case 403: return forbidden
        default: return operationFailed
        }
    }
}

// MARK: - 连接配置

public enum AgentCLIConnection {
    public struct Config: Equatable {
        public let port: Int
        public let token: String?
    }

    /// 凭据单一事实源与 hook 一致：① CFPreferences（AppIdentity.bundleID 域，与
    /// RemoteInstallDeploy 同款直读）；② ~/.vibefocus/hook-config.json 兜底。
    /// preferCFPreferences=false 供 Runner 回环测试注入（跳过①——CFPreferences 是
    /// 跨进程共享域，测试进程里直读会打到真实生产端口；生产路径恒走①）。
    public static func load(home: String = NSHomeDirectory(), preferCFPreferences: Bool = true) -> Config {
        let prefPort = preferCFPreferences
            ? CFPreferencesCopyAppValue(ClaudeHookPreferences.portKey as CFString, AppIdentity.bundleID as CFString) as? Int
            : nil
        let prefToken = preferCFPreferences
            ? CFPreferencesCopyAppValue("claudeHookToken" as CFString, AppIdentity.bundleID as CFString) as? String
            : nil
        if let port = prefPort, port >= 1024 {
            return Config(port: port, token: (prefToken?.isEmpty ?? true) ? nil : prefToken)
        }
        // 兜底：hook-config.json {"port":...,"token":...}
        let path = (home as NSString).appendingPathComponent(".vibefocus/hook-config.json")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let port = json["port"] as? Int, port >= 1024 {
            let token = json["token"] as? String
            return Config(port: port, token: (token?.isEmpty ?? true) ? nil : token)
        }
        return Config(port: ClaudeHookPreferences.defaultPort, token: prefToken)
    }
}

// MARK: - 执行器

public enum AgentCLI {
    /// 即退式执行。返回进程退出码。stdout 只放 JSON（机器读），stderr 放人读消息。
    public static func run(_ command: AgentCLICommand, home: String = NSHomeDirectory(), preferCFPreferences: Bool = true) -> Int32 {
        switch command {
        case .windowsList(let includeAll):
            return runWindowsList(includeAll: includeAll)
        case .sessionsList:
            return runSessionsList(home: home)
        default:
            return runViaAPI(command, home: home, preferCFPreferences: preferCFPreferences)
        }
    }

    // 本地直读：CG 窗口列表（免 AX、免 App 在跑）。默认只给「人眼可见」的
    // 常规窗口（onScreen + 最短边 ≥80px，滤掉输入法候选条/服务浮层类噪声），
    // --all 看全量——agent 感知的默认口径应是「屏幕上真正存在的窗」。
    private static func runWindowsList(includeAll: Bool) -> Int32 {
        let entries = cgWindowListAll().filter { $0.layer == 0 }.filter { e in
            guard !includeAll else { return true }
            guard e.isOnScreen, let b = e.bounds else { return false }
            return b.width >= 80 && b.height >= 80
        }
        let rows: [[String: Any]] = entries.map { e in
            var d: [String: Any] = ["windowId": e.windowID, "pid": e.ownerPID, "isOnScreen": e.isOnScreen]
            if let app = e.ownerName { d["app"] = app }
            if let title = e.name { d["title"] = title }
            if let b = e.bounds {
                d["x"] = b.origin.x; d["y"] = b.origin.y
                d["width"] = b.width; d["height"] = b.height
            }
            return d
        }
        printJSON(["count": rows.count, "windows": rows])
        return AgentCLIExitCode.ok
    }

    // 本地直读：session-activity.json（App 侧持久化的会话活动快照）。
    private static func runSessionsList(home: String) -> Int32 {
        let path = (home as NSString).appendingPathComponent(".vibefocus/session-activity.json")
        let activities: [String: SessionActivity]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let parsed = SessionActivityTracker.parseActivities(data: data) {
            activities = parsed
        } else {
            activities = [:]
        }
        let df = ISO8601DateFormatter()
        let rows: [[String: Any]] = activities.map { sessionID, activity in
            [
                "sessionId": sessionID,
                "lastEvent": activity.lastEvent.rawValue,
                "lastAt": df.string(from: activity.at)
            ]
        }
        printJSON(["count": rows.count, "sessions": rows])
        return AgentCLIExitCode.ok
    }

    // 转发通道：curl → 127.0.0.1:<port>/api/v1/*（token header）。
    private static func runViaAPI(_ command: AgentCLICommand, home: String, preferCFPreferences: Bool = true) -> Int32 {
        guard let endpoint = command.apiEndpoint else {
            FileHandle.standardError.write(Data("internal: no endpoint for command\n".utf8))
            return AgentCLIExitCode.usage
        }
        let config = AgentCLIConnection.load(home: home, preferCFPreferences: preferCFPreferences)
        var curlArgs = [
            "-s", "--max-time", "30",
            "-X", endpoint.method,
            "-H", "X-VibeFocus-Token: \(config.token ?? "")",
            "-w", "\n%{http_code}"
        ]
        let bodyData = command.apiBody.isEmpty
            ? nil
            : (try? JSONSerialization.data(withJSONObject: command.apiBody))
        if let bodyData, let body = String(data: bodyData, encoding: .utf8) {
            curlArgs += ["-H", "Content-Type: application/json", "-d", body]
        }
        curlArgs.append("http://127.0.0.1:\(config.port)\(endpoint.path)")

        let result = ShellRunner.run(executable: "/usr/bin/curl", arguments: curlArgs, timeout: 35)
        guard let result else {
            FileHandle.standardError.write(Data("VibeFocus app 不可达（未在运行？）\n".utf8))
            return AgentCLIExitCode.appUnreachable
        }
        // curl -w 把状态码追加在最后一行；分离 JSON 体与状态码。
        let output = result.stdout
        var jsonPart = output
        var statusPart = ""
        if let lastNewline = output.lastIndex(of: "\n") {
            statusPart = String(output[output.index(after: lastNewline)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            jsonPart = String(output[..<lastNewline])
        }
        let httpStatus = Int(statusPart) ?? (result.exitCode == 0 ? 500 : 0)
        if !jsonPart.isEmpty { print(jsonPart) }
        if result.exitCode != 0 {
            FileHandle.standardError.write(Data("VibeFocus app 不可达（curl exit \(result.exitCode)）\n".utf8))
            return AgentCLIExitCode.appUnreachable
        }
        let code = AgentCLIExitCode.resolve(transportFailed: false, httpStatus: httpStatus)
        if code != AgentCLIExitCode.ok, jsonPart.isEmpty {
            FileHandle.standardError.write(Data("HTTP \(httpStatus)\n".utf8))
        }
        return code
    }

    private static func printJSON(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            print(s)
        }
    }
}
