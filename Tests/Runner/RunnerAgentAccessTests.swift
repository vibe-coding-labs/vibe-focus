// Tests/Runner/RunnerAgentAccessTests.swift — Agent 接入纯判定层直测（design-agent-access.md）
// 覆盖：AgentAccessGate 授权矩阵、AgentApiEndpoint 路由表与分级语义、
// AgentApiRequestDecoder 参数钳制、AgentWindowListing 感知列表构建、
// AgentCLIRouter 解析 / AgentCLIExitCode 退出码、MCPProtocol JSON-RPC 路由与工具调用。
// IO（HTTP 壳/curl/stdio 循环）归真机 E2E；渲染走 body 求值（B255 先例）。

import AppKit
import CoreGraphics
import Foundation
@testable import VibeFocusKit

extension RunnerHarness {
    func runAgentAccessTests() {

        // ===== A. 授权门矩阵（总开关 × 子开关 × 三级） =====
        do {
            let off = AgentAccessPreferences.Snapshot(enabled: false, allowWindowOps: false, allowCreateWindows: false)
            let l0 = AgentAccessPreferences.Snapshot(enabled: true, allowWindowOps: false, allowCreateWindows: false)
            let l1 = AgentAccessPreferences.Snapshot(enabled: true, allowWindowOps: true, allowCreateWindows: false)
            let l2 = AgentAccessPreferences.Snapshot(enabled: true, allowWindowOps: true, allowCreateWindows: true)

            check("gate: 总开关关→L0 读也拒", !AgentAccessGate.isTierAllowed(.read, prefs: off))
            check("gate: 总开关关→拒绝码 agent_access_disabled", AgentAccessGate.denialCode(prefs: off) == "agent_access_disabled")
            check("gate: 只开总开关→L0 放行", AgentAccessGate.isTierAllowed(.read, prefs: l0))
            check("gate: 只开总开关→L1 拒", !AgentAccessGate.isTierAllowed(.windowOps, prefs: l0))
            check("gate: 只开总开关→L2 拒", !AgentAccessGate.isTierAllowed(.createWindows, prefs: l0))
            check("gate: 只开总开关→拒绝码 agent_writes_disabled", AgentAccessGate.denialCode(prefs: l0) == "agent_writes_disabled")
            check("gate: 开 L1→L1 放行", AgentAccessGate.isTierAllowed(.windowOps, prefs: l1))
            check("gate: 开 L1→L2 仍拒", !AgentAccessGate.isTierAllowed(.createWindows, prefs: l1))
            check("gate: 开 L1 缺 L2→拒绝码 create_windows_disabled", AgentAccessGate.denialCode(prefs: l1) == "create_windows_disabled")
            check("gate: 开 L2 缺 L1→拒绝码 window_ops_disabled", AgentAccessGate.denialCode(prefs: AgentAccessPreferences.Snapshot(enabled: true, allowWindowOps: false, allowCreateWindows: true)) == "window_ops_disabled")
            check("gate: L1+L2 全开→L2 放行", AgentAccessGate.isTierAllowed(.createWindows, prefs: l2))
            check("gate: 子开关不越总开关（关总开+开 L2）", !AgentAccessGate.isTierAllowed(.read, prefs: AgentAccessPreferences.Snapshot(enabled: false, allowWindowOps: true, allowCreateWindows: true)))
        }

        // ===== B. 端点路由表与分级语义 =====
        do {
            check("routes: 共 13 端点", AgentApiEndpoint.all.count == 13)
            let combos = AgentApiEndpoint.all.map { "\($0.method) \($0.path)" }
            check("routes: 无重复 method+path", Set(combos).count == combos.count)
            check("routes: 全部走 /api/v1 前缀", AgentApiEndpoint.all.allSatisfy { $0.path.hasPrefix("/api/v1/") })
            let gets = AgentApiEndpoint.all.filter { $0.method == "GET" }
            check("routes: GET 全为 L0 读", gets.count == 4 && gets.allSatisfy { $0.tier == .read })
            let l2paths = AgentApiEndpoint.all.filter { $0.tier == .createWindows }.map(\.path)
            check("routes: L2 恰为 grid/create 与 snapshots/restore", Set(l2paths) == ["/api/v1/grid/create", "/api/v1/snapshots/restore"])
            check("routes: 其余 POST 全为 L1", AgentApiEndpoint.all.filter { $0.method == "POST" && $0.tier == .windowOps }.count == 7)

            check("routes: match 命中", AgentApiEndpoint.match(method: "POST", path: "/api/v1/windows/move-main")?.tier == .windowOps)
            check("routes: 方法不匹配不命中", AgentApiEndpoint.match(method: "GET", path: "/api/v1/windows/move-main") == nil)
            check("routes: hook 老端点不在 API 表内", AgentApiEndpoint.match(method: "POST", path: "/claude/hook") == nil)
        }

        // ===== C. 参数解码与钳制 =====
        do {
            check("decode: 缺 body → 空对象", AgentApiRequestDecoder.parseJSONObject(nil)?.isEmpty == true)
            check("decode: 非法 JSON → nil", AgentApiRequestDecoder.parseJSONObject(Data("not-json".utf8)) == nil)

            check("decode: windowId 合法", AgentApiRequestDecoder.decodeWindowID(["windowId": 3220]) == 3220)
            check("decode: windowId 零拒绝", AgentApiRequestDecoder.decodeWindowID(["windowId": 0]) == nil)
            check("decode: windowId 负数拒绝", AgentApiRequestDecoder.decodeWindowID(["windowId": -5]) == nil)
            check("decode: windowId 缺失拒绝", AgentApiRequestDecoder.decodeWindowID([:]) == nil)

            check("decode: float 缺 on 拒绝", AgentApiRequestDecoder.decodeFloat(["windowId": 1]) == nil)
            check("decode: float 合法", AgentApiRequestDecoder.decodeFloat(["windowId": 7, "on": true])?.on == true)

            check("decode: layout 合法 preset", AgentApiRequestDecoder.decodeLayout(["preset": "leftHalf"]) == .leftHalf)
            check("decode: layout 非法 preset 拒绝", AgentApiRequestDecoder.decodeLayout(["preset": "evil"]) == nil)

            check("decode: notify 空文本拒绝", AgentApiRequestDecoder.decodeNotify(["text": "   "]) == nil)
            check("decode: notify 非文本拒绝", AgentApiRequestDecoder.decodeNotify(["text": 42]) == nil)
            check("decode: notify 去首尾空格", AgentApiRequestDecoder.decodeNotify(["text": " hi "])?.text == "hi")
            check("decode: notify 空标题归 nil", AgentApiRequestDecoder.decodeNotify(["text": "hi", "title": "  "])?.title == nil)
            check("decode: notify 超长拒绝", AgentApiRequestDecoder.decodeNotify(["text": String(repeating: "x", count: 2001)]) == nil)

            check("decode: space 0 拒绝", AgentApiRequestDecoder.decodeSpaceSwitch(["space": 0]) == nil)
            check("decode: space 65 拒绝", AgentApiRequestDecoder.decodeSpaceSwitch(["space": 65]) == nil)
            check("decode: space 合法", AgentApiRequestDecoder.decodeSpaceSwitch(["space": 3]) == 3)

            check("decode: grid 行列缺省放行", AgentApiRequestDecoder.decodeGridCreate([:])?.rows == nil && AgentApiRequestDecoder.decodeGridCreate([:])?.cols == nil)
            check("decode: grid 合法覆盖", AgentApiRequestDecoder.decodeGridCreate(["rows": 2, "cols": 3])?.rows == 2 && AgentApiRequestDecoder.decodeGridCreate(["rows": 2, "cols": 3])?.cols == 3)
            check("decode: grid 行 0 拒绝", AgentApiRequestDecoder.decodeGridCreate(["rows": 0]) == nil)
            check("decode: grid 行 9 拒绝", AgentApiRequestDecoder.decodeGridCreate(["rows": 9]) == nil)
            check("decode: grid 列 8 边界放行", AgentApiRequestDecoder.decodeGridCreate(["cols": 8])?.rows == nil && AgentApiRequestDecoder.decodeGridCreate(["cols": 8])?.cols == 8)

            check("decode: capture 空名归 nil", AgentApiRequestDecoder.decodeSnapshotCapture(["name": "  "]) == nil)
            check("decode: capture 长名截 80", AgentApiRequestDecoder.decodeSnapshotCapture(["name": String(repeating: "a", count: 100)])?.count == 80)
            check("decode: restore 空 id 归 nil", AgentApiRequestDecoder.decodeSnapshotRestore(["id": ""]) == nil)
        }

        // ===== D. 感知列表构建 =====
        do {
            func entry(id: UInt32, pid: Int32, layer: Int, name: String?, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, onScreen: Bool) -> CGWindowEntry {
                let dict: [String: Any] = [
                    "kCGWindowNumber": id,
                    "kCGWindowOwnerPID": pid,
                    "kCGWindowOwnerName": "Terminal",
                    "kCGWindowLayer": layer,
                    "kCGWindowBounds": ["X": x, "Y": y, "Width": w, "Height": h] as [String: CGFloat],
                    "kCGWindowIsOnscreen": onScreen,
                    "name": name as Any
                ]
                return CGWindowEntry(from: dict)!
            }
            let mainScreen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
            let summaries = AgentWindowListing.summaries(
                from: [
                    entry(id: 1, pid: 100, layer: 0, name: "zed", x: 10, y: 10, w: 800, h: 600, onScreen: true),
                    entry(id: 2, pid: 100, layer: 25, name: "menu", x: 0, y: 0, w: 1728, h: 24, onScreen: true),
                    entry(id: 3, pid: 200, layer: 0, name: "offscreen", x: 5000, y: 5000, w: 800, h: 600, onScreen: false)
                ],
                mainScreenFrame: mainScreen,
                sessionLookup: { $0 == 1 ? "sess-abc" : nil }
            )
            check("listing: layer!=0 被滤", summaries.count == 2)
            check("listing: 绑定 join 命中", summaries.first { $0.windowID == 1 }?.sessionID == "sess-abc")
            check("listing: 无绑定为 nil", summaries.first { $0.windowID == 3 }?.sessionID == nil)
            check("listing: 中心点在主屏判定", summaries.first { $0.windowID == 1 }?.onMainScreen == true)
            check("listing: 副屏窗 onMain=false", summaries.first { $0.windowID == 3 }?.onMainScreen == false)
            check("listing: 无主屏框全部 false", AgentWindowListing.summaries(from: [entry(id: 9, pid: 1, layer: 0, name: nil, x: 1, y: 1, w: 100, h: 100, onScreen: true)], mainScreenFrame: nil, sessionLookup: { _ in nil }).allSatisfy { !$0.onMainScreen })
        }

        // ===== E. CLI 解析与退出码 =====
        do {
            check("cli: 空参数=notOurs", AgentCLIRouter.parse([]) == .notOurs)
            check("cli: 旧旗标=notOurs", AgentCLIRouter.parse(["--diagnose"]) == .notOurs)
            check("cli: 随机词=notOurs", AgentCLIRouter.parse(["bogus"]) == .notOurs)
            check("cli: status 合法", AgentCLIRouter.parse(["status"]) == .command(.status))
            check("cli: status 带参=invalid", AgentCLIRouter.parse(["status", "x"]) == .invalid("status 不接受参数"))
            check("cli: windows list 合法", AgentCLIRouter.parse(["windows", "list"]) == .command(.windowsList(includeAll: false)))
            check("cli: windows list --all", AgentCLIRouter.parse(["windows", "list", "--all"]) == .command(.windowsList(includeAll: true)))
            check("cli: move-main 合法", AgentCLIRouter.parse(["windows", "move-main", "--id", "3220"]) == .command(.moveMain(windowID: 3220)))
            check("cli: move-main 缺 id=invalid", AgentCLIRouter.parse(["windows", "move-main"]) != .command(.moveMain(windowID: 1)))
            check("cli: float on", AgentCLIRouter.parse(["windows", "float", "--id", "7", "--on"]) == .command(.float(windowID: 7, on: true)))
            check("cli: float 缺开关=invalid", AgentCLIRouter.parse(["windows", "float", "--id", "7"]) != .command(.float(windowID: 7, on: true)))
            check("cli: layout 合法", AgentCLIRouter.parse(["windows", "layout", "--preset", "leftHalf"]) == .command(.layout(preset: "leftHalf")))
            check("cli: sessions list", AgentCLIRouter.parse(["sessions", "list"]) == .command(.sessionsList))
            check("cli: snapshots capture", AgentCLIRouter.parse(["snapshots", "capture", "--name", "t"]) == .command(.snapshotCapture(name: "t")))
            check("cli: snapshots restore 缺省", AgentCLIRouter.parse(["snapshots", "restore"]) == .command(.snapshotRestore(id: nil)))
            check("cli: grid create 行列", AgentCLIRouter.parse(["grid", "create", "--rows", "2", "--cols", "3"]) == .command(.gridCreate(rows: 2, cols: 3)))
            check("cli: grid 行非整数=invalid", AgentCLIRouter.parse(["grid", "create", "--rows", "x"]) != .command(.gridCreate(rows: 1, cols: nil)))
            check("cli: notify 合法", AgentCLIRouter.parse(["notify", "--text", "hi", "--title", "t"]) == .command(.notify(text: "hi", title: "t")))
            check("cli: notify 缺文本=invalid", AgentCLIRouter.parse(["notify", "--title", "t"]) != .command(.notify(text: "x", title: nil)))
            check("cli: space switch", AgentCLIRouter.parse(["space", "switch", "--space", "2"]) == .command(.spaceSwitch(space: 2)))
            check("cli: space 0=invalid", AgentCLIRouter.parse(["space", "switch", "--space", "0"]) != .command(.spaceSwitch(space: 2)))

            // 写类命令带 API 端点；直读类不带
            check("cli: 直读命令无端点", AgentCLICommand.windowsList(includeAll: false).apiEndpoint == nil && AgentCLICommand.sessionsList.apiEndpoint == nil)
            check("cli: moveMain 端点指向 move-main", AgentCLICommand.moveMain(windowID: 1).apiEndpoint?.path == "/api/v1/windows/move-main")
            check("cli: moveMain body 带 windowId", AgentCLICommand.moveMain(windowID: 9).apiBody["windowId"] as? Int == 9)
            check("cli: float body 双参", AgentCLICommand.float(windowID: 9, on: false).apiBody["on"] as? Bool == false)

            check("exit: 200→0", AgentCLIExitCode.resolve(transportFailed: false, httpStatus: 200) == 0)
            check("exit: 传输失败→3", AgentCLIExitCode.resolve(transportFailed: true, httpStatus: 0) == 3)
            check("exit: 401→4", AgentCLIExitCode.resolve(transportFailed: false, httpStatus: 401) == 4)
            check("exit: 403→5", AgentCLIExitCode.resolve(transportFailed: false, httpStatus: 403) == 5)
            check("exit: 409→6", AgentCLIExitCode.resolve(transportFailed: false, httpStatus: 409) == 6)
        }

        // ===== F. MCP 协议路由与工具调用 =====
        do {
            func jsonDict(_ data: Data?) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any] ?? [:] }
            func fakeAPI(method: String, path: String, body: Data?) -> (Int, Data) {
                (200, AgentApiResponseBuilder.body(ok: true, code: "ok", message: "", data: ["echo": path]))
            }

