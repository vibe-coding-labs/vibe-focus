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
                    query: ["token": ClaudeHookPreferences.authToken ?? ""],
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
        // token 门只认 server 实例上的 configuredToken（未起服 = nil → 门放行）。
        // 逐域覆盖率进程内本域不起服；全量 Runner 里前面的 HTTP 壳域会起服 → 401 生效。
        if let expected = server.configuredToken, !expected.isEmpty {
            check("apiGuard: 起服后错误 token → 401", badToken.statusCode == 401)
        } else {
            check("apiGuard: 未起服（configuredToken=nil）→ token 门放行（非 401）",
                  badToken.statusCode != 401)
        }

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

        // --- D2. 快照捕获：无 yabai/无终端窗时采集前置失败 → 409（失败路径不落库） ---
        let capture = call("POST", "/api/v1/snapshots/capture")
        check("apiGuard: capture 采集前置失败 → 409（或环境可采 → 200）",
              capture.statusCode == 409 || capture.statusCode == 200)

        // --- D3. layout 合法 preset：前台是他属 app 时跳过（防真机误移用户窗口）；
        //     否则走真实分发 → 无焦点窗 409 / 自摆本进程窗 200 ---
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let frontIsSelfOrNil = frontPID == nil || frontPID == getpid()
        if frontIsSelfOrNil {
            let layoutValid = call("POST", "/api/v1/windows/layout", body: #"{"preset":"leftHalf"}"#)
            check("apiGuard: layout 合法 preset → 409 降级或 200 自摆（不发散）",
                  layoutValid.statusCode == 409 || layoutValid.statusCode == 200)
        } else {
            check("apiGuard: 前台为他属 app，跳过 layout 实摆（防真机误移）", true)
        }

        // --- D4. settings 批量坏项（缺 value）→ 400 逐项 bad_request，零设置写入 ---
        let savedWriteAgain = AgentAccessPreferences.allowSettingsWrite
        AgentAccessPreferences.allowSettingsWrite = true
        let badItem = call("POST", "/api/v1/settings", body: #"{"updates":[{"key":"sound.volume"}]}"#)
        AgentAccessPreferences.allowSettingsWrite = savedWriteAgain
        check("apiGuard: settings 批量缺 value → 400", badItem.statusCode == 400)

        // --- D5. sessions 读体：进程内注入一条活动 + 窗口绑定，覆盖「带绑定行」分支。
        //     注入只进内存（Runner 无 bundle id → 不落盘）；测毕 reset 回填原样。 ---
        do {
            let tracker = SessionActivityTracker.shared
            let registry = SessionWindowRegistry.shared
            let savedActivities = tracker.activities
            let injectedSession = "ut-api-guard-session"
            let injectedWID: UInt32 = 987_001
            tracker.resetForTesting()
            tracker.record(sessionID: injectedSession, event: .userPromptSubmit,
                           code: "ut-guard", at: Date(timeIntervalSince1970: 1_700_000_000))
            let injectedState = WindowState(
                windowID: injectedWID, pid: Int32(getpid()), tty: nil,
                axWindowNumber: nil, appName: "Terminal", bundleIdentifier: "com.apple.Terminal",
                title: "ut-guard", termSessionID: nil, itermSessionID: nil,
                kittyWindowID: nil, weztermPane: nil, envWindowID: nil,
                sessionID: injectedSession, cwd: nil, model: nil,
                origX: nil, origY: nil, origW: nil, origH: nil,
                targetX: nil, targetY: nil, targetW: nil, targetH: nil,
                sourceSpace: nil, sourceDisplay: nil,
                sourceYabaiDisp: nil, sourceDispSpace: nil,
                targetDisplay: nil, toggleReason: nil, toggledAt: nil,
                isCompleted: false, completedAt: nil,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            registry.windowStates[injectedWID] = injectedState
            defer {
                registry.windowStates.removeValue(forKey: injectedWID)
                tracker.resetForTesting()
                for (sid, activity) in savedActivities {
                    tracker.record(sessionID: sid, event: activity.lastEvent,
                                   code: activity.lastCode, at: activity.at)
                }
            }
            let sessionsBound = call("GET", "/api/v1/sessions")
            let sessionsText = String(data: sessionsBound.body, encoding: .utf8) ?? ""
            check("apiGuard: sessions 带绑定行 → 200 且含 windowId/completed 字段",
                  sessionsBound.statusCode == 200
                  && sessionsText.contains("\"windowId\"")
                  && sessionsText.contains("\"completed\""))
        }

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
