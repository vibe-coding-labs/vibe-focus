// Tests/Runner/RunnerAgentApiGuardSweepTests.swift — 覆盖率批次 34：Agent API 请求门与
// 参数守卫全表（CLI 直测，零真实窗操作）。
//
// handleAgentAPIRequest 的 dispatch 之前有四道门（回环 only / token / 端点匹配 / 分级
// 授权），之后每个写端点各有一层参数守卫。本域用空 JSON 打全部端点，只走「参数缺失 →
// 400」与「目标不存在 → 404/409」失败臂，覆盖守卫与错误响应构造；绝不调用
// snapshots/capture（会写快照库）与 grid/create（会真的建终端窗），也不构造会触发
// 真搬窗的入参。成功臂的真窗路径归真机 E2E 口径。
//
// 写操作限流（60s / 30 次）在域末尾用无害 400 请求打满并断言 429——本域独立进程，
// 不影响其他域。

import AppKit
import Foundation

@testable import VibeFocusKit

extension RunnerHarness {
    func runAgentApiGuardSweepTests() {
        print("\n=== AgentApiGuardSweep ===")
        let server = ClaudeHookServer.shared

        final class ResultBox: @unchecked Sendable {
            var value: (statusCode: Int, body: Data)?
        }
        func call(_ method: String, _ path: String, body: String = "{}", peer: String? = nil) -> (statusCode: Int, body: Data) {
            let box = ResultBox()
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                let r = await server.handleAgentAPIRequest(
                    method: method,
                    path: path,
                    body: Data(body.utf8),
                    query: ["token": ClaudeHookPreferences.authToken],
                    headers: [:],
                    peerAddress: peer
                )
                box.value = r
                sem.signal()
            }
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if sem.wait(timeout: .now() + 0.05) == .success { break }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return box.value ?? (statusCode: -1, body: Data())
        }

        let savedEnabled = AgentAccessPreferences.isEnabled
        let savedWindowOps = AgentAccessPreferences.allowWindowOps
        let savedCreateWindows = AgentAccessPreferences.allowCreateWindows
        let savedSettingsWrite = AgentAccessPreferences.allowSettingsWrite
        AgentAccessPreferences.isEnabled = true
        AgentAccessPreferences.allowWindowOps = true
        AgentAccessPreferences.allowCreateWindows = true
        AgentAccessPreferences.allowSettingsWrite = false
        defer {
            AgentAccessPreferences.isEnabled = savedEnabled
            AgentAccessPreferences.allowWindowOps = savedWindowOps
            AgentAccessPreferences.allowCreateWindows = savedCreateWindows
            AgentAccessPreferences.allowSettingsWrite = savedSettingsWrite
        }

        // --- A. 四道前置门：非回环 / 未知端点 / 分级未开 ---
        let lan = call("GET", "/api/v1/status", peer: "192.168.1.66")
        check("apiGuard: 非回环对端 → 403", lan.statusCode == 403)
        let unknown = call("GET", "/api/v1/ut-unknown")
        check("apiGuard: 未知端点 → 404", unknown.statusCode == 404)
        AgentAccessPreferences.allowWindowOps = false
        let tierDenied = call("POST", "/api/v1/windows/focus")
        check("apiGuard: L1 未开 → 403", tierDenied.statusCode == 403)
        AgentAccessPreferences.allowWindowOps = true
        let badToken = {
            let box = ResultBox()
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                let r = await server.handleAgentAPIRequest(
                    method: "GET", path: "/api/v1/status", body: nil,
                    query: [:], headers: ["X-VibeFocus-Token": "definitely-wrong-token"])
                box.value = r
                sem.signal()
            }
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if sem.wait(timeout: .now() + 0.05) == .success { break }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return box.value ?? (statusCode: -1, body: Data())
        }()
        check("apiGuard: 错误 token → 401",
              ClaudeHookPreferences.authToken.isEmpty || badToken.statusCode == 401)

        // --- B. L0 读端点：三份只读体构造 ---
        let status = call("GET", "/api/v1/status")
        check("apiGuard: status 200", status.statusCode == 200)
        let windows = call("GET", "/api/v1/windows")
        check("apiGuard: windows 200", windows.statusCode == 200)
        let sessions = call("GET", "/api/v1/sessions")
        check("apiGuard: sessions 200", sessions.statusCode == 200)
        let snapshotsList = call("GET", "/api/v1/snapshots")
        check("apiGuard: snapshots 列表 200", snapshotsList.statusCode == 200)
        let settingsGET = call("GET", "/api/v1/settings")
        check("apiGuard: settings GET 200", settingsGET.statusCode == 200)

        // --- C. 写端点参数守卫（空 JSON → 400，零窗口动作） ---
        let moveMain = call("POST", "/api/v1/windows/move-main")
        check("apiGuard: move-main 缺 windowId → 400", moveMain.statusCode == 400)
        let moveMainGhost = call("POST", "/api/v1/windows/move-main", body: #"{"windowId":999999}"#)
        check("apiGuard: move-main 幽灵窗 → 404", moveMainGhost.statusCode == 404)
        let floatGuard = call("POST", "/api/v1/windows/float")
        check("apiGuard: float 缺参 → 400", floatGuard.statusCode == 400)
        let focusGuard = call("POST", "/api/v1/windows/focus")
        check("apiGuard: focus 缺参 → 400", focusGuard.statusCode == 400)
        let layoutGuard = call("POST", "/api/v1/windows/layout")
        check("apiGuard: layout 缺 preset → 400", layoutGuard.statusCode == 400)
        let notifyGuard = call("POST", "/api/v1/notify")
        check("apiGuard: notify 缺 text → 400", notifyGuard.statusCode == 400)
        let spaceGuard = call("POST", "/api/v1/space/switch")
        check("apiGuard: space/switch 缺参 → 400", spaceGuard.statusCode == 400)
        let settingsPOST = call("POST", "/api/v1/settings", body: #"{"key":"no.such.key","value":1}"#)
        check("apiGuard: settings POST 白名单外/未授权 → 400 或 403",
              settingsPOST.statusCode == 400 || settingsPOST.statusCode == 403)

        // --- D. 快照恢复：不存在的 ID → 409（零建窗） ---
        let restoreMissing = call("POST", "/api/v1/snapshots/restore", body: #"{"id":"ut-api-guard-nonexistent"}"#)
        check("apiGuard: restore 不存在快照 → 409", restoreMissing.statusCode == 409)

        // --- E. 写限流：无害 400 打满 60s 窗口 → 429 ---
        var sawRateLimited = false
        for _ in 0..<40 {
            if call("POST", "/api/v1/windows/float").statusCode == 429 {
                sawRateLimited = true
                break
            }
        }
        check("apiGuard: 写操作限流生效 → 429", sawRateLimited)
    }
}
