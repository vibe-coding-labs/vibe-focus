import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerAgentAPIDispatchTests.swift — 覆盖率批次（2026-11-03）：
// Agent 命令 API 的**进程内分发直调**（不起服务器、不走 socket）。
//
// 与 RunnerAgentAccessLoopbackTests 的分工：那边用真实 GCDWebServer 打环回，验证
// HTTP 壳与 CLI 退出码；这边直调 `handleAgentAPIRequest`，覆盖 HTTP 面不可达/不必
// 走网络的判定臂——非回环对端 403、未知端点 404、分级门拒绝码、L0 读端点、
// 各写端点的参数解码 400 与幽灵目标 404/409。
//
// 安全边界（真机零副作用）：
// - 全程不启动服务器、不写用户文件、不发系统通知、不搬窗/建窗/切 space；
// - L2（grid/create、snapshots/restore）只在授权关态验证 403，绝不真执行；
// - snapshots/capture 属 L1 真写库，只在 windowOps 关态验证 403；
// - layout 合法 preset 会真摆前台窗——只验非法 preset 的 400 臂；
// - AgentAccessPreferences 快照-还原，写配额每段清零。

extension RunnerHarness {

    func runAgentAPIDispatchTests() {
        print("\n=== AgentAPIDispatch ===")

        let savedEnabled = AgentAccessPreferences.isEnabled
        let savedWindowOps = AgentAccessPreferences.allowWindowOps
        let savedCreate = AgentAccessPreferences.allowCreateWindows
        let savedSettingsWrite = AgentAccessPreferences.allowSettingsWrite
        defer {
            AgentAccessPreferences.isEnabled = savedEnabled
            AgentAccessPreferences.allowWindowOps = savedWindowOps
            AgentAccessPreferences.allowCreateWindows = savedCreate
            AgentAccessPreferences.allowSettingsWrite = savedSettingsWrite
            AgentWriteRateLimiter.resetForTesting()
        }
        AgentWriteRateLimiter.resetForTesting()

        /// 进程内直调分发层；返回 (状态码, JSON 信封)。
        func call(
            _ method: String, _ path: String, body: [String: Any]? = nil,
            peer: String? = nil, headers: [String: String] = [:]
        ) -> (status: Int, json: [String: Any]) {
            let data = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            // 全量 Runner 连跑时，前面域可能已起服并留下 configuredToken——请求必须
            // 带上当前 token 才能通过 token 门（本域不起服、只直调分发层）。
            var allHeaders = headers
            if allHeaders["X-VibeFocus-Token"] == nil,
               let token = ClaudeHookServer.shared.configuredToken {
                allHeaders["X-VibeFocus-Token"] = token
            }
            final class Box: @unchecked Sendable {
                var value: (status: Int, json: [String: Any]) = (-1, [:])
            }
            let box = Box()
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                let result = await ClaudeHookServer.shared.handleAgentAPIRequest(
                    method: method, path: path, body: data,
                    query: [:], headers: allHeaders, peerAddress: peer)
                let json = (try? JSONSerialization.jsonObject(with: result.body)) as? [String: Any] ?? [:]
                box.value = (result.statusCode, json)
                sem.signal()
            }
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if sem.wait(timeout: .now() + 0.05) == .success { break }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return box.value
        }
        func code(_ json: [String: Any]) -> String { json["code"] as? String ?? "-" }

        // MARK: §1 环路门 / 未知端点（不依赖授权态；判定顺序在最前）
        do {
            AgentAccessPreferences.isEnabled = true
            let remote = call("GET", "/api/v1/status", peer: "10.1.2.3")
            check("apiDispatch: 非回环对端→403 loopback_only（实际 \(remote.status)/\(code(remote.json))）",
                  remote.status == 403 && code(remote.json) == "loopback_only")

            let unknown = call("GET", "/api/v1/evil")
            check("apiDispatch: 未知端点→404 not_found（实际 \(unknown.status)/\(code(unknown.json))）",
                  unknown.status == 404 && code(unknown.json) == "not_found")

            // IPv6 回环与代理头不在本层判定，用 ::1 直连确认放行到业务层
            let loopbackV6 = call("GET", "/api/v1/status", peer: "::1")
            check("apiDispatch: IPv6 环回放行→200", loopbackV6.status == 200)
        }

        // MARK: §2 分级门：总开关关 → 一律 403 agent_access_disabled
        do {
            AgentAccessPreferences.isEnabled = false
            AgentAccessPreferences.allowWindowOps = false
            AgentAccessPreferences.allowCreateWindows = false
            for path in ["/api/v1/status", "/api/v1/settings", "/api/v1/windows",
                         "/api/v1/sessions", "/api/v1/snapshots"] {
                let r = call("GET", path)
                check("apiDispatch: 总开关关 GET \(path)→403（实际 \(r.status)/\(code(r.json))）",
                      r.status == 403 && code(r.json) == "agent_access_disabled")
            }
        }

        // MARK: §3 L0 读端点（只读：CG 窗口枚举 / 注册表 / 快照列表）
        do {
            AgentAccessPreferences.isEnabled = true
            let settings = call("GET", "/api/v1/settings")
            let settingsData = settings.json["data"] as? [String: Any]
            check("apiDispatch: GET settings→200 且返回目录",
                  settings.status == 200 && settingsData?.isEmpty == false)
            let windows = call("GET", "/api/v1/windows")
            check("apiDispatch: GET windows→200", windows.status == 200)
            let sessions = call("GET", "/api/v1/sessions")
            check("apiDispatch: GET sessions→200", sessions.status == 200)
            let snapshots = call("GET", "/api/v1/snapshots")
            check("apiDispatch: GET snapshots→200", snapshots.status == 200)
        }

