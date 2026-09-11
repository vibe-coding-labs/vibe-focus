import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerRemoteInstallTests.swift — B84：远程一键安装脚本「生成物行为测试」
// （B50/B54 模式：真实 bash 执行应用生成的安装脚本于沙盒 HOME，断言落盘产物）。
// 覆盖：「局域网 Hook → 远程一键安装」按钮产出的脚本此前零存活测试——它跑在远程
// 机器上，坏一处则整个 SSH 远程联动断链。
//
// 契约锁定：
// 1. machine_label 由 host 派生（点→横杠，前缀 remote-）。
// 2. hook-config.json 四字段精确（host/port/token/machine_label）。
// 3. forwarder.sh 可执行且含鉴权头/配置读取/terminal_ctx 注入。
// 4. settings.json 合并保留既有 hooks、注册触发事件、SessionEnd 按偏好缺席。
// 5. 无 jq 环境 → settings.json 走 python3 降级合并（同语义，不再只警告跳过——
//    真机 local-server-002 无 jq，旧降级导致 hooks 注册被静默跳过）。
// 6. ~/.codex/hooks.json 规范形状（codex 0.153.4 实证：事件字典必须包在顶层
//    "hooks" 字段下，顶层只接受 description/hooks）且只注册 codex 可触发事件
//    （SessionStart[+SessionEnd]；Claude 的 Stop/UserPromptSubmit 在 codex 无
//    对应事件、写入永不触发）。

extension RunnerHarness {