            check("mcp: 非法 JSON→parse error", jsonDict(MCPProtocol.handleMessage(Data("junk".utf8), performAPI: fakeAPI))["error"] != nil)
            let initResp = jsonDict(MCPProtocol.handleMessage(Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}".utf8), performAPI: fakeAPI))
            check("mcp: initialize 回 serverInfo", (initResp["result"] as? [String: Any])?["serverInfo"] != nil)
            check("mcp: initialized 通知不回包", MCPProtocol.handleMessage(Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}".utf8), performAPI: fakeAPI) == nil)
            let listResp = jsonDict(MCPProtocol.handleMessage(Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}".utf8), performAPI: fakeAPI))
            let tools = (listResp["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
            check("mcp: tools/list 13 个工具", tools.count == 13)
            check("mcp: 工具 schema 含 name/description/inputSchema", tools.allSatisfy { $0["name"] != nil && $0["description"] != nil && $0["inputSchema"] != nil })
            check("mcp: ping 回空 result", jsonDict(MCPProtocol.handleMessage(Data("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}".utf8), performAPI: fakeAPI))["result"] != nil)
            check("mcp: 未知方法→methodNotFound", (jsonDict(MCPProtocol.handleMessage(Data("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"evil\"}".utf8), performAPI: fakeAPI))["error"] as? [String: Any])?["code"] as? Int == -32601)

            // tools/call：缺必填 / 未知工具 / 白名单 / 成功与失败
            var capturedPath = ""
            var capturedBody: Data?
            let spyAPI: (String, String, Data?) -> (Int, Data) = { _, path, body in
                capturedPath = path
                capturedBody = body
                return (200, AgentApiResponseBuilder.body(ok: true, code: "ok", message: ""))
            }
            let missing = MCPProtocol.handleToolCall(params: ["name": "vibefocus_window_move_main", "arguments": [:]], performAPI: spyAPI)
            check("mcp: 必填缺失→isError", missing.isError)
            let unknown = MCPProtocol.handleToolCall(params: ["name": "vibefocus_hack"], performAPI: spyAPI)
            check("mcp: 未知工具→isError", unknown.isError)
            let okCall = MCPProtocol.handleToolCall(params: ["name": "vibefocus_window_move_main", "arguments": ["windowId": 9, "extra": "x"]], performAPI: spyAPI)
            check("mcp: 合法调用指向正确端点", capturedPath == "/api/v1/windows/move-main" && !okCall.isError)
            check("mcp: 参数白名单透传（多余键被滤）", (jsonDict(capturedBody!)["windowId"] as? Int) == 9 && jsonDict(capturedBody!)["extra"] == nil)
            var deniedStatus = 0
            let deniedAPI: (String, String, Data?) -> (Int, Data) = { _, _, _ in
                deniedStatus += 1
                return (403, AgentApiResponseBuilder.body(ok: false, code: "agent_writes_disabled", message: ""))
            }
            let denied = MCPProtocol.handleToolCall(params: ["name": "vibefocus_notify", "arguments": ["text": "hi"]], performAPI: deniedAPI)
            check("mcp: 403 落工具错误（host 可感知授权关）", denied.isError && deniedStatus == 1)
        }

        // ===== G. 设置页 body 求值三态（B255 先例；defaults save/restore） =====
        do {
            let view = SettingsView()
            let savedEnabled = AgentAccessPreferences.isEnabled
            let savedWindowOps = AgentAccessPreferences.allowWindowOps
            let savedCreate = AgentAccessPreferences.allowCreateWindows
            defer {
                AgentAccessPreferences.isEnabled = savedEnabled
                AgentAccessPreferences.allowWindowOps = savedWindowOps
                AgentAccessPreferences.allowCreateWindows = savedCreate
            }

            AgentAccessPreferences.isEnabled = false
            _ = view.agentAccessSection
            check("renderAgent: 全关态 body 求值零崩溃", true)

            AgentAccessPreferences.isEnabled = true
            AgentAccessPreferences.allowWindowOps = true
            _ = view.agentAccessSection
            check("renderAgent: 总开关+L1 态 body 求值零崩溃", true)

            AgentAccessPreferences.allowCreateWindows = true
            _ = view.agentAccessSection
            check("renderAgent: 全开态 body 求值零崩溃", true)
        }
    }
}
