import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerSpoolDrainTests.swift — B171：远程事件 spool 兜底通道
// （VPN/单向 NAT + sshd AllowTcpForwarding no 下远程事件的唯一通路）。
//
// 三层锁定：
// 1. 纯判定直测：主机规范化（防 ssh 选项注入）/对端解析/自注册决策/拉取命令
//    构建/输出解析/ssh argv。
// 2. 注册表行为：隔离 UserDefaults 套件读写去重删除。
// 3. 生成物行为测试（B50/B94 模式）：真实 bash 执行生成的 forwarder 于沙盒 HOME，
//    PATH 注入可控退出的假 curl——直投失败落盘 spool + hint、hint 新鲜跳过直投、
//    hint 过期自愈重试、积压 200 上限挤压。

extension RunnerHarness {

    func runSpoolDrainTests() {

        // ===== 1a. normalizeHost：防注入与规范化 =====
        check("spoolDrain: normalizeHost 修剪空白", RemoteSpoolDrainLogic.normalizeHost("  user@host \n") == "user@host")
        check("spoolDrain: normalizeHost 接受裸 host", RemoteSpoolDrainLogic.normalizeHost("192.168.1.83") == "192.168.1.83")
        check("spoolDrain: normalizeHost 拒绝空串", RemoteSpoolDrainLogic.normalizeHost("   ") == nil)
        check("spoolDrain: normalizeHost 拒绝内嵌空白", RemoteSpoolDrainLogic.normalizeHost("a b@host") == nil)
        check("spoolDrain: normalizeHost 拒绝前导横杠（ssh 选项注入）", RemoteSpoolDrainLogic.normalizeHost("-oProxyCommand=evil") == nil)
        check("spoolDrain: normalizeHost 拒绝多 @", RemoteSpoolDrainLogic.normalizeHost("a@b@c") == nil)
        check("spoolDrain: normalizeHost 拒绝超长", RemoteSpoolDrainLogic.normalizeHost(String(repeating: "x", count: 256)) == nil)

        // ===== 1b. peerIP 解析（GCDWebServer remoteAddressString = host:port）=====
        check("spoolDrain: peerIP 剥端口", RemoteSpoolDrainLogic.peerIP(fromRemoteAddress: "192.168.1.83:55123") == "192.168.1.83")
        check("spoolDrain: peerIP 裸 IP 原样", RemoteSpoolDrainLogic.peerIP(fromRemoteAddress: "192.168.1.83") == "192.168.1.83")
        check("spoolDrain: peerIP IPv6 取末冒号前段", RemoteSpoolDrainLogic.peerIP(fromRemoteAddress: "::1:55123") == "::1")
        check("spoolDrain: peerIP 空/nil 回 nil",
              RemoteSpoolDrainLogic.peerIP(fromRemoteAddress: "") == nil
              && RemoteSpoolDrainLogic.peerIP(fromRemoteAddress: nil) == nil)

        // ===== 1c. 自注册决策：对端必须与上报服务器 IP 一致 =====
        check("spoolDrain: registrationTarget 对端一致 → user@ip",
              RemoteSpoolDrainLogic.registrationTarget(
                machineLabel: "remote-server-001", sshUser: "cc",
                sshServerIP: "192.168.1.83", peerIP: "192.168.1.83") == "cc@192.168.1.83")
        check("spoolDrain: registrationTarget 对端不一致 → 拒注册（防伪造）",
              RemoteSpoolDrainLogic.registrationTarget(
                machineLabel: "remote-x", sshUser: "cc",
                sshServerIP: "192.168.1.83", peerIP: "9.9.9.9") == nil)
        check("spoolDrain: registrationTarget 本地事件（无 label）→ 拒",
              RemoteSpoolDrainLogic.registrationTarget(
                machineLabel: nil, sshUser: "cc",
                sshServerIP: "127.0.0.1", peerIP: "127.0.0.1") == nil)
        check("spoolDrain: registrationTarget 缺用户/缺服务器IP/缺对端 → 拒",
              RemoteSpoolDrainLogic.registrationTarget(
                machineLabel: "r", sshUser: "", sshServerIP: "1.2.3.4", peerIP: "1.2.3.4") == nil
              && RemoteSpoolDrainLogic.registrationTarget(
                machineLabel: "r", sshUser: "cc", sshServerIP: "", peerIP: "1.2.3.4") == nil
              && RemoteSpoolDrainLogic.registrationTarget(
                machineLabel: "r", sshUser: "cc", sshServerIP: "1.2.3.4", peerIP: nil) == nil)

        // ===== 1d. 拉取命令与 ssh argv =====
        let cmd = RemoteSpoolDrainLogic.drainCommand(stalenessMinutes: 10, batchLimit: 20)
        check("spoolDrain: drainCommand 建目录+超龄删除+限量+逐文件取走",
              cmd.contains("mkdir -p")
              && cmd.contains("-mmin +10")
              && cmd.contains("-delete")
              && cmd.contains("head -n 20")
              && cmd.contains("rm -f"))
        check("spoolDrain: drainCommand 参数注入生效",
              RemoteSpoolDrainLogic.drainCommand(stalenessMinutes: 3, batchLimit: 7).contains("-mmin +3")
              && RemoteSpoolDrainLogic.drainCommand(stalenessMinutes: 3, batchLimit: 7).contains("head -n 7"))
        let argv = RemoteSpoolDrainLogic.sshArguments(target: "cc@1.2.3.4", command: "echo hi")
        check("spoolDrain: ssh argv 含 BatchMode 与 -- 防注入且目标在命令前",
              argv.contains("BatchMode=yes")
              && argv.contains("--")
              && argv.count >= 3
              && argv[argv.count - 2] == "cc@1.2.3.4"
              && argv[argv.count - 1] == "echo hi")

        // ===== 1e. 输出解析：只留 JSON 对象行（ssh 杂音/半截写入不进计数器）=====
        check("spoolDrain: parseDrainedLines 取 JSON 行跳过空行与杂音",
              RemoteSpoolDrainLogic.parseDrainedLines("{\"a\":1}\n\n{\"b\":2}\r\ngarbage\nssh: banner\n") ==
              ["{\"a\":1}", "{\"b\":2}"])
        check("spoolDrain: parseDrainedLines 全空输出 → 空",
              RemoteSpoolDrainLogic.parseDrainedLines("\n\n").isEmpty)

        // ===== 2. 注册表（隔离套件）=====
        do {
            let suite = "test-spool-drain-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            check("spoolDrain: 空注册表读出空", RemoteSpoolHosts.loadHosts(defaults: defaults).isEmpty)
            check("spoolDrain: 注册含规范化", RemoteSpoolHosts.registerHost("  cc@1.2.3.4  ", defaults: defaults))
            check("spoolDrain: 重复注册去重", !RemoteSpoolHosts.registerHost("cc@1.2.3.4", defaults: defaults))
            RemoteSpoolHosts.registerHost("cc@5.6.7.8", defaults: defaults)
            check("spoolDrain: 保持插入序", RemoteSpoolHosts.loadHosts(defaults: defaults) == ["cc@1.2.3.4", "cc@5.6.7.8"])
            RemoteSpoolHosts.removeHost("cc@1.2.3.4", defaults: defaults)
            check("spoolDrain: 删除生效", RemoteSpoolHosts.loadHosts(defaults: defaults) == ["cc@5.6.7.8"])
            check("spoolDrain: 非法目标拒注册", !RemoteSpoolHosts.registerHost("-evil", defaults: defaults))
        }

        // ===== 2b. TerminalContext ssh_user 解码（含旧转发器无字段兼容）=====
        do {
            struct Wrapper: Decodable { let ctx: TerminalContext }
            let withUser = try JSONDecoder().decode(
                Wrapper.self,
                from: Data(#"{"ctx":{"machine_label":"m1","ssh_user":"cc"}}"#.utf8))
            check("spoolDrain: terminal_ctx 解码 ssh_user", withUser.ctx.sshUser == "cc")
            let legacy = try JSONDecoder().decode(
                Wrapper.self,
                from: Data(#"{"ctx":{"machine_label":"m1"}}"#.utf8))
            check("spoolDrain: 旧转发器无 ssh_user → nil（向后兼容）", legacy.ctx.sshUser == nil)
        } catch {
            check("spoolDrain: TerminalContext 解码套件异常：\(error)", false)
        }

        // ===== 2c. runProcess：正常收输出 + 超时杀 =====
        do {
            let ok = RemoteSpoolDrainer.runProcess(executable: "/bin/echo", arguments: ["spool-ok"], timeout: 5)
            check("spoolDrain: runProcess 收 stdout", ok?.exitCode == 0 && ok?.stdout.contains("spool-ok") == true)
            let killed = RemoteSpoolDrainer.runProcess(executable: "/bin/sleep", arguments: ["5"], timeout: 0.5)
            check("spoolDrain: runProcess 超时返回 nil", killed == nil)
        }

        // ===== 3. forwarder 生成物内容断言 =====
        let forwarder = ClaudeHookPreferences.generateRemoteHelperScriptContent()
        check("spoolDrain: forwarder 含 spool 目录与原子改名落盘",
              forwarder.contains(".vibefocus/spool")
              && forwarder.contains(".tmp-$VF_STAMP")
              && forwarder.contains("mv \"$VF_SPOOL_DIR/.tmp-$VF_STAMP\""))
        check("spoolDrain: forwarder 直投带快速超时（connect-timeout 1）",
              forwarder.contains("--connect-timeout 1") && forwarder.contains("-m 4"))
        check("spoolDrain: forwarder 含 channel-hint 跳过与自愈",
              forwarder.contains("VF_HINT_FILE") && forwarder.contains("VF_HINT_TTL=600"))
        check("spoolDrain: forwarder 上报 ssh_user 供自注册",
              forwarder.contains("whoami") && forwarder.contains("ssh_user"))
        check("spoolDrain[B172]: forwarder 只认 2xx 为已投递（401/404 不再吞事件）",
              forwarder.contains("-w '%{http_code}'")
              && forwarder.contains("case \"$VF_CODE\" in")
              && forwarder.contains("2*)"))
        check("spoolDrain[B172]: forwarder 追加 SSH_CLIENT 自学习候选",
              forwarder.contains("VF_LEARNED=\"${VF_SSHC%% *}\"")
              && forwarder.contains("VF_ORDERED+=(\"$VF_LEARNED\")"))
        check("spoolDrain[B172]: spool 落盘前压平换行（JSONL 契约）",
              forwarder.contains("tr -d '\\r\\n'"))
        check("spoolDrain[B172]: drain 超时后 mux 重置 argv 合法（-- 后置目标）",
              RemoteSpoolDrainLogic.muxResetArguments(target: "cc@1.2.3.4").last == "cc@1.2.3.4"
              && RemoteSpoolDrainLogic.muxResetArguments(target: "cc@1.2.3.4").contains("-O")
              && RemoteSpoolDrainLogic.muxResetArguments(target: "cc@1.2.3.4").contains("exit")
              && RemoteSpoolDrainLogic.muxResetArguments(target: "cc@1.2.3.4").contains("--"))

        // ===== 4. forwarder 沙盒行为测试（假 curl 可控退出/可控状态码）=====
        func makeSandbox() -> (home: String, bin: String, log: String, configPath: String, fwdPath: String, spoolDir: String, hintPath: String) {
            let home = "/tmp/vibefocus-b169-spool-\(UUID().uuidString)"
            let bin = home + "/bin"
            let cfgDir = home + "/.vibefocus"
            try? FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: cfgDir, withIntermediateDirectories: true)
            // forwarder 全部外部命令：python3/cat 真身 + date/mkdir/mv/ls/tail/rm/whoami/tr/curl
            for (name, target) in [("python3", "/usr/bin/python3"), ("cat", "/bin/cat"),
                                   ("date", "/bin/date"), ("mkdir", "/bin/mkdir"),
                                   ("mv", "/bin/mv"), ("ls", "/bin/ls"),
                                   ("tail", "/usr/bin/tail"), ("rm", "/bin/rm"),
                                   ("whoami", "/usr/bin/whoami"), ("tr", "/usr/bin/tr")] {
                try? FileManager.default.createSymbolicLink(atPath: bin + "/" + name, withDestinationPath: target)
            }
            let log = home + "/fake-curl.log"
            // 假 curl：参数逐行记日志；stdout 吐 FAKE_CURL_STATUS（模拟 HTTP 状态码，
            // 缺省 200=投递成功）；退出码 FAKE_CURL_EXIT（缺省 0，非 0=连接层失败）
            let fake = "#!/bin/bash\nfor a in \"$@\"; do printf '%s\\n' \"$a\" >> \"${FAKE_CURL_LOG}\"; done; printf '%s\\n' '---' >> \"${FAKE_CURL_LOG}\"\nprintf '%s' \"${FAKE_CURL_STATUS:-200}\"\nexit ${FAKE_CURL_EXIT:-0}\n"
            FileManager.default.createFile(atPath: bin + "/curl", contents: Data(fake.utf8))
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin + "/curl")
            return (home, bin, log, cfgDir + "/hook-config.json", cfgDir + "/hook-forwarder.sh",
                    cfgDir + "/spool", cfgDir + "/direct-hint")
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
                print("[诊断-spoolDrain] status=\(proc.terminationStatus) child<<\n\(dbg.prefix(600))\n>>")
            }
            return proc.terminationStatus
        }

        func spoolFiles(_ dir: String) -> [String] {
            let urls = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            return urls.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted()
        }

        let payloadA = #"{"event":"UserPromptSubmit","session_id":"sp-1"}"#
        let ctxEnvA = ["TERM_SESSION_ID": "ts-1", "PPID": "4242",
                       "CLAUDE_PROJECT_DIR": "/Users/x/proj-a",
                       "SSH_CLIENT": "192.168.1.37 51111 192.168.1.83 22"]

        // 场景 A：直投失败（假 curl exit 7）→ 事件落盘 spool + 写 hint
        do {
            let (home, bin, log, configPath, fwdPath, spoolDir, hintPath) = makeSandbox()
            defer { try? FileManager.default.removeItem(atPath: home) }
            FileManager.default.createFile(atPath: configPath,
                contents: Data(#"{"host":"127.0.0.1","port":1,"token":"sec-169","machine_label":"remote-server-001"}"#.utf8))
            FileManager.default.createFile(atPath: fwdPath, contents: Data(forwarder.utf8))
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fwdPath)

            var env = ["HOME": home, "FAKE_CURL_LOG": log, "FAKE_CURL_EXIT": "7"]
            env.merge(ctxEnvA) { _, new in new }
            let exit = runForwarder(fwdPath, payload: payloadA, env: env, bin: bin)
            check("spoolDrain[A]: 直投失败仍零错误退出（不吞事件）", exit == 0)
            check("spoolDrain[A]: 直投尝试过（日志非空）", !((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").isEmpty)
            let files = spoolFiles(spoolDir)
            check("spoolDrain[A]: 事件落盘 spool 恰一个 .json", files.count == 1)
            check("spoolDrain[A]: hint 记录失败时刻（纯数字）",
                  (try? String(contentsOfFile: hintPath, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } != nil)
            if let first = files.first,
               let data = FileManager.default.contents(atPath: spoolDir + "/" + first),
               let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let ctx = body["terminal_ctx"] as? [String: Any] {
                check("spoolDrain[A]: spool 载荷为 enriched JSON（事件/label/ssh 上下文）",
                      body["event"] as? String == "UserPromptSubmit"
                      && body["session_id"] as? String == "sp-1"
                      && ctx["machine_label"] as? String == "remote-server-001"
                      && ctx["ssh_server_ip"] as? String == "192.168.1.83"
                      && ctx["ssh_user"] as? String == NSUserName())
                check("spoolDrain[A]: spool 载荷单行（JSONL 拉取契约）",
                      String(data: data, encoding: .utf8)?.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 1)
            } else {
                check("spoolDrain[A]: spool 载荷为 enriched JSON（事件/label/ssh 上下文）", false)
                check("spoolDrain[A]: spool 载荷单行（JSONL 拉取契约）", false)
            }
        }

        // 场景 B：hint 新鲜 → 跳过直投（假 curl 零调用）直接落盘
        do {
            let (home, bin, log, configPath, fwdPath, spoolDir, hintPath) = makeSandbox()
            defer { try? FileManager.default.removeItem(atPath: home) }
            FileManager.default.createFile(atPath: configPath,
                contents: Data(#"{"host":"127.0.0.1","port":1,"token":"t","machine_label":"m1"}"#.utf8))
            FileManager.default.createFile(atPath: fwdPath, contents: Data(forwarder.utf8))
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fwdPath)
            let now = Int(Date().timeIntervalSince1970)
            FileManager.default.createFile(atPath: hintPath, contents: Data("\(now)".utf8))

            let exit = runForwarder(fwdPath, payload: payloadA,
                                    env: ["HOME": home, "FAKE_CURL_LOG": log], bin: bin)
            check("spoolDrain[B]: hint 新鲜零错误退出", exit == 0)
            check("spoolDrain[B]: 直投被跳过（假 curl 零调用）",
                  ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").isEmpty)
            check("spoolDrain[B]: 事件仍落盘不丢", spoolFiles(spoolDir).count == 1)
        }

        // 场景 C：hint 过期 → 自愈重试直投，假 curl 成功 → hint 清除、零落盘
        do {
            let (home, bin, log, configPath, fwdPath, spoolDir, hintPath) = makeSandbox()
            defer { try? FileManager.default.removeItem(atPath: home) }
            FileManager.default.createFile(atPath: configPath,
                contents: Data(#"{"host":"127.0.0.1","port":1,"token":"t","machine_label":"m1"}"#.utf8))
            FileManager.default.createFile(atPath: fwdPath, contents: Data(forwarder.utf8))
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fwdPath)
            let stale = Int(Date().timeIntervalSince1970) - 601
            FileManager.default.createFile(atPath: hintPath, contents: Data("\(stale)".utf8))

            let exit = runForwarder(fwdPath, payload: payloadA,
                                    env: ["HOME": home, "FAKE_CURL_LOG": log], bin: bin)
            check("spoolDrain[C]: hint 过期零错误退出", exit == 0)
            check("spoolDrain[C]: 直投重试（日志非空）",
                  !((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").isEmpty)
            check("spoolDrain[C]: 直投成功 → hint 清除",
                  !FileManager.default.fileExists(atPath: hintPath))
            check("spoolDrain[C]: 直投成功 → 不落盘", spoolFiles(spoolDir).isEmpty)
        }

        // 场景 D：积压挤压——超过 200 上限时只留最新 200（forwarder 新写的必须幸存）
        do {
            let (home, bin, log, configPath, fwdPath, spoolDir, _) = makeSandbox()
            defer { try? FileManager.default.removeItem(atPath: home) }
            FileManager.default.createFile(atPath: configPath,
                contents: Data(#"{"host":"127.0.0.1","port":1,"token":"t","machine_label":"m1"}"#.utf8))
            FileManager.default.createFile(atPath: fwdPath, contents: Data(forwarder.utf8))
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fwdPath)
            try? FileManager.default.createDirectory(atPath: spoolDir, withIntermediateDirectories: true)
            // 205 个陈旧积压（文件名 epoch 前缀远小于当前时间戳，与 mtime 同序）
            let fill = "i=1; while [ $i -le 205 ]; do printf 'x\\n' > \(spoolDir)/1000000000-$i.json; i=$((i+1)); done"
            let filler = Process()
            filler.executableURL = URL(fileURLWithPath: "/bin/bash")
            filler.arguments = ["-c", fill]
            try? filler.run()
            filler.waitUntilExit()

            var env = ["HOME": home, "FAKE_CURL_LOG": log, "FAKE_CURL_EXIT": "7"]
            env.merge(ctxEnvA) { _, new in new }
            _ = runForwarder(fwdPath, payload: payloadA, env: env, bin: bin)
            let files = spoolFiles(spoolDir)
            check("spoolDrain[D]: 积压挤压到 200 上限", files.count == 200)
            check("spoolDrain[D]: 最新事件幸存（陈旧文件先被挤掉）",
                  files.contains { !$0.hasPrefix("1000000000-") })
        }

        // 场景 E（B172）：Mac 应答 401（token 轮换未重部署）→ 不算已投递，
        // 事件落 spool（拉取通道带 Mac 当前 token，自愈）
        do {
            let (home, bin, log, configPath, fwdPath, spoolDir, hintPath) = makeSandbox()
            defer { try? FileManager.default.removeItem(atPath: home) }
            FileManager.default.createFile(atPath: configPath,
                contents: Data(#"{"host":"127.0.0.1","port":1,"token":"old-token","machine_label":"m1"}"#.utf8))
            FileManager.default.createFile(atPath: fwdPath, contents: Data(forwarder.utf8))
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fwdPath)

            let exit = runForwarder(fwdPath, payload: payloadA,
                                    env: ["HOME": home, "FAKE_CURL_LOG": log,
                                          "FAKE_CURL_EXIT": "0", "FAKE_CURL_STATUS": "401"],
                                    bin: bin)
            check("spoolDrain[E]: 401 应答零错误退出", exit == 0)
            check("spoolDrain[E]: 401 不算投递成功 → 事件落盘", spoolFiles(spoolDir).count == 1)
            check("spoolDrain[E]: 401 → hint 记失败时刻（下次免试）",
                  FileManager.default.fileExists(atPath: hintPath))
        }

        // 场景 F（B172）：非 JSON 多行载荷（enrich 回退原样）→ 落盘压平为单行
        do {
            let (home, bin, log, configPath, fwdPath, spoolDir, _) = makeSandbox()
            defer { try? FileManager.default.removeItem(atPath: home) }
            FileManager.default.createFile(atPath: configPath,
                contents: Data(#"{"host":"127.0.0.1","port":1,"token":"t","machine_label":"m1"}"#.utf8))
            FileManager.default.createFile(atPath: fwdPath, contents: Data(forwarder.utf8))
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fwdPath)

            let multiline = "{ \"broken\": \n \"payload with\nnewline\" }"
            var env = ["HOME": home, "FAKE_CURL_LOG": log, "FAKE_CURL_EXIT": "7"]
            env.merge(ctxEnvA) { _, new in new }
            _ = runForwarder(fwdPath, payload: multiline, env: env, bin: bin)
            let files = spoolFiles(spoolDir)
            check("spoolDrain[F]: 多行载荷落盘恰一个文件", files.count == 1)
            if let first = files.first,
               let raw = try? String(contentsOfFile: spoolDir + "/" + first, encoding: .utf8) {
                let lines = raw.components(separatedBy: "\n").filter { !$0.isEmpty }
                check("spoolDrain[F]: spool 内容压平为单行（JSONL 拉取契约）", lines.count == 1)
            } else {
                check("spoolDrain[F]: spool 内容压平为单行（JSONL 拉取契约）", false)
            }
        }

        // 场景 G（B172）：SSH_CLIENT 自学习候选追加在配置候选之后
        check("spoolDrain[G]: 自学习候选源码序在配置候选循环之后（末位兜底）",
              forwarder.range(of: "VF_LEARNED=\"${VF_SSHC%% *}\"")?.lowerBound ?? forwarder.startIndex
              > forwarder.range(of: "for VF_H in \"${VF_HOSTS[@]}\"; do")?.lowerBound ?? forwarder.endIndex)
    }
}