        // MARK: §4 写端点参数解码 400 族（全部在动作执行之前返回）
        do {
            AgentAccessPreferences.isEnabled = true
            AgentAccessPreferences.allowWindowOps = true
            AgentAccessPreferences.allowCreateWindows = false
            AgentWriteRateLimiter.resetForTesting()

            let cases: [(path: String, body: [String: Any])] = [
                ("/api/v1/windows/move-main", [:]),
                ("/api/v1/windows/float", [:]),
                ("/api/v1/windows/focus", [:]),
                ("/api/v1/windows/layout", ["preset": "evil"]),
                ("/api/v1/notify", ["text": "  "]),
                ("/api/v1/space/switch", [:]),
                ("/api/v1/space/switch", ["space": 0]),
            ]
            for item in cases {
                let r = call("POST", item.path, body: item.body)
                check("apiDispatch: POST \(item.path) \(item.body)→400 bad_request（实际 \(r.status)/\(code(r.json))）",
                      r.status == 400 && code(r.json) == "bad_request")
            }

            // 幽灵目标：读路径 404；float off 幂等 no-op（不执行任何窗口操作）
            let ghostMove = call("POST", "/api/v1/windows/move-main", body: ["windowId": 4_000_000_000])
            check("apiDispatch: move-main 幽灵窗→404 window_not_found（实际 \(ghostMove.status)/\(code(ghostMove.json))）",
                  ghostMove.status == 404 && code(ghostMove.json) == "window_not_found")
            let ghostFloat = call("POST", "/api/v1/windows/float",
                                  body: ["windowId": 4_000_000_000, "on": false])
            check("apiDispatch: float 幽灵窗 off→no_op（实际 \(ghostFloat.status)/\(code(ghostFloat.json))）",
                  ghostFloat.status == 200 && code(ghostFloat.json) == "no_op")
        }

        // MARK: §5 授权矩阵：L1/L2 关态的拒绝码分层
        do {
            AgentAccessPreferences.isEnabled = true
            AgentAccessPreferences.allowWindowOps = false
            AgentAccessPreferences.allowCreateWindows = false
            let capture = call("POST", "/api/v1/snapshots/capture", body: [:])
            check("apiDispatch: capture（L1）关→403 agent_writes_disabled（实际 \(capture.status)/\(code(capture.json))）",
                  capture.status == 403 && code(capture.json) == "agent_writes_disabled")

            AgentAccessPreferences.allowWindowOps = true
            AgentAccessPreferences.allowCreateWindows = false
            let grid = call("POST", "/api/v1/grid/create", body: [:])
            check("apiDispatch: grid create（L2）关→403 create_windows_disabled（实际 \(grid.status)/\(code(grid.json))）",
                  grid.status == 403 && code(grid.json) == "create_windows_disabled")
            let restore = call("POST", "/api/v1/snapshots/restore", body: [:])
            check("apiDispatch: snapshot restore（L2）关→403 create_windows_disabled（实际 \(restore.status)/\(code(restore.json))）",
                  restore.status == 403 && code(restore.json) == "create_windows_disabled")
        }

        // MARK: §6 settings 写：独立开关 + 白名单/人属键拒绝（不落任何真实设置）
        do {
            AgentAccessPreferences.isEnabled = true
            AgentAccessPreferences.allowSettingsWrite = false
            let disabled = call("POST", "/api/v1/settings",
                                body: ["key": "sound.volume", "value": 0.5])
            check("apiDispatch: settings 写开关关→403 settings_write_disabled（实际 \(disabled.status)/\(code(disabled.json))）",
                  disabled.status == 403 && code(disabled.json) == "settings_write_disabled")

            AgentAccessPreferences.allowSettingsWrite = true
            let empty = call("POST", "/api/v1/settings", body: ["updates": [[String: Any]]()])
            check("apiDispatch: settings updates 空数组→400（实际 \(empty.status)/\(code(empty.json))）",
                  empty.status == 400)
            let badShape = call("POST", "/api/v1/settings", body: ["foo": 1])
            check("apiDispatch: settings 缺 key/value→400（实际 \(badShape.status)/\(code(badShape.json))）",
                  badShape.status == 400)
            let readonly = call("POST", "/api/v1/settings",
                                body: ["key": "hook.token", "value": "x"])
            let readonlyResults = readonly.json["data"] as? [String: Any]
            let readonlyRow = (readonlyResults?["results"] as? [[String: Any]])?.first
            check("apiDispatch: settings 人属键→403 settings_key_readonly（实际 \(readonly.status)/\((readonlyRow?["error"] as? String) ?? "-")）",
                  readonly.status == 403 && readonlyRow?["error"] as? String == "settings_key_readonly")
            let unknownKey = call("POST", "/api/v1/settings",
                                  body: ["key": "no.such.key", "value": 1])
            let unknownResults = unknownKey.json["data"] as? [String: Any]
            let unknownRow = (unknownResults?["results"] as? [[String: Any]])?.first
            check("apiDispatch: settings 目录外键→400 settings_key_unknown（实际 \(unknownKey.status)/\((unknownRow?["error"] as? String) ?? "-")）",
                  unknownKey.status == 400 && unknownRow?["error"] as? String == "settings_key_unknown")
        }
    }
}
