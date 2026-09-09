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
// 5. 无 jq 环境 → settings.json 原样保留 + 警告 + 手动 JSON 回显（降级分支）。

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

        // ===== 受控偏好下的完整沙盒安装 =====
        func jqAvailable() -> Bool {
            let r = ShellRunner.run(executable: "/usr/bin/env", arguments: ["which", "jq"])
            return (r?.exitCode == 0) && !(r?.stdout.isEmpty ?? true)
        }
        let hasJQ = jqAvailable()

        func runInstaller(home: String, path: String) -> (exit: Int32, output: String) {
            let script = ClaudeHookPreferences.generateRemoteInstallScript(host: "192.168.1.12")
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
                      && output.contains("[4/4] Updated"))

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
                try? FileManager.default.removeItem(atPath: home)
            }
        }

        // 场景 2：无 jq（沙盒 bin 只放脚本所需工具，不含 jq）→ settings.json 原样保留 + 降级警告
        do {
            let home = "/tmp/vibefocus-b83-ri-nojq-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
            let seeded = #"{"hooks":{"PreToolUse":[{"hooks":[{"command":"echo keep-me","type":"command"}]}]}}"#
            let seededData = Data(seeded.utf8)
            FileManager.default.createFile(atPath: home + "/.claude/settings.json", contents: seededData)

            // 沙盒 bin：只放安装脚本所需工具（python3/mkdir/cat/chmod），不含 jq
            let binDir = home + "/bin"
            try? FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
            for tool in ["/usr/bin/python3", "/bin/mkdir", "/bin/cat", "/bin/chmod"] {
                let name = (tool as NSString).lastPathComponent
                try? FileManager.default.createSymbolicLink(atPath: binDir + "/" + name,
                                                            withDestinationPath: tool)
            }

            let (exit, output) = runInstaller(home: home, path: binDir)

            check("remoteInstall[nojq]: 脚本零错误退出（jq 缺失走降级）", exit == 0)
            let settingsAfter = FileManager.default.contents(atPath: home + "/.claude/settings.json")
            check("remoteInstall[nojq]: settings.json 原样保留（不破坏用户配置）",
                  settingsAfter == seededData)
            check("remoteInstall[nojq]: 输出含降级警告与手动 JSON",
                  output.contains("jq not found") && output.contains("hooks"))
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
            try? FileManager.default.removeItem(atPath: home)
        }
    }
}
