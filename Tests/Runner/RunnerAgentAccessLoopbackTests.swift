import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerAgentAccessLoopbackTests.swift — Agent 命令 API HTTP 壳回环直测
// （B154 hookSrv 家法：真实 GCDWebServer 起服 + HTTP 打环回；此前 +API.swift 110 行
// handler 层零覆盖）。覆盖：token 门/404/四级授权门（disabled/writes-off/create-off）、
// 参数 400 族、幽灵目标的 404/409 分支、notify 在无 bundle 进程的 409 分支，
// 以及 AgentCLI runViaAPI 的退出码全家族（0/3/4/5/6）经真实 curl 打环。
//
// 红线（真机域留白）：①严禁 applyPreferences（写真实 ~/.vibefocus）；②L2 端点
// （grid/create、snapshots/restore）只在授权关态验证 403——绝不真建网格/恢复布局；
// ③layout 合法 preset 会真摆用户前台窗——只验 400 分支；④snapshots/capture 真跑
// 会写真实 DB——不 POST。

extension RunnerHarness {
    func runAgentAccessLoopbackTests() {
        final class HTTPResult: @unchecked Sendable {
            var status = -1
            var ok: Bool?
            var code: String?
        }
        func http(_ method: String, _ port: Int, _ path: String, token: String?, body: String? = nil) -> HTTPResult {
            let res = HTTPResult()
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            req.httpMethod = method
            if let body { req.httpBody = Data(body.utf8) }
            if let token { req.setValue(token, forHTTPHeaderField: "X-VibeFocus-Token") }
            req.timeoutInterval = 5
            let sem = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                res.status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    res.ok = obj["ok"] as? Bool
                    res.code = obj["code"] as? String
                }
                sem.signal()
            }.resume()
            // 短片等待 + 泵主 RunLoop：handler 在 MainActor，长阻塞 wait 会饿死它（B154 实测）。
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if sem.wait(timeout: .now() + 0.05) == .success { break }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return res
        }

        let savedLAN = LANHookPreferences.lanMode
        let savedEnabled = AgentAccessPreferences.isEnabled
        let savedWindowOps = AgentAccessPreferences.allowWindowOps
        let savedCreate = AgentAccessPreferences.allowCreateWindows
        defer {
            LANHookPreferences.lanMode = savedLAN
            AgentAccessPreferences.isEnabled = savedEnabled
            AgentAccessPreferences.allowWindowOps = savedWindowOps
            AgentAccessPreferences.allowCreateWindows = savedCreate
            ClaudeHookServer.shared.stop()
        }
        LANHookPreferences.lanMode = false

        var port = 40000 + Int.random(in: 0..<20000)
        var tries = 0
        while tries < 4 {
            ClaudeHookServer.shared.startIfNeeded(port: port, token: "tk-agent-loopback")
            if ClaudeHookServer.shared.isRunning { break }
            port = 40000 + Int.random(in: 0..<20000)
            tries += 1
        }
        check("loop: 回环起服成功", ClaudeHookServer.shared.isRunning)
        guard ClaudeHookServer.shared.isRunning else { return }

        // MARK: §1 token 门与 404
        do {
            let noToken = http("GET", port, "/api/v1/status", token: nil)
            check("loop: 无 token→401", noToken.status == 401 && noToken.code == "unauthorized")
            let badPath = http("GET", port, "/api/v1/evil", token: "tk-agent-loopback")
            // 未注册路径由 GCDWebServer 自身应答 501（实证两次，其 unmatched-request
            // 约定），无我的 JSON 信封——handler 内 404 分支是纵深防御，HTTP 面不可达。
            check("loop: 未知端点→GCDWebServer 501", badPath.status == 501)
            let wrongMethod = http("GET", port, "/api/v1/windows/move-main", token: "tk-agent-loopback")
            check("loop: 方法不匹配→GCDWebServer 501", wrongMethod.status == 501)
        }

        // MARK: §2 全关：读也被拒，拒绝码分层
        do {
            AgentAccessPreferences.isEnabled = false
            AgentAccessPreferences.allowWindowOps = false
            AgentAccessPreferences.allowCreateWindows = false
            let s = http("GET", port, "/api/v1/status", token: "tk-agent-loopback")
            check("loop: 全关→GET status 403 agent_access_disabled",
                  s.status == 403 && s.code == "agent_access_disabled")
            let g = http("POST", port, "/api/v1/grid/create", token: "tk-agent-loopback", body: "{}")
            check("loop: 全关→grid 403", g.status == 403 && g.code == "agent_access_disabled")
        }

        // MARK: §3 只开总开关（L0）：读放行、写分层拒
        do {
            AgentAccessPreferences.isEnabled = true
            AgentAccessPreferences.allowWindowOps = false
            AgentAccessPreferences.allowCreateWindows = false
            let s = http("GET", port, "/api/v1/status", token: "tk-agent-loopback")
            check("loop: L0→status 200 且含 agentAccess 块", s.status == 200 && s.ok == true)
            let w = http("GET", port, "/api/v1/windows", token: "tk-agent-loopback")
            check("loop: L0→windows 200", w.status == 200 && w.ok == true)
            let sess = http("GET", port, "/api/v1/sessions", token: "tk-agent-loopback")
            check("loop: L0→sessions 200", sess.status == 200 && sess.ok == true)
            let snaps = http("GET", port, "/api/v1/snapshots", token: "tk-agent-loopback")
            check("loop: L0→snapshots 200", snaps.status == 200 && snaps.ok == true)
            let settings = http("GET", port, "/api/v1/settings", token: "tk-agent-loopback")
            check("loop: L0→settings 200", settings.status == 200 && settings.ok == true)

            let mv = http("POST", port, "/api/v1/windows/move-main", token: "tk-agent-loopback", body: "{\"windowId\":1}")
            check("loop: 只开读→写 403 agent_writes_disabled", mv.status == 403 && mv.code == "agent_writes_disabled")
            let nt = http("POST", port, "/api/v1/notify", token: "tk-agent-loopback", body: "{\"text\":\"hi\"}")
            check("loop: 只开读→notify 403", nt.status == 403)
            let gw = http("POST", port, "/api/v1/grid/create", token: "tk-agent-loopback", body: "{}")
            check("loop: 只开读→L2 403 agent_writes_disabled", gw.status == 403 && gw.code == "agent_writes_disabled")
        }

        // MARK: §4 L1 开：参数 400 族 + 幽灵目标 404/409 分支
        do {
            AgentAccessPreferences.allowWindowOps = true
            AgentAccessPreferences.allowCreateWindows = false

            let noID = http("POST", port, "/api/v1/windows/move-main", token: "tk-agent-loopback", body: "{}")
            check("loop: move-main 缺 windowId→400", noID.status == 400 && noID.code == "bad_request")
            let ghostMove = http("POST", port, "/api/v1/windows/move-main", token: "tk-agent-loopback", body: "{\"windowId\":4000000000}")
            check("loop: move-main 幽灵窗→404 window_not_found", ghostMove.status == 404 && ghostMove.code == "window_not_found")

            let floatNoOn = http("POST", port, "/api/v1/windows/float", token: "tk-agent-loopback", body: "{\"windowId\":4000000000}")
            check("loop: float 缺 on→400", floatNoOn.status == 400)
            let ghostFloat = http("POST", port, "/api/v1/windows/float", token: "tk-agent-loopback", body: "{\"windowId\":4000000000,\"on\":true}")
            check("loop: float 幽灵窗→409 float_failed", ghostFloat.status == 409 && ghostFloat.code == "float_failed")

            let badPreset = http("POST", port, "/api/v1/windows/layout", token: "tk-agent-loopback", body: "{\"preset\":\"evil\"}")
            check("loop: layout 非法 preset→400", badPreset.status == 400 && badPreset.code == "bad_request")
            // 合法 preset 会真摆用户前台窗（真机域）——刻意不 POST。

            let emptyNotify = http("POST", port, "/api/v1/notify", token: "tk-agent-loopback", body: "{\"text\":\"  \"}")
            check("loop: notify 空文本→400", emptyNotify.status == 400)
            let notify = http("POST", port, "/api/v1/notify", token: "tk-agent-loopback", body: "{\"text\":\"loopback 测试\"}")
            check("loop: notify 合法→Runner 无 bundle id 通知器短路 409",
                  notify.status == 409 && notify.code == "notify_failed")

            let space0 = http("POST", port, "/api/v1/space/switch", token: "tk-agent-loopback", body: "{\"space\":0}")
            check("loop: space 0→400", space0.status == 400)
            let ghostSpace = http("POST", port, "/api/v1/space/switch", token: "tk-agent-loopback", body: "{\"space\":64}")
            check("loop: 幽灵 space→不崩溃（200/409 随 yabai 态）",
                  ghostSpace.status == 200 || ghostSpace.status == 409)

            // L2 只在关态验证（开态真执行 = 真机域留白）
            let restore = http("POST", port, "/api/v1/snapshots/restore", token: "tk-agent-loopback", body: "{}")
            check("loop: L1 开 L2 关→restore 403 create_windows_disabled",
                  restore.status == 403 && restore.code == "create_windows_disabled")
        }

        // MARK: §5 AgentCLI runViaAPI 经真实 curl 打环（退出码全家族）
        // ⚠️curl 同步阻塞所在线程，而 server handler 在主线程——必须在后台线程跑
        // CLI、主线程泵 RunLoop 应答（同线程必死锁：curl 30s 超时 exit 28，实测）。
        do {
            let tmp = NSTemporaryDirectory() + "vf-agentcli-\(UUID().uuidString.prefix(8))"
            try? FileManager.default.createDirectory(atPath: tmp + "/.vibefocus", withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmp) }
            func writeConfig(port: Int, token: String?) {
                var obj: [String: Any] = ["port": port]
                if let token { obj["token"] = token }
                let data = try! JSONSerialization.data(withJSONObject: obj)
                try! data.write(to: URL(fileURLWithPath: tmp + "/.vibefocus/hook-config.json"))
            }
            // 后台执行 + 主泵等待（server handler 要主线程）。返回各命令退出码。
            // 锁盒收集：@Sendable 闭包内不裸改捕获变量（零警告门禁）。
            final class ResultBox: @unchecked Sendable {
                private var values: [Int32] = []
                private let lock = NSLock()
                func append(_ v: Int32) { lock.lock(); values.append(v); lock.unlock() }
                func snapshot() -> [Int32] { lock.lock(); defer { lock.unlock() }; return values }
            }
            func runBG(_ commands: [AgentCLICommand]) -> [Int32] {
                // 每次调用新盒——跨调用累积会把 first 错位到旧值（实测 6 连红根因）。
                let box = ResultBox()
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .default).async {
                    for c in commands { box.append(AgentCLI.run(c, home: tmp, preferCFPreferences: false)) }
                    sem.signal()
                }
                let deadline = Date().addingTimeInterval(90)
                while Date() < deadline {
                    if sem.wait(timeout: .now() + 0.05) == .success { break }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                }
                return box.snapshot()
            }

            // 死端口→3（transport failed；port+1000 落在合法区间且非本服端口）
            writeConfig(port: port + 1000, token: "tk-agent-loopback")
            let r1 = runBG([.status])
            check("loop: CLI 死端口→退出码 3", r1.first == AgentCLIExitCode.appUnreachable)

            // 正确 token→0 + 错 token→4（后台线程内切换配置）
            writeConfig(port: port, token: "tk-agent-loopback")
            let r2 = runBG([.status])
            check("loop: CLI status→退出码 0", r2.first == AgentCLIExitCode.ok)
            writeConfig(port: port, token: "wrong-token")
            let r3 = runBG([.status])
            check("loop: CLI 错 token→退出码 4", r3.first == AgentCLIExitCode.unauthorized)

            // 本地直读双命令（不经 HTTP）
            let r4 = runBG([.windowsList(includeAll: false)])
            check("loop: CLI windows list 本地直读→0", r4.first == AgentCLIExitCode.ok)
            let r5 = runBG([.sessionsList])
            check("loop: CLI sessions list 本地直读→0", r5.first == AgentCLIExitCode.ok)

            // 写命令授权矩阵（⚠️先把正确 token 配置写回去——上一场景覆写成了错 token）：
            // 全关→5；L1 开幽灵窗→6（404→operationFailed）
            writeConfig(port: port, token: "tk-agent-loopback")
            AgentAccessPreferences.isEnabled = false
            let r6 = runBG([.moveMain(windowID: 1)])
            check("loop: CLI 写命令全关→退出码 5", r6.first == AgentCLIExitCode.forbidden)

            AgentAccessPreferences.isEnabled = true
            AgentAccessPreferences.allowWindowOps = true
            let r7 = runBG([.moveMain(windowID: 4000000000)])
            check("loop: CLI L1 幽灵窗→退出码 6", r7.first == AgentCLIExitCode.operationFailed)
        }
    }
}