    func runRemoteInstallTests() {
        // 受控偏好：生成器读全局静态（Runner 域跨进程持久化——先存后还原，防污染
        // 同进程后续测试与下次运行）。
        let savedPort = ClaudeHookPreferences.listenPort
        let savedToken = ClaudeHookPreferences.authToken
        let savedOnStop = ClaudeHookPreferences.triggerOnStop
        let savedOnSessionEnd = ClaudeHookPreferences.triggerOnSessionEnd
        let savedAutoRestore = ClaudeHookPreferences.autoRestoreOnPromptSubmit
        ClaudeHookPreferences.listenPort = 39277
        ClaudeHookPreferences.authToken = "test-token-b84"
        ClaudeHookPreferences.triggerOnStop = true
        ClaudeHookPreferences.triggerOnSessionEnd = false
        ClaudeHookPreferences.autoRestoreOnPromptSubmit = true
        defer {
            ClaudeHookPreferences.listenPort = savedPort
            ClaudeHookPreferences.authToken = savedToken
            ClaudeHookPreferences.triggerOnStop = savedOnStop
            ClaudeHookPreferences.triggerOnSessionEnd = savedOnSessionEnd
            ClaudeHookPreferences.autoRestoreOnPromptSubmit = savedAutoRestore
        }

        // ===== machineLabel 派生 =====
        check("remoteInstall: label = remote- + host 点转横杠",
              ClaudeHookPreferences.machineLabel(forHost: "192.168.1.12") == "remote-192-168-1-12")

        // ===== 生成物字符串契约（不执行）=====
        let helper = ClaudeHookPreferences.generateRemoteHelperScriptContent()
        check("remoteInstall: forwarder 读 config 且带鉴权头/terminal_ctx 注入/正确端点",
              helper.contains("machine_label") && helper.contains("X-VibeFocus-Token")
              && helper.contains("http://$VF_HOST:$VF_PORT/claude/hook")
              && helper.contains("hook-config.json"))

        check("remoteInstall: forwarder 多候选试连（connect-timeout+last-good 记忆）",
              helper.contains("--connect-timeout 1 -m 4")
              && helper.contains(".forwarder-host")
              && helper.contains("VF_ORDERED"))
        check("remoteInstall: forwarder hosts 数组优先、单 host 回退、loopback 兜底",
              helper.contains("d.get('hosts')")
              && helper.contains("str(d.get('host') or '127.0.0.1')")
              && helper.contains("VF_HOSTS_RAW=\"127.0.0.1\""))

        // ===== 多候选失效切换（沙盒真实执行——B168 死地址→活地址）=====
        func runForwarder(home: String, path: String, payload: String) -> (exit: Int32, output: String) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [home + "/.vibefocus/hook-forwarder.sh"]
            proc.environment = ["HOME": home, "PATH": path, "SSH_CLIENT": "203.0.113.9 51000 192.168.1.12 22"]
            let inPipe = Pipe()
            let out = Pipe()
            proc.standardInput = inPipe
            proc.standardOutput = out
            proc.standardError = out
            let script = ClaudeHookPreferences.generateRemoteHelperScriptContent()
            try? FileManager.default.createDirectory(atPath: home + "/.vibefocus", withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: home + "/.vibefocus/hook-forwarder.sh",
                                           contents: Data(script.utf8))
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home + "/.vibefocus/hook-forwarder.sh")
            do { try proc.run() } catch { return (1, "spawn failed") }
            inPipe.fileHandleForWriting.write(Data(payload.utf8))
            try? inPipe.fileHandleForWriting.close()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }

        func pollUntil(_ path: String, timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: path) { return true }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return false
        }

        if FileManager.default.fileExists(atPath: "/usr/bin/python3") {
            let home = "/tmp/vibefocus-b165-failover-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: home + "/.vibefocus", withIntermediateDirectories: true)
            let catcherPath = home + "/catcher.py"
            let portFile = home + "/catcher.port"
            let requestFile = home + "/catcher.request"
            let catcherSource = """
            import socket, sys
            s = socket.socket()
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(('127.0.0.1', 0))
            s.listen(1)
            open(sys.argv[1], 'w').write(str(s.getsockname()[1]))
            for i in (1, 2):
                conn, _ = s.accept()
                data = conn.recv(65536)
                conn.sendall(b'HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\n\\r\\nok')
                conn.close()
                open(sys.argv[2] + '.' + str(i), 'wb').write(data)
            """
            FileManager.default.createFile(atPath: catcherPath, contents: Data(catcherSource.utf8))

            let catcher = Process()
            catcher.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            catcher.arguments = [catcherPath, portFile, requestFile]
            try? catcher.run()

            let portReady = pollUntil(portFile, timeout: 10)
            check("remoteInstall[failover]: catcher 起监听", portReady)
            if portReady {
                let livePort = String(data: FileManager.default.contents(atPath: portFile) ?? Data(), encoding: .utf8) ?? ""
                let config = ClaudeHookPreferences.hookConfigJSON(
                    host: "192.0.2.1", port: Int(livePort) ?? 39277, token: "tok-failover",
                    machineLabel: "remote-failover-test", extraHosts: [])
                // hosts 序 = [死地址(192.0.2.1 TEST-NET 必超时), 127.0.0.1(活)]
                let configWithLive = config
                    .replacingOccurrences(of: "\"host\": \"192.0.2.1\",",
                                          with: "\"host\": \"192.0.2.1\",\"hosts\": [\"192.0.2.1\",\"127.0.0.1\"],")
                FileManager.default.createFile(atPath: home + "/.vibefocus/hook-config.json",
                                               contents: Data(configWithLive.utf8))

                let payload = "{\"session_id\":\"b165-failover\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"hi\",\"cwd\":\"/tmp\"}"
                let fEnvPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
                let t0 = Date()
                let (exit, output) = runForwarder(home: home, path: fEnvPath, payload: payload)
                let elapsed = Date().timeIntervalSince(t0)

                if exit != 0 { print("[诊断-b165-failover] exit=\(exit) output<<\n\(output.prefix(800))\n>>") }
                check("remoteInstall[failover]: 死地址后回退 127.0.0.1 投递成功", exit == 0)
                check("remoteInstall[failover]: catcher 收到请求体（terminal_ctx/鉴权头/label）",
                      pollUntil(requestFile + ".1", timeout: 10)
                      && (FileManager.default.contents(atPath: requestFile + ".1") as Data?).map { body in
                          let raw = String(decoding: body, as: UTF8.self)
                          return raw.contains("b165-failover") && raw.contains("terminal_ctx")
                              && raw.contains("tok-failover") && raw.contains("remote-failover-test")
                      } == true)
                check("remoteInstall[failover]: last-good 落盘为 127.0.0.1",
                      (try? String(contentsOfFile: home + "/.vibefocus/.forwarder-host", encoding: .utf8))?
                        .trimmingCharacters(in: .whitespacesAndNewlines) == "127.0.0.1")
                check("remoteInstall[failover]: 死地址消耗在 connect-timeout 量级（<8s）", elapsed < 8)

                // 快路径：配置只剩死地址时，last-good 提前仍可达
                let deadOnly = "{\n  \"host\": \"192.0.2.1\",\n  \"port\": \(livePort),\n  \"token\": \"tok-failover\",\n  \"machine_label\": \"remote-failover-test\"\n}"
                FileManager.default.createFile(atPath: home + "/.vibefocus/hook-config.json",
                                               contents: Data(deadOnly.utf8))
                let (exit2, _) = runForwarder(home: home, path: fEnvPath, payload: payload)
                // exit 码区分不了投递（全死也零退出），用第二笔请求落账锁死投递语义
                check("remoteInstall[failover]: 配置退化只剩死地址时 last-good 仍投递成功",
                      exit2 == 0 && pollUntil(requestFile + ".2", timeout: 10))

                // 无 last-good + 全死 → 静默失败退出 0（hook 链不卡 Claude Code）
                try? FileManager.default.removeItem(atPath: home + "/.vibefocus/.forwarder-host")
                let (exit3, _) = runForwarder(home: home, path: fEnvPath, payload: payload)
                Thread.sleep(forTimeInterval: 1.5)
                check("remoteInstall[failover]: 无 last-good 且全死时零退出且无第三笔投递",
                      exit3 == 0 && !FileManager.default.fileExists(atPath: requestFile + ".3"))
            }
            catcher.waitUntilExit()
            try? FileManager.default.removeItem(atPath: home)
        }

        // ===== 受控偏好下的完整沙盒安装 =====
        func jqAvailable() -> Bool {
            let r = ShellRunner.run(executable: "/usr/bin/env", arguments: ["which", "jq"])
            return (r?.exitCode == 0) && !(r?.stdout.isEmpty ?? true)
        }
        let hasJQ = jqAvailable()

        func runInstaller(home: String, path: String) -> (exit: Int32, output: String) {
            // B168: 显式注入受控值——此前经全局 authToken 读回，在本域新增的沙盒子进程
            // 孵化（failover 场景）介入后出现过时序性 nil（cfprefs 读回竞态），注入后
            // 本域确定性；偏好 getter 自身由其它域直测。
            let script = ClaudeHookPreferences.generateRemoteInstallScript(
                host: "192.168.1.12", port: 39277, token: "test-token-b84")
            let scriptPath = home + "/install.sh"
            try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: scriptPath, contents: Data(script.utf8))
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [scriptPath]
            proc.environment = ["HOME": home, "PATH": path, "PWD": home]
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = out
            do { try proc.run() } catch { return (1, "spawn failed") }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }

        func readJSON(_ path: String) -> [String: Any]? {
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }

        // 场景 1：有 jq（机器实况）→ settings.json 自动合并
        if hasJQ {
            do {
                let home = "/tmp/vibefocus-b83-ri-jq-\(UUID().uuidString)"
                try? FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
                // 预置一个与 VibeFocus 无关的既有 hook，验证合并不破坏
                let seeded = #"{"hooks":{"PreToolUse":[{"hooks":[{"command":"echo keep-me","type":"command"}]}]}}"#
                FileManager.default.createFile(atPath: home + "/.claude/settings.json",
                                               contents: Data(seeded.utf8))

            let (exit, output) = runInstaller(
                home: home,
                path: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")

            if exit != 0 || output.contains("error") || output.contains("ERROR") {
                print("[诊断-remoteInstall jq] exit=\(exit) output<<\n\(output.prefix(1200))\n>>")
            }
            check("remoteInstall[jq]: 脚本零错误退出", exit == 0)
                check("remoteInstall[jq]: 既有 PreToolUse hook 保留",
                      readJSON(home + "/.claude/settings.json")?["hooks"] != nil
                      && output.contains("[4/6] Updated"))

                let hooks = (readJSON(home + "/.claude/settings.json")?["hooks"] as? [String: Any]) ?? [:]
                // 种子 PreToolUse + 生成的三事件并存（合并语义）
                let registered = hooks.keys.sorted()
                check("remoteInstall[jq]: 注册 SessionStart/Stop/UserPromptSubmit 且种子 hook 保留",
                      registered == ["PreToolUse", "SessionStart", "Stop", "UserPromptSubmit"])

                let entryOK = (hooks["Stop"] as? [[String: Any]])?.first != nil
                    && ((hooks["Stop"] as? [[String: Any]])?[0]["hooks"] as? [[String: Any]])?.first != nil
                    && (((hooks["Stop"] as? [[String: Any]])?[0]["hooks"] as? [[String: Any]])?[0]["command"] as? String)?
                        .contains(".vibefocus/hook-forwarder.sh") == true
                    && (((hooks["Stop"] as? [[String: Any]])?[0]["hooks"] as? [[String: Any]])?[0]["timeout"] as? Int) == 10
                check("remoteInstall[jq]: hook 条目指向 forwarder 且 timeout=10", entryOK)

                let cfg = readJSON(home + "/.vibefocus/hook-config.json") ?? [:]
                check("remoteInstall[jq]: hook-config 四字段精确",
                      cfg["host"] as? String == "192.168.1.12"
                      && cfg["port"] as? Int == 39277
                      && cfg["token"] as? String == "test-token-b84"
                      && cfg["machine_label"] as? String == "remote-192-168-1-12")

                let fwd = home + "/.vibefocus/hook-forwarder.sh"
                check("remoteInstall[jq]: forwarder 落盘且可执行",
                      FileManager.default.isExecutableFile(atPath: fwd))
                check("remoteInstall[jq]: 完成标记与 label 回显",
                      output.contains("Installation Complete") && output.contains("remote-192-168-1-12"))

                // Codex 产物：规范形状（事件包在顶层 "hooks" 字段下）+ 只注册可触发事件
                let codexDoc = readJSON(home + "/.codex/hooks.json") ?? [:]
                let codexHooks = (codexDoc["hooks"] as? [String: Any]) ?? [:]
                check("remoteInstall[jq]: codex hooks.json 规范形状（事件包在 hooks 字段下）",
                      !codexDoc.isEmpty && codexDoc["hooks"] != nil
                      && codexHooks["SessionStart"] != nil)
                check("remoteInstall[jq]: codex 只注册可触发事件（无 Stop/UserPromptSubmit）",
                      codexHooks["Stop"] == nil && codexHooks["UserPromptSubmit"] == nil)
                check("remoteInstall[jq]: codex 步骤回显",
                      output.contains("[5/6] Updated ~/.codex/hooks.json"))

                // B124 回归锁：远程 hook 命令必须 $HOME 形态——真身绝对路径
                //（/Users/...）在远程机器不存在，hook 静默空转（真机 002 实锤）
                func firstCommand(_ dict: [String: Any]?, event: String) -> String? {
                    guard let entries = dict?[event] as? [[String: Any]],
                          let hooks = entries.first?["hooks"] as? [[String: Any]] else { return nil }
                    return hooks.first?["command"] as? String
                }
                let claudeCmd = firstCommand(hooks, event: "Stop")
                let codexCmd = firstCommand(codexHooks, event: "SessionStart")
                check("remoteInstall[jq]: 远程 hook 命令为 $HOME 形态（杜绝 Mac 绝对路径）",
                      claudeCmd == "bash \"$HOME/.vibefocus/hook-forwarder.sh\""
                      && codexCmd == "bash \"$HOME/.vibefocus/hook-forwarder.sh\""
                      && output.contains("/Users/") == false)
                try? FileManager.default.removeItem(atPath: home)
            }
        }

        // 场景 2：无 jq（沙盒 bin 只放脚本所需工具，不含 jq）→ settings.json 走
        // python3 降级合并（同语义；真机 002 无 jq，旧「只警告跳过」会让 hooks
        // 注册静默缺失，远程链路断在半路）
        do {
            let home = "/tmp/vibefocus-b83-ri-nojq-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
            let seeded = #"{"hooks":{"PreToolUse":[{"hooks":[{"command":"echo keep-me","type":"command"}]}]}}"#
            FileManager.default.createFile(atPath: home + "/.claude/settings.json",
                                           contents: Data(seeded.utf8))

            // 沙盒 bin：只放安装脚本所需工具（python3/mkdir/cat/chmod），不含 jq
            let binDir = home + "/bin"
            try? FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
            for tool in ["/usr/bin/python3", "/bin/mkdir", "/bin/cat", "/bin/chmod"] {
                let name = (tool as NSString).lastPathComponent
                try? FileManager.default.createSymbolicLink(atPath: binDir + "/" + name,
                                                            withDestinationPath: tool)
            }

            let (exit, output) = runInstaller(home: home, path: binDir)

            check("remoteInstall[nojq]: 脚本零错误退出（jq 缺失走 python3 降级）", exit == 0)
            let nojqHooks = (readJSON(home + "/.claude/settings.json")?["hooks"] as? [String: Any]) ?? [:]
            check("remoteInstall[nojq]: python3 合并——种子保留 + 三事件注册",
                  nojqHooks.keys.sorted() == ["PreToolUse", "SessionStart", "Stop", "UserPromptSubmit"])
            check("remoteInstall[nojq]: 输出 python3 降级标记",
                  output.contains("(via python3)"))
            // codex 路径同样只依赖 python3，无 jq 环境下照常落盘
            let nojqCodex = ((readJSON(home + "/.codex/hooks.json") ?? [:])["hooks"] as? [String: Any]) ?? [:]
            check("remoteInstall[nojq]: codex hooks.json 照常落盘（SessionStart）",
                  nojqCodex["SessionStart"] != nil)
            try? FileManager.default.removeItem(atPath: home)
        }

        // 场景 3：全新机器（无 ~/.claude/settings.json，无 jq 需求的完整文件创建）
        do {
            let home = "/tmp/vibefocus-b83-ri-fresh-\(UUID().uuidString)"
            let (exit, output) = runInstaller(home: home, path: "/usr/bin:/bin")
            if exit != 0 {
                print("[诊断-remoteInstall fresh] exit=\(exit) output<<\n\(output.prefix(1200))\n>>")
            }
            check("remoteInstall[fresh]: 全新 HOME 零错误退出", exit == 0)
            check("remoteInstall[fresh]: config + forwarder 落盘",
                  FileManager.default.fileExists(atPath: home + "/.vibefocus/hook-config.json")
                  && FileManager.default.isExecutableFile(atPath: home + "/.vibefocus/hook-forwarder.sh"))
            check("remoteInstall[fresh]: codex hooks.json 落盘",
                  FileManager.default.fileExists(atPath: home + "/.codex/hooks.json"))
            try? FileManager.default.removeItem(atPath: home)
        }
    }

    // MARK: - B94：hook-forwarder.sh 转发器行为测试（假 curl 捕获，PATH 注入）
    //
    // 转发器是 LAN 链路的客户端核心（远程机器每个 hook 事件都经它发出）。
    // 测试不真发请求：PATH 注入沙盒 bin（python3 真身 + 假 curl），假 curl 把
    // 参数逐行追加到日志文件，断言 URL/鉴权头/enriched 载荷三要素。

    func runForwarderBehaviorTests() {
        func makeSandbox() -> (home: String, bin: String, log: String, configPath: String, fwdPath: String) {
            let home = "/tmp/vibefocus-b94-fw-\(UUID().uuidString)"
            let bin = home + "/bin"
            let cfgDir = home + "/.vibefocus"
            try? FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: cfgDir, withIntermediateDirectories: true)
            // python3（config 解析与 enrich）与 cat（VF_PAYLOAD=$(cat) 读 stdin）真身；
            // tty 不在 PATH 时脚本有 || echo 兜底，无需符号链接
            try? FileManager.default.createSymbolicLink(atPath: bin + "/python3", withDestinationPath: "/usr/bin/python3")
            try? FileManager.default.createSymbolicLink(atPath: bin + "/cat", withDestinationPath: "/bin/cat")
            let log = home + "/fake-curl.log"
            // 假 curl：把收到的参数逐行写日志，调用之间用 --- 分隔
            let fake = "#!/bin/bash\nfor a in \"$@\"; do printf '%s\\n' \"$a\" >> \"${FAKE_CURL_LOG}\"; done; printf '%s\\n' '---' >> \"${FAKE_CURL_LOG}\"\n"
            let fakePath = bin + "/curl"
            FileManager.default.createFile(atPath: fakePath, contents: Data(fake.utf8))
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePath)
            let configPath = cfgDir + "/hook-config.json"
            let fwdPath = cfgDir + "/hook-forwarder.sh"
            return (home, bin, log, configPath, fwdPath)
        }

        func runForwarder(_ fwdPath: String, payload: String, env: [String: String], bin: String) -> Int32 {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [fwdPath]
            var childEnv = env
            childEnv["PATH"] = bin
            proc.environment = childEnv
            let inPipe = Pipe()
            proc.standardInput = inPipe
            let dbgOut = Pipe()
            proc.standardOutput = dbgOut
            proc.standardError = dbgOut
            do { try proc.run() } catch { return -1 }
            inPipe.fileHandleForWriting.write(Data(payload.utf8))
            try? inPipe.fileHandleForWriting.close()
            proc.waitUntilExit()
            let dbg = String(data: dbgOut.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if proc.terminationStatus != 0 || !dbg.isEmpty {
                print("[诊断-forwarder] status=\(proc.terminationStatus) child<<\n\(dbg.prefix(600))\n>>")
            }
            return proc.terminationStatus
        }

        func readLines(_ path: String) -> [String] {
            guard let data = FileManager.default.contents(atPath: path),
                  let text = String(data: data, encoding: .utf8) else { return [] }
            return text.components(separatedBy: "\n").filter { !$0.isEmpty }
        }

        let forwarder = ClaudeHookPreferences.generateRemoteHelperScriptContent()

        // 场景 1：完整转发——config 四字段 → URL/token 头/machine_label 注入 enriched 载荷
        do {
            let (home, bin, log, configPath, fwdPath) = makeSandbox()
            FileManager.default.createFile(atPath: configPath,
                contents: Data(#"{"host":"192.168.1.12","port":39277,"token":"sec-123","machine_label":"remote-server-001"}"#.utf8))
            FileManager.default.createFile(atPath: fwdPath, contents: Data(forwarder.utf8))
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fwdPath)

            _ = runForwarder(fwdPath, payload: #"{"event":"Stop","session_id":"s-1"}"#,
                                    env: ["HOME": home, "FAKE_CURL_LOG": log,
                                          "TERM_SESSION_ID": "ts-1", "PPID": "4242",
                                          "CLAUDE_PROJECT_DIR": "/Users/x/proj-a"],
                                    bin: bin)
            let lines = readLines(log)
            check("forwarder: 假 curl 收到调用（日志非空）", !lines.isEmpty)

            // URL 与方法
            check("forwarder: POST 到 config 指定的 host:port 端点",
                  lines.contains("-X") && lines.contains("POST")
                  && lines.contains("http://192.168.1.12:39277/claude/hook"))
            // 鉴权头
            check("forwarder: 携带 X-VibeFocus-Token 鉴权头",
                  lines.contains("X-VibeFocus-Token: sec-123"))
            // enriched 载荷：machine_label 与终端上下文注入
            if let dataIdx = lines.firstIndex(of: "--data"), dataIdx + 1 < lines.count,
               let payloadData = lines[dataIdx + 1].data(using: .utf8),
               let body = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any],
               let ctx = body["terminal_ctx"] as? [String: Any] {
                check("forwarder: --data 为 enriched JSON（事件/会话/label/终端上下文注入）",
                      body["event"] as? String == "Stop"
                      && body["session_id"] as? String == "s-1"
                      && ctx["machine_label"] as? String == "remote-server-001"
                      && ctx["term_session_id"] as? String == "ts-1"
                      && ctx["claude_project_dir"] as? String == "/Users/x/proj-a")
            } else {
                check("forwarder: --data 为 enriched JSON（事件/会话/label/终端上下文注入）", false)
            }
            try? FileManager.default.removeItem(atPath: home)
        }

        // 场景 2：config 无 token → 不带鉴权头（本机服务器默认未配 token 的形态）
        do {
            let (home, bin, log, configPath, fwdPath) = makeSandbox()
            FileManager.default.createFile(atPath: configPath,
                contents: Data(#"{"host":"127.0.0.1","port":39277,"token":""}"#.utf8))
            FileManager.default.createFile(atPath: fwdPath, contents: Data(forwarder.utf8))
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fwdPath)

            _ = runForwarder(fwdPath, payload: #"{"event":"Stop","session_id":"s-2"}"#,
                             env: ["HOME": home, "FAKE_CURL_LOG": log], bin: bin)
            let lines = readLines(log)
            check("forwarder: token 为空 → 不带鉴权头",
                  !lines.contains(where: { $0.hasPrefix("X-VibeFocus-Token") })
                  && lines.contains("http://127.0.0.1:39277/claude/hook"))
            try? FileManager.default.removeItem(atPath: home)
        }

        // 场景 3：载荷非 JSON → enrich 失败回退原样转发（不吞事件）
        do {
            let (home, bin, log, configPath, fwdPath) = makeSandbox()
            FileManager.default.createFile(atPath: configPath,
                contents: Data(#"{"host":"192.168.1.12","port":39277,"token":"t","machine_label":"m1"}"#.utf8))
            FileManager.default.createFile(atPath: fwdPath, contents: Data(forwarder.utf8))
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fwdPath)

            _ = runForwarder(fwdPath, payload: "not-json-at-all",
                             env: ["HOME": home, "FAKE_CURL_LOG": log], bin: bin)
            let lines = readLines(log)
            check("forwarder: 非 JSON 载荷原样转发（不吞事件）",
                  lines.contains("not-json-at-all"))
            try? FileManager.default.removeItem(atPath: home)
        }
    }
}
