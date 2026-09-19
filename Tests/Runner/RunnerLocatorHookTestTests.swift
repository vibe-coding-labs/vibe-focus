// Tests/Runner/RunnerLocatorHookTestTests.swift
// B229 覆盖堆叠·定位器注入缝 + Hook 测试纯件 + 崩溃报告只读扫描：
// ①ClaudeSessionLocator 全家族假 runner 直驱（claudePID/workingDirectory/shellPID/
//   shellWorkingDirectory/locateSessionID——ps/lsof 全走假 runner 零 fork，home 注入
//   隔离目录）；②SettingsView+HookTest 的 buildHookRequest/hookResponseVerdict 纯件
//   （sendTestHookEvent 真发 HTTP 到本机服务不碰）；③CrashContextRecorder+IO 只读扫描
//   （latestCrashReportURL/loadState）。

import Foundation
@testable import VibeFocusKit

extension RunnerHarness {

    func runLocatorSeamTests() {
        print("\n=== LocatorSeam (B229) ===")

        // 1) claudePID：混合进程表取 claude、无 claude nil、runner 失败 nil
        func fakeRunner(_ table: [String: (Int32, String)]) -> (String, [String]) -> YabaiClient.YabaiResult? {
            return { exe, args in
                table[exe + "|" + args.joined(separator: " ")].map {
                    YabaiClient.YabaiResult(exitCode: $0.0, stdout: $0.1, stderr: "")
                }
            }
        }
        let psKey = "/bin/ps|-t ttys010 -o pid=,command="
        let mixed = fakeRunner([
            psKey: (0, "  501 login -pf cc\n  502 zsh\n  610 /usr/local/bin/claude --resume s9\n  700 vim\n")
        ])
        check("locator: claudePID 命中 claude 进程",
              ClaudeSessionLocator.claudePID(onTTY: "/dev/ttys010", runner: mixed) == 610)
        let noClaude = fakeRunner([psKey: (0, "  502 zsh\n  700 vim\n")])
        check("locator: 无 claude 进程 nil",
              ClaudeSessionLocator.claudePID(onTTY: "ttys010", runner: noClaude) == nil)
        let deadRunner: (String, [String]) -> YabaiClient.YabaiResult? = { _, _ in nil }
        check("locator: ps 失败 nil",
              ClaudeSessionLocator.claudePID(onTTY: "/dev/ttys010", runner: deadRunner) == nil)

        // 2) workingDirectory：lsof n 前缀行取 cwd；无 n 行 nil
        let lsofKey = "/usr/sbin/lsof|-a -p 610 -d cwd -Fn"
        let withCwd = fakeRunner([lsofKey: (0, "p610\nn/tmp/b229-proj\n")])
        check("locator: lsof n 行取 cwd",
              ClaudeSessionLocator.workingDirectory(ofPID: 610, runner: withCwd) == "/tmp/b229-proj")
        let noCwd = fakeRunner([lsofKey: (0, "p610\n")])
        check("locator: 无 n 行 nil",
              ClaudeSessionLocator.workingDirectory(ofPID: 610, runner: noCwd) == nil)

        // 3) shellPID：login 前缀剥离、多 shell 取最小 pid、非 shell nil
        let shells = fakeRunner([psKey: (0, "  501 login -pf cc\n  502 -zsh\n  503 bash\n")])
        check("locator: shellPID 最小 pid（login 剥离）",
              ClaudeSessionLocator.shellPID(onTTY: "/dev/ttys010", runner: shells) == 502)
        let noShell = fakeRunner([psKey: (0, "  700 vim\n")])
        check("locator: 无 shell nil",
              ClaudeSessionLocator.shellPID(onTTY: "/dev/ttys010", runner: noShell) == nil)

        // 4) shellWorkingDirectory 组合：shell→lsof 链
        let composed = fakeRunner([
            psKey: (0, "  502 zsh\n"),
            lsofKey + "": (0, ""),
        ])
        // 为组合用例重造 lsof 键（pid 502）
        let composedRunner: (String, [String]) -> YabaiClient.YabaiResult? = { exe, args in
            if exe == "/bin/ps" { return YabaiClient.YabaiResult(exitCode: 0, stdout: "  502 zsh\n", stderr: "") }
            if args.first == "-a" { return YabaiClient.YabaiResult(exitCode: 0, stdout: "p502\nn/tmp/b229-shell\n", stderr: "") }
            return nil
        }
        check("locator: shell 组合 cwd",
              ClaudeSessionLocator.shellWorkingDirectory(onTTY: "/dev/ttys010", runner: composedRunner) == "/tmp/b229-shell")
        _ = composed

        // 5) locateSessionID 组合：claude→cwd→projects 目录（home 注入隔离临时目录）
        let tempHome = NSTemporaryDirectory() + "b229-home-\(UUID().uuidString)"
        let projectDir = tempHome + "/.claude/projects/-tmp-b229-proj"
        try? FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: projectDir + "/b229-session.jsonl",
            contents: Data("{}".utf8))
        defer { try? FileManager.default.removeItem(atPath: tempHome) }
        let sessionRunner: (String, [String]) -> YabaiClient.YabaiResult? = { exe, args in
            if exe == "/bin/ps" { return YabaiClient.YabaiResult(exitCode: 0, stdout: "  610 /opt/claude --resume\n", stderr: "") }
            if args.first == "-a" { return YabaiClient.YabaiResult(exitCode: 0, stdout: "p610\nn/tmp/b229-proj\n", stderr: "") }
            return nil
        }
        let located = ClaudeSessionLocator.locateSessionID(
            ttyPath: "/dev/ttys010", runner: sessionRunner, now: Date(), home: tempHome)
        check("locator: 组合命中 session+cwd",
              located?.sessionID == "b229-session" && located?.cwd == "/tmp/b229-proj")
        let notFound = ClaudeSessionLocator.locateSessionID(
            ttyPath: "/dev/ttys010", runner: noClaude, now: Date(), home: tempHome)
        check("locator: 无 claude 组合 nil", notFound == nil)
    }

    // MARK: - HookTest 纯件（请求构造 + 响应裁决）

    func runHookTestPureTests() {
        print("\n=== HookTestPure (B229) ===")

        // buildHookRequest：URL/方法/头/token/body 形状
        let request = try? SettingsView.buildHookRequest(
            port: 39277, endpoint: "/claude/hook",
            payload: ["event": "Stop", "session_id": "b229"], token: "tk-b229")
        check("hookTest: URL 端点拼接",
              request?.url?.absoluteString == "http://127.0.0.1:39277/claude/hook")
        check("hookTest: POST+JSON 头", request?.httpMethod == "POST"
              && request?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        check("hookTest: token 头注入",
              request?.value(forHTTPHeaderField: "X-VibeFocus-Token") == "tk-b229")
        check("hookTest: body JSON 可解析",
              (try? JSONSerialization.jsonObject(with: request?.httpBody ?? Data())) != nil)
        let noToken = try? SettingsView.buildHookRequest(
            port: 1, endpoint: "/x", payload: [:], token: nil)
        check("hookTest: 无 token 不带头",
              noToken?.value(forHTTPHeaderField: "X-VibeFocus-Token") == nil)

        // hookResponseVerdict 三态：非 HTTP/4xx 带 body/2xx 成功
        if case .failure = SettingsView.hookResponseVerdict(response: nil, data: nil) {
            check("hookTest: 非 HTTP 响应失败", true)
        } else {
            check("hookTest: 非 HTTP 响应失败", false)
        }
        let http403 = HTTPURLResponse(url: URL(string: "http://127.0.0.1")!, statusCode: 403,
                                      httpVersion: nil, headerFields: nil)!
        if case .failure(let err) = SettingsView.hookResponseVerdict(response: http403, data: Data("denied".utf8)) {
            let nsErr = err as NSError
            check("hookTest: 4xx 失败携带状态码与 body", nsErr.code == 403
                  && nsErr.localizedDescription.contains("denied"))
        } else {
            check("hookTest: 4xx 失败携带状态码与 body", false)
        }
        let http200 = HTTPURLResponse(url: URL(string: "http://127.0.0.1")!, statusCode: 200,
                                      httpVersion: nil, headerFields: nil)!
        if case .success = SettingsView.hookResponseVerdict(response: http200, data: nil) {
            check("hookTest: 2xx 成功", true)
        } else {
            check("hookTest: 2xx 成功", false)
        }
    }

    // MARK: - CrashContextRecorder+IO 只读扫描

    func runCrashIOReadTests() {
        print("\n=== CrashIORead (B229) ===")
        let recorder = CrashContextRecorder.shared

        // latestCrashReportURL：真实 DiagnosticReports 目录只读扫描（无报告 nil / 有报告取最新）
        let report = recorder.latestCrashReportURL()
        check("crashIO: 报告扫描不崩溃（nil 或 VibeFocus-*.ips）",
              report == nil || (report!.lastPathComponent.hasPrefix("VibeFocus-")
                                && report!.lastPathComponent.hasSuffix(".ips")))

        // loadState：状态文件缺失/损坏/合法（runner 隔离路径）→ 不崩溃
        _ = recorder.loadState()
        check("crashIO: 状态读取不崩溃", true)
    }
}
