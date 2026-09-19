import CoreGraphics
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerSessionRestoreTests.swift — 会话恢复 v2（2026-09-13）
// 多屏 × 多工作区 × 多 pane × 本地/远程 Claude 会话。旧「单屏快照 + iTerm2 无 tty +
// 远程无建模」三代根因的整体替换，本文件穷尽锁定新模块纯决策层：
//   SSHCommandParser / PaneClassifier / PaneEnumeration 解析 / RemoteSessionProbe
//   解析与匹配 / SessionCommandBuilder / SessionSnapshotMigrator / SessionRestoreStore.merge
//   / SessionRestorePlanner（display/space 解析 + 活窗联动 + 诚实记账）
extension RunnerHarness {

    func runSessionRestoreTests() {
        runSSHParserTests()
        runPaneClassifierTests()
        runPaneEnumerationTests()
        runPaneEnumerationBuilderTests()
        runRemoteProbeTests()
        runCommandBuilderTests()
        runMigratorTests()
        runStoreMergeTests()
        runRestorePlannerTests()
        runYabaiCaptureFilterTests()
    }

    // MARK: SSH 命令行解析

    private func runSSHParserTests() {
        // isSSHProcess：basename 精确匹配；sshd/sshfs/gnome-ssh-agent 一律拒绝
        check("ssh: 裸 ssh / 路径形 ssh 认定",
              SSHCommandParser.isSSHProcess(commandLine: "ssh user@host")
              && SSHCommandParser.isSSHProcess(commandLine: "/usr/bin/ssh -p 22 host"))
        check("ssh: sshd / sshfs / ssh-agent 不误吞",
              !SSHCommandParser.isSSHProcess(commandLine: "sshd: cc11001100 [priv]")
              && !SSHCommandParser.isSSHProcess(commandLine: "sshfs mount here")
              && !SSHCommandParser.isSSHProcess(commandLine: "/usr/bin/ssh-agent -s"))
        check("ssh: 空行拒绝", !SSHCommandParser.isSSHProcess(commandLine: ""))

        // parseDestination：真机实锚形态（wrapper → ssh -o ... user@IP）
        let real = SSHCommandParser.parseDestination(
            commandLine: "ssh -o StrictHostKeyChecking=no cc11001100@192.168.1.83")
        check("ssh: 真机形态 user@IP", real?.host == "192.168.1.83" && real?.user == "cc11001100"
              && real?.destinationArg == "cc11001100@192.168.1.83" && real?.port == nil)
        // -p 分离/粘写、-l
        let p1 = SSHCommandParser.parseDestination(commandLine: "ssh -p 2222 host")
        let p2 = SSHCommandParser.parseDestination(commandLine: "ssh -p2222 -l alice host")
        check("ssh: -p 分离值", p1?.port == "2222" && p1?.host == "host")
        check("ssh: -p 粘写 + -l user", p2?.port == "2222" && p2?.user == "alice")
        // 带值选项吞值不吞目的地
        let withOpts = SSHCommandParser.parseDestination(
            commandLine: "ssh -i /path/to/key -F /etc/ssh_config -L 8080:localhost:80 -4 host dest")
        check("ssh: -i/-F/-L 选项消化后首个非选项为目的地", withOpts?.host == "host")
        // -o 分离形态
        let oSep = SSHCommandParser.parseDestination(commandLine: "ssh -o ConnectTimeout=4 host")
        check("ssh: -o 带值消化", oSep?.host == "host")
        // ssh:// URL 与 host:port
        check("ssh: ssh:// URL 目的地",
              SSHCommandParser.parseDestination(commandLine: "ssh ssh://bob@example.com:2222")?.port == "2222")
        check("ssh: host:port 数字端口拆出",
              SSHCommandParser.parseDestination(commandLine: "ssh example.com:2200")?.port == "2200")
        // -- 终结选项后目的地
        check("ssh: -- 终结符后目的地",
              SSHCommandParser.parseDestination(commandLine: "ssh -t -- host")?.host == "host")
        // 目的地后跟远端命令（非交互 pane）仍解析
        let withCmd = SSHCommandParser.parseDestination(commandLine: "ssh host cd /tmp && run")
        check("ssh: 目的地后远端命令仍解析", withCmd?.host == "host")
        // 无目的地 → nil
        check("ssh: 全选项无目的地 → nil",
              SSHCommandParser.parseDestination(commandLine: "ssh -v -4") == nil)
    }

    // MARK: pane 进程分类

    private func runPaneClassifierTests() {
        // 真机实锚 tty：login → -zsh → wrapper bash → ssh
        let remoteTTY = [
            " 3980 login -fp cc11001100",
            " 3981 -zsh",
            "51478 /bin/bash /Users/cc11001100/bin/l1",
            "51484 /bin/bash /Users/cc11001100/bin/login-local-server-001",
            "51485 ssh -o StrictHostKeyChecking=no cc11001100@192.168.1.83",
        ]
        let remote = PaneClassifier.classify(processLines: remoteTTY)
        check("分类: ssh pane（login/-zsh/wrapper 不干扰）",
              remote.kind == .remoteSSH && remote.sshTarget == "cc11001100@192.168.1.83"
              && remote.sshCommand?.contains("StrictHostKeyChecking=no") == true)
        // 本机 claude 优先
        let local = PaneClassifier.classify(processLines: [
            "  100 -zsh",
            "  101 /Users/x/.local/bin/claude --resume abc",
        ])
        check("分类: 本机 claude", local.kind == .localClaude && local.pid == 101)
        // 纯 shell（登录 shell 剥前导 '-'、路径形 basename）
        let shell = PaneClassifier.classify(processLines: [
            "  200 login -fp cc",
            "  201 /bin/zsh",
        ])
        check("分类: 纯 shell", shell.kind == .shell && shell.pid == 201)
        // 空表 → shell 无 pid
        check("分类: 空 ps → shell 无 pid",
              PaneClassifier.classify(processLines: []).kind == .shell
              && PaneClassifier.classify(processLines: []).pid == nil)
    }

    // MARK: pane 枚举解析

    /// B214 覆盖补强：PaneEnumeration 脚本构建器族 + Terminal.app tab 解析
    ///（基线缺口：itermEnumerateSessions 文本/四个注入脚本构建器/parseTerminalTabTTYs）
    private func runPaneEnumerationBuilderTests() {
        // A. 枚举脚本构建：iTerm2 AppleScript 形状锁定（解析端与产出端同源演化的锚）
        do {
            let script = PaneEnumeration.itermEnumerateSessions()
            check("paneBuilder A1: 枚举脚本含 iTerm2 应用定位与三层循环",
                  script.contains(#"tell application id "com.googlecode.iterm2""#)
                  && script.contains("repeat with w in windows")
                  && script.contains("repeat with t in tabs of w")
                  && script.contains("repeat with s in sessions of t"))
            check("paneBuilder A2: 行协议七段齐备（winID|tab|sess|tty|bounds|name）",
                  script.contains(#""|" & tabIdx & "|" & sessIdx & "|"#)
                  && script.contains("tty of s")
                  && script.contains("name of s"))
        }

        // B. 注入脚本构建器族
        do {
            let appendTab = PaneEnumeration.itermAppendTab(windowASID: "42", command: "echo hi")
            check("paneBuilder B1: appendTab 定位窗+建 tab+写命令",
                  appendTab.contains("tell window id 42")
                  && appendTab.contains("create tab with default profile")
                  && appendTab.contains(#"write text "echo hi""#))

            let writeSession = PaneEnumeration.itermWriteToSession(
                windowASID: "42", tabIndex: 1, sessionIndex: 2, command: "echo hi")
            check("paneBuilder B2: writeSession 按 tab/session 序定位",
                  writeSession.contains("tell session 2 of tab 1 of window id 42")
                  && writeSession.contains(#"write text "echo hi""#))

            let escaped = PaneEnumeration.itermAppendTab(windowASID: "7", command: "say \"ok\"")
            check("paneBuilder B3: 命令经 appleScriptEscaped 转义引号",
                  escaped.contains(#"write text "say \"ok\"""#))

            let writeWindow = PaneEnumeration.itermWriteToWindow(windowASID: "9", command: "cd /tmp")
            check("paneBuilder B4: 窗级注入委托 TerminalAutomationScript（命令与窗 id 在场）",
                  writeWindow.contains("9") && writeWindow.contains("cd /tmp"))

            let terminalWrite = PaneEnumeration.terminalWriteToWindow(windowCGID: 55, command: "ls -la")
            check("paneBuilder B5: Terminal.app 注入含 CG 窗 id 与命令",
                  terminalWrite.contains("55") && terminalWrite.contains("ls -la"))
        }

        // C. parseTerminalTabTTYs：聚合/防御全分支
        do {
            let out = PaneEnumeration.parseTerminalTabTTYs("""
                12|/dev/ttys001
                12|ttys002
                abc|ttys003
                |ttys004
                30|
                99|/dev/ttys003|extra
                """)
            check("paneBuilder C1: 同窗多 tab 有序聚合 + 缺 /dev/ 前缀补全",
                  out[12] == ["/dev/ttys001", "/dev/ttys002"])
            check("paneBuilder C2: 非法窗 id/空窗 id/空 tty 三类跳过",
                  out[30] == nil && out.count == 2)
            check("paneBuilder C3: tty 含 | 不撕列（首个 | 后整段保留）",
                  out[99] == ["/dev/ttys003|extra"])
        }
    }

    private func runPaneEnumerationTests() {
        // iTerm2 行：ASwinID|tab|sess|tty|l,t,r,b|name
        let line1 = "2520|1|1|/dev/ttys047|966,-528,1606,0|cc11001100"
        let line2 = "561|2|3|ttys023|325,-528,964,0|ssh|weird|name"
        let entries = PaneEnumeration.parseITermSessions([line1, line2, "bad line", "", "x|1|1|tty|1,2,3|n"].joined(separator: "\n"))
        check("iTerm 枚举: 正常行解析（bounds 转 rect）",
              entries.count == 2
              && entries[0].windowASID == "2520"
              && entries[0].windowBounds == CGRect(x: 966, y: -528, width: 640, height: 528)
              && entries[0].tty == "/dev/ttys047")
        check("iTerm 枚举: tty 缺 /dev/ 补全 + name 含 | 不撕列",
              entries[1].tty == "/dev/ttys023" && entries[1].name == "ssh|weird|name"
              && entries[1].tabIndex == 2 && entries[1].sessionIndex == 3)
        // 就近匹配：同屏多候选 + used 排除 + 超差拒配
        let cands: [(windowASID: String, bounds: CGRect)] = [
            ("a", CGRect(x: 0, y: 0, width: 640, height: 528)),
            ("b", CGRect(x: 8, y: 0, width: 640, height: 528)),
        ]
        check("iTerm 匹配: 就近选 a",
              PaneEnumeration.matchITermWindow(cgFrame: CGRect(x: 0, y: 0, width: 640, height: 528),
                                               candidates: cands, usedASIDs: []) == "a")
        check("iTerm 匹配: used 排除后次近 b 补位",
              PaneEnumeration.matchITermWindow(cgFrame: CGRect(x: 0, y: 0, width: 640, height: 528),
                                               candidates: cands, usedASIDs: ["a"]) == "b")
        check("iTerm 匹配: 全部超差 → nil",
              PaneEnumeration.matchITermWindow(cgFrame: CGRect(x: 5000, y: 5000, width: 640, height: 528),
                                               candidates: cands, usedASIDs: []) == nil)
        // Terminal 多 tab tty 表
        let ttyMap = PaneEnumeration.parseTerminalTabTTYs("101|ttys001\n101|ttys002\n202|/dev/ttys003\nbad|\n303|")
        check("Terminal 枚举: 同窗多 tab 聚序 + 前缀补全",
              ttyMap[101] == ["/dev/ttys001", "/dev/ttys002"] && ttyMap[202] == ["/dev/ttys003"]
              && ttyMap[303] == nil)
    }

    // MARK: 远程探针

    private func runRemoteProbeTests() {
        check("探针: 脚本单引号契约（外层 sh -c 包裹完整性）",
              RemoteSessionProbe.scriptHasNoSingleQuotes())
        // ⚠️ Swift 字面量转义回归锁（2026-09-14 真机 E2E 产品 bug）：grep 模式必须
        // 含 shell 层 `\"`（字节级反斜杠+引号）。Swift 源码写 `\"` 会被编译期吞成
        // 裸 `"`，远端 sh 语法错误 → 探针恒空 → remoteLive 恒 0、远程恢复整体降级
        // 裸回放——此断言锁的是脚本字节，不是语义等价物。
        check("探针: grep 模式含 shell 层 \\\" 字面反斜杠（Swift 转义吞反斜杠回归锁）",
              RemoteSessionProbe.probeScript.contains("\\\"cwd\\\":\\\"[^\\\"]*\\\"")
              && !RemoteSessionProbe.probeScript.contains("\"\"cwd"))
        check("探针: 单行 sh -c 包裹形态",
              RemoteSessionProbe.remoteCommand.hasPrefix("sh -c '")
              && RemoteSessionProbe.remoteCommand.hasSuffix("'"))

        // 传输重试语义（2026-09-14 真机实锤 TUN 代理间歇秒断 255）：首次失败第二次
        // 成功 → 捞回；双失败 → 空表；exit 0 空表 = 远端真没会话，不烧第二次
        let goodOut = "PROJ|-tmp/|68560ea4-14a7-411c-aed2-d40df38ccbb9.jsonl|\"cwd\":\"/tmp\""
        do {
            var calls = 0
            let entries = RemoteSessionProbe.probe(target: "u@h", port: nil, runner: { _, _, _ in
                calls += 1
                return calls == 1
                    ? YabaiClient.YabaiResult(exitCode: 255, stdout: "", stderr: "Connection closed by 198.18.0.205")
                    : YabaiClient.YabaiResult(exitCode: 0, stdout: goodOut, stderr: "")
            })
            check("探针: 传输秒断后重试一次捞回", entries.count == 1 && entries[0].cwd == "/tmp" && calls == 2)
        }
        do {
            var calls = 0
            let entries = RemoteSessionProbe.probe(target: "u@h", port: nil, runner: { _, _, _ in
                calls += 1
                return YabaiClient.YabaiResult(exitCode: 255, stdout: "", stderr: "closed")
            })
            check("探针: 双失败诚实空表", entries.isEmpty && calls == 2)
        }
        do {
            var calls = 0
            let entries = RemoteSessionProbe.probe(target: "u@h", port: nil, runner: { _, _, _ in
                calls += 1
                return YabaiClient.YabaiResult(exitCode: 0, stdout: "", stderr: "")
            })
            check("探针: exit 0 空输出不重试（远端真无会话）", entries.isEmpty && calls == 1)
        }
        let out = [
            "PROJ|-home-cc11001100-github-aigchub-repos-chat-show/|46fb8e4c-3939-4b17-9fec-96f959368588.jsonl|\"cwd\":\"/home/cc11001100/github/aigchub-repos/chat-show\"",
            "PROJ|-private-tmp/|a0a41632-d0a6-47e6-860e-a8791bd0ba44.jsonl|",
            "noise line",
            "PROJ||x.jsonl|",
        ].joined(separator: "\n")
        let entries = RemoteSessionProbe.parseProbeOutput(out)
        check("探针: cwd 真值抽取 + 尾斜杠剥离",
              entries.count == 2
              && entries[0].projectDir == "-home-cc11001100-github-aigchub-repos-chat-show"
              && entries[0].cwd == "/home/cc11001100/github/aigchub-repos/chat-show"
              && entries[1].cwd == nil)
        check("探针: cwd 段形态校验",
              RemoteSessionProbe.parseCWDField("\"cwd\":\"/x y\"") == "/x y"
              && RemoteSessionProbe.parseCWDField("\"cwd\":\"\"") == nil
              && RemoteSessionProbe.parseCWDField("garbage") == nil
              && RemoteSessionProbe.parseCWDField(nil) == nil)
        // 匹配链：cwd 转义精确 > 标题后缀唯一 > 单项目 > 无信号 nil
        let pool = [
            RemoteSessionEntry(projectDir: "-home-cc-github-chat-show", sessionID: "sid-chat", cwd: "/home/cc/github/chat-show"),
            RemoteSessionEntry(projectDir: "-home-cc-github-ai-cex", sessionID: "sid-cex", cwd: "/home/cc/github/ai-cex"),
            RemoteSessionEntry(projectDir: "-home-cc-unique-proj", sessionID: "sid-uniq", cwd: nil),
        ]
        check("探针匹配: cwd 正向转义精确命中",
              RemoteSessionProbe.matchSession(remoteCWD: "/home/cc/github/ai-cex", paneTitle: nil, entries: pool)?.sessionID == "sid-cex")
        check("探针匹配: cwd 已知但不匹配 → 不猜",
              RemoteSessionProbe.matchSession(remoteCWD: "/home/cc/other", paneTitle: "chat-show", entries: pool) == nil)
        check("探针匹配: 标题后缀唯一命中",
              RemoteSessionProbe.matchSession(remoteCWD: nil, paneTitle: "chat-show", entries: pool)?.sessionID == "sid-chat")
        check("探针匹配: 单项目直取",
              RemoteSessionProbe.matchSession(remoteCWD: nil, paneTitle: nil, entries: [pool[2]])?.sessionID == "sid-uniq")
        check("探针匹配: 多项目无信号 → nil（宁缺毋错）",
              RemoteSessionProbe.matchSession(remoteCWD: nil, paneTitle: nil, entries: pool) == nil)
    }

    // MARK: 恢复命令构建

    private func runCommandBuilderTests() {
        check("命令: 本地 claude = cd + resume（含空格目录单引号）",
              SessionCommandBuilder.localCommand(cwd: "/Users/x/My Dir", sessionID: "abc-123", fallback: nil)
              == "cd '/Users/x/My Dir' && claude --resume abc-123")
        check("命令: shell + 启动命令偏好",
              SessionCommandBuilder.shellCommand(cwd: "/tmp", launchCommand: "claude") == "cd '/tmp' && claude")
        check("命令: sessionID 非法字符拒绝注入（退化为 cd）",
              SessionCommandBuilder.localCommand(cwd: "/tmp", sessionID: "x; rm -rf /", fallback: nil) == "cd '/tmp'")
        check("命令: isSafeSessionID 边界",
              SessionCommandBuilder.isSafeSessionID("46fb8e4c-3939-4b17-9fec-96f959368588")
              && !SessionCommandBuilder.isSafeSessionID("")
              && !SessionCommandBuilder.isSafeSessionID("a b")
              && !SessionCommandBuilder.isSafeSessionID("$(reboot)"))
        // 远程：定位到会话 → ssh -p -t target '远端命令'（单引号包裹，内部再单引号转义）
        let remotePane = SessionPaneSnapshot(
            kind: .remoteSSH, sessionID: "sid-1",
            cwd: "/home/cc/my dir",
            sshCommand: "ssh -o StrictHostKeyChecking=no -p 2222 cc@1.2.3.4",
            sshTarget: "cc@1.2.3.4")
        let remoteCmd = SessionCommandBuilder.paneCommand(remotePane, launchCommand: nil) ?? ""
        check("命令: 远程 resume 组合（-p 端口 + -t + 单引号远端段）",
              remoteCmd == "ssh -p 2222 -t cc@1.2.3.4 'cd '\''/home/cc/my dir'\'' && claude --resume sid-1'"
              || remoteCmd == "ssh -p 2222 -t cc@1.2.3.4 'cd '\\''/home/cc/my dir'\\'' && claude --resume sid-1'",
              )
        // 远程无会话：原样回放捕获命令行（保真降级）
        let replayPane = SessionPaneSnapshot(kind: .remoteSSH, sshCommand: "ssh -o X=y cc@1.2.3.4", sshTarget: "cc@1.2.3.4")
        check("命令: 远程无会话原样回放",
              SessionCommandBuilder.paneCommand(replayPane, launchCommand: nil) == "ssh -o X=y cc@1.2.3.4")
        // 远程无会话无原始命令：裸 ssh -t target
        let barePane = SessionPaneSnapshot(kind: .remoteSSH, sshTarget: "cc@1.2.3.4")
        check("命令: 远程裸 ssh 降级", SessionCommandBuilder.paneCommand(barePane, launchCommand: nil) == "ssh -t cc@1.2.3.4")
        // 窗口级：首 pane 建窗 + 附加 pane 列表
        let window = SessionWindowSnapshot(
            appBundleID: "com.googlecode.iterm2",
            frame: CGRect(x: 0, y: 0, width: 800, height: 500),
            displayID: 1,
            panes: [
                SessionPaneSnapshot(kind: .localClaude, sessionID: "s1", cwd: "/a"),
                SessionPaneSnapshot(kind: .shell, cwd: "/b"),
                SessionPaneSnapshot(kind: .shell, cwd: nil),
            ])
        check("命令: 窗口首 pane 与附加 pane 序列",
              SessionCommandBuilder.windowCommand(window, launchCommand: nil) == "cd '/a' && claude --resume s1"
              && SessionCommandBuilder.additionalPaneCommands(window, launchCommand: nil).count == 2
              && SessionCommandBuilder.additionalPaneCommands(window, launchCommand: nil)[0] == "cd '/b'"
              && SessionCommandBuilder.additionalPaneCommands(window, launchCommand: nil)[1] == nil)
    }

    // MARK: 旧快照迁移

    private func runMigratorTests() {
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy = TerminalGridSnapshot(
            id: "legacy-1", name: "旧快照", appBundleID: "com.googlecode.iterm2",
            displayID: 7, displayYabaiIndex: 2, rows: 2, cols: 2,
            cells: [
                TerminalGridCellSnapshot(index: 0, x: 0, y: 0, width: 800, height: 500,
                                         ttyPath: "/dev/ttys001", sessionID: "sid-a", cwd: "/a", title: "t1"),
                TerminalGridCellSnapshot(index: 1, x: 808, y: 0, width: 800, height: 500,
                                         ttyPath: nil, sessionID: nil, cwd: nil, title: nil),
            ],
            launchCommand: "claude", capturedAt: capturedAt)
        let migrated = SessionSnapshotMigrator.migrateLegacy(legacy)
        check("迁移: id/名称/时间/启动命令无损",
              migrated.id == "legacy-1" && migrated.name == "旧快照"
              && migrated.capturedAt == capturedAt && migrated.launchCommand == "claude"
              && migrated.formatVersion == SessionRestoreSnapshot.currentFormatVersion)
        check("迁移: claude 格 → localClaude 单 pane（tty/session/cwd 平移）",
              migrated.windows.count == 2
              && migrated.windows[0].panes.count == 1
              && migrated.windows[0].panes[0].kind == .localClaude
              && migrated.windows[0].panes[0].sessionID == "sid-a"
              && migrated.windows[0].panes[0].tty == "/dev/ttys001"
              && migrated.windows[0].panes[0].cwd == "/a")
        check("迁移: 窗口归属屏平移 + 无 Space（落到可见工作区）",
              migrated.windows[0].displayID == 7 && migrated.windows[0].yabaiDisplay == 2
              && migrated.windows[0].yabaiSpace == nil
              && migrated.windows[0].frame == CGRect(x: 0, y: 0, width: 800, height: 500))
        check("迁移: 纯 shell 格语义保留",
              migrated.windows[1].panes[0].kind == .shell && migrated.windows[1].panes[0].tty == nil)
    }

    // MARK: 存储合并视图

    private func runStoreMergeTests() {
        let v2 = SessionRestoreSnapshot(id: "v2-1", name: "新", windows: [], launchCommand: nil)
        let v2SameID = SessionRestoreSnapshot(id: "v2-1", name: "新版", windows: [], launchCommand: nil)
        let legacyConverted = SessionRestoreSnapshot(id: "v2-1", name: "旧版同 id", windows: [], launchCommand: nil)
        let legacyOther = SessionRestoreSnapshot(id: "v2-2", name: "旧版独有", windows: [], launchCommand: nil)
        let merged = SessionRestoreStore.merge(v2: [v2SameID], legacyConverted: [legacyConverted, legacyOther])
        check("存储: 同 id v2 优先 + legacy 独有尾随",
              merged.map(\.name) == ["新版", "旧版独有"])
        check("存储: 空并空 → 空",
              SessionRestoreStore.merge(v2: [], legacyConverted: []).isEmpty)
        _ = v2
    }

    // MARK: 恢复规划器

    private func makeWindow(
        frame: CGRect, displayID: UInt32, yabaiDisplay: Int? = 1, yabaiSpace: Int? = 2,
        appBundleID: String = "com.googlecode.iterm2", minimized: Bool = false,
        panes: [SessionPaneSnapshot]
    ) -> SessionWindowSnapshot {
        SessionWindowSnapshot(
            appBundleID: appBundleID, frame: frame, displayID: displayID,
            yabaiDisplay: yabaiDisplay, yabaiSpace: yabaiSpace,
            wasMinimized: minimized, panes: panes)
    }

    private func runRestorePlannerTests() {
        let pane = SessionPaneSnapshot(kind: .localClaude, sessionID: "s1", cwd: "/a")
        let window = makeWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 500), displayID: 1, panes: [pane])
        let snapshot = SessionRestoreSnapshot(name: "p", windows: [window], launchCommand: nil)

        func env(
            displays: Set<UInt32> = [1, 2],
            byYabai: [Int: UInt32] = [1: 1, 2: 2],
            primary: UInt32? = 1,
            spaces: Set<Int> = [2, 3],
            visible: [Int: Int] = [1: 2, 2: 5],
            live: [SessionRestorePlanner.ObservedLiveWindow] = []
        ) -> (Set<UInt32>, [Int: UInt32], UInt32?, Set<Int>, [Int: Int], [SessionRestorePlanner.ObservedLiveWindow]) {
            (displays, byYabai, primary, spaces, visible, live)
        }

        // 全新环境（重启后）：create + 目标 1 屏 2 工作区 + 无降级注记
        let (displays, byYabai, primary, spaces, visible, live) = env()
        let plan = SessionRestorePlanner.plan(
            snapshot: snapshot, existingDisplayIDs: displays, displayIDByYabaiIndex: byYabai,
            primaryDisplayID: primary, existingSpaceIndices: spaces,
            visibleSpaceByYabaiDisplay: visible, liveWindows: live, launchCommand: nil)
        check("规划: 重启后全新建窗（命令进动作）",
              plan.refusal == nil && plan.items.count == 1
              && plan.items[0].action == .create(commands: ["cd '/a' && claude --resume s1"])
              && plan.items[0].targetYabaiDisplay == 1 && plan.items[0].targetYabaiSpace == 2
              && plan.items[0].notes.isEmpty)

        // 显示器失效：yabai 屏序映射；再失效：主屏兜底；全失效：skipUnplaceable
        let lostWindow = makeWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 500), displayID: 9, yabaiDisplay: 2, panes: [pane])
        let lostSnapshot = SessionRestoreSnapshot(name: "lost", windows: [lostWindow], launchCommand: nil)
        let remapped = SessionRestorePlanner.plan(
            snapshot: lostSnapshot, existingDisplayIDs: [1], displayIDByYabaiIndex: [2: 1],
            primaryDisplayID: 1, existingSpaceIndices: spaces, visibleSpaceByYabaiDisplay: [2: 5],
            liveWindows: [], launchCommand: nil)
        check("规划: 原屏失效按 yabai 屏序重映射",
              remapped.items[0].targetYabaiDisplay == 2
              && remapped.items[0].notes.contains("显示器已变化，按 yabai 屏序映射到当前对应屏"))
        let toPrimary = SessionRestorePlanner.plan(
            snapshot: lostSnapshot, existingDisplayIDs: [1], displayIDByYabaiIndex: [:],
            primaryDisplayID: 1, existingSpaceIndices: spaces, visibleSpaceByYabaiDisplay: [1: 2],
            liveWindows: [], launchCommand: nil)
        check("规划: 映射失效改投主屏（无 yabai 映射时投递目标如实为 nil）",
              toPrimary.items[0].action == .create(commands: ["cd '/a' && claude --resume s1"])
              && toPrimary.items[0].notes.contains("原显示器不在场，改投主屏"))
        let noScreen = SessionRestorePlanner.plan(
            snapshot: lostSnapshot, existingDisplayIDs: [], displayIDByYabaiIndex: [:],
            primaryDisplayID: nil, existingSpaceIndices: spaces, visibleSpaceByYabaiDisplay: [:],
            liveWindows: [], launchCommand: nil)
        check("规划: 无屏可投 → skipUnplaceable",
              noScreen.items[0].action == .skipUnplaceable(reason: "无可用显示器"))

        // 工作区失效：落到目标屏可见工作区 + 注记
        let goneSpaceWindow = makeWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 500), displayID: 1, yabaiSpace: 9, panes: [pane])
        let goneSpace = SessionRestorePlanner.plan(
            snapshot: SessionRestoreSnapshot(name: "g", windows: [goneSpaceWindow], launchCommand: nil),
            existingDisplayIDs: displays, displayIDByYabaiIndex: byYabai, primaryDisplayID: primary,
            existingSpaceIndices: spaces, visibleSpaceByYabaiDisplay: visible, liveWindows: [], launchCommand: nil)
        check("规划: 工作区已消失 → 落该屏可见工作区",
              goneSpace.items[0].targetYabaiSpace == 2
              && goneSpace.items[0].notes.contains("原工作区 Space 9 已不存在")
              && goneSpace.items[0].notes.contains("落到该屏当前工作区 Space 2"))

        // 活窗联动：本地 claude 活 → skipAlive；ssh 活 → skipAlive；空闲 → inject；无匹配 → create
        let idleLive = SessionRestorePlanner.ObservedLiveWindow(
            cgWindowID: 501, frame: CGRect(x: 2, y: 2, width: 800, height: 500),
            appBundleID: "com.googlecode.iterm2", itermWindowASID: "777",
            panes: [SessionRestorePlanner.ObservedLivePane(tty: "/dev/ttys009", hasLocalClaude: false, hasSSH: false)],
            paneCoords: [0: SessionRestorePlanner.PaneCoord(tabIndex: 1, sessionIndex: 1)])
        let busyLive = SessionRestorePlanner.ObservedLiveWindow(
            cgWindowID: 502, frame: CGRect(x: 2, y: 2, width: 800, height: 500),
            appBundleID: "com.googlecode.iterm2", itermWindowASID: "778",
            panes: [SessionRestorePlanner.ObservedLivePane(tty: "/dev/ttys010", hasLocalClaude: true, hasSSH: false)])
        let sshLive = SessionRestorePlanner.ObservedLiveWindow(
            cgWindowID: 503, frame: CGRect(x: 2, y: 2, width: 800, height: 500),
            appBundleID: "com.googlecode.iterm2", itermWindowASID: "779",
            panes: [SessionRestorePlanner.ObservedLivePane(tty: "/dev/ttys011", hasLocalClaude: false, hasSSH: true)])
        let withLives = SessionRestorePlanner.plan(
            snapshot: snapshot, existingDisplayIDs: displays, displayIDByYabaiIndex: byYabai,
            primaryDisplayID: primary, existingSpaceIndices: spaces, visibleSpaceByYabaiDisplay: visible,
            liveWindows: [idleLive, busyLive, sshLive], launchCommand: nil)
        check("规划: 空闲活窗 → inject（带 AS id）",
              withLives.items[0].action == .inject(windowID: 501, itermWindowASID: "777", commands: ["cd '/a' && claude --resume s1"]))
        let busySnap = SessionRestoreSnapshot(name: "b", windows: [
            makeWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 500), displayID: 1, panes: [pane]),
            makeWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 500), displayID: 1, panes: [
                SessionPaneSnapshot(kind: .remoteSSH, sshCommand: "ssh cc@h", sshTarget: "cc@h")]),
        ], launchCommand: nil)
        let busyPlan = SessionRestorePlanner.plan(
            snapshot: busySnap, existingDisplayIDs: displays, displayIDByYabaiIndex: byYabai,
            primaryDisplayID: primary, existingSpaceIndices: spaces, visibleSpaceByYabaiDisplay: visible,
            liveWindows: [busyLive, sshLive], launchCommand: nil)
        check("规划: 会话仍在跑/远程挂线 → skipAlive",
              busyPlan.items[0].action == .skipAlive(reason: "会话仍在跑")
              && busyPlan.items[1].action == .skipAlive(reason: "远程会话挂线中"))
        // 活窗不重复认领：第二个同位窗 create
        let twinSnap = SessionRestoreSnapshot(name: "twin", windows: [
            makeWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 500), displayID: 1, panes: [pane]),
            makeWindow(frame: CGRect(x: 2, y: 2, width: 800, height: 500), displayID: 1, panes: [pane]),
        ], launchCommand: nil)
        let twinPlan = SessionRestorePlanner.plan(
            snapshot: twinSnap, existingDisplayIDs: displays, displayIDByYabaiIndex: byYabai,
            primaryDisplayID: primary, existingSpaceIndices: spaces, visibleSpaceByYabaiDisplay: visible,
            liveWindows: [busyLive], launchCommand: nil)
        check("规划: 活窗只被认领一次",
              twinPlan.items[0].action == .skipAlive(reason: "会话仍在跑")
              && twinPlan.items[1].action == .create(commands: ["cd '/a' && claude --resume s1"]))
        // 最小化注记
        let minPlan = SessionRestorePlanner.plan(
            snapshot: SessionRestoreSnapshot(name: "m", windows: [
                makeWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 500), displayID: 1, minimized: true, panes: [pane])
            ], launchCommand: nil),
            existingDisplayIDs: displays, displayIDByYabaiIndex: byYabai, primaryDisplayID: primary,
            existingSpaceIndices: spaces, visibleSpaceByYabaiDisplay: visible, liveWindows: [], launchCommand: nil)
        check("规划: 最小化状态不还原（注记交代）",
              minPlan.items[0].notes.contains("捕获时该窗处于最小化，恢复为普通窗口"))

        // 风暴护栏
        let flood = SessionRestoreSnapshot(name: "flood", windows: (0..<65).map { _ in
            makeWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 500), displayID: 1, panes: [pane])
        }, launchCommand: nil)
        let floodPlan = SessionRestorePlanner.plan(
            snapshot: flood, existingDisplayIDs: displays, displayIDByYabaiIndex: byYabai,
            primaryDisplayID: primary, existingSpaceIndices: spaces, visibleSpaceByYabaiDisplay: visible,
            liveWindows: [], launchCommand: nil)
        check("规划: 超上限整体拒绝（防窗口风暴）",
              floodPlan.refusal?.contains("已拒绝恢复") == true && floodPlan.items.isEmpty)

        // 汇总诚实记账：去重聚合计数
        let mixed = SessionRestoreSnapshot(name: "mix", windows: [
            makeWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 500), displayID: 9, yabaiDisplay: 2, panes: [pane]),
            makeWindow(frame: CGRect(x: 810, y: 0, width: 800, height: 500), displayID: 9, yabaiDisplay: 2, panes: [pane]),
            makeWindow(frame: CGRect(x: 1620, y: 0, width: 800, height: 500), displayID: 1, panes: [pane]),
        ], launchCommand: nil)
        let mixedPlan = SessionRestorePlanner.plan(
            snapshot: mixed, existingDisplayIDs: [1], displayIDByYabaiIndex: [2: 1],
            primaryDisplayID: 1, existingSpaceIndices: spaces, visibleSpaceByYabaiDisplay: [2: 5],
            liveWindows: [], launchCommand: nil)
        let summary = SessionRestorePlanner.summaryMessage(plan: mixedPlan, snapshotWindowCount: mixed.windows.count)
        check("汇总: 新建计数 + 降级注记聚合去重",
              summary.contains("新建 3 窗")
              && summary.contains("显示器已变化，按 yabai 屏序映射到当前对应屏（2 窗）"))
        let emptySummary = SessionRestorePlanner.summaryMessage(
            plan: SessionRestorePlanner.Plan(items: [], refusal: nil), snapshotWindowCount: 0)
        check("汇总: 空计划兜底文案", emptySummary == "快照没有可恢复的窗口")
        check("汇总: 拒绝原样透出",
              SessionRestorePlanner.summaryMessage(
                plan: SessionRestorePlanner.Plan(items: [], refusal: "拒绝"), snapshotWindowCount: 0) == "拒绝")
    }

    // MARK: yabai 捕获过滤（替代旧 CG isOnScreen 过滤——跨屏跨工作区的存在前提）

    private func runYabaiCaptureFilterTests() {
        func frame(_ w: Double, _ h: Double) -> YabaiWindowInfo.Frame { YabaiWindowInfo.Frame(x: 0, y: 0, w: w, h: h) }
        func window(pid: Int?, w: Double = 800, h: Double = 500) -> YabaiWindowInfo {
            YabaiWindowInfo(id: 1, pid: pid, app: "iTerm2", title: nil, space: 1, display: 1,
                            frame: frame(w, h), isFloatingRaw: false, hasAXReferenceRaw: true)
        }
        let iterm: (pid_t) -> String? = { _ in "com.googlecode.iterm2" }
        let chrome: (pid_t) -> String? = { _ in "com.google.Chrome" }
        check("yabaiCapture: 终端窗 + 合格尺寸 → 通过",
              SessionRestoreController.isCapturableYabaiWindow(window(pid: 100), bundleIDOf: iterm))
        check("yabaiCapture: 非终端 owner / 小窗 / 无 frame / 无 pid 拒绝",
              !SessionRestoreController.isCapturableYabaiWindow(window(pid: 100), bundleIDOf: chrome)
              && !SessionRestoreController.isCapturableYabaiWindow(window(pid: 100, w: 99, h: 99), bundleIDOf: iterm)
              && !SessionRestoreController.isCapturableYabaiWindow(
                YabaiWindowInfo(id: 1, pid: 100, app: "iTerm2", title: nil, space: 1, display: 1,
                                frame: nil, isFloatingRaw: false, hasAXReferenceRaw: true),
                bundleIDOf: iterm)
              && !SessionRestoreController.isCapturableYabaiWindow(window(pid: nil), bundleIDOf: iterm))
    }
}

extension RunnerHarness {
    /// B224：快照模型纯计算属性直测——frame setter、三计数属性、迁移器
    /// shell-with-tty 分支此前零覆盖（E2E 有消费但默认 Runner 不跑 E2E 模式）。
    func runSessionRestoreModelCountsTests() {
        print("\n=== SessionRestoreModelCounts (B224) ===")

        // --- frame setter：get/set 往返四分量保真 ---
        var win = SessionWindowSnapshot(
            appBundleID: "com.apple.Terminal",
            frame: CGRect(x: 1, y: 2, width: 3, height: 4),
            displayID: 1,
            panes: []
        )
        win.frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        check("modelCounts: frame setter 四分量落账",
              win.x == 10 && win.y == 20 && win.width == 300 && win.height == 200)
        check("modelCounts: frame getter 重建一致",
              win.frame == CGRect(x: 10, y: 20, width: 300, height: 200))

        // --- 三计数属性：去重/nil 不计/空表语义 ---
        func pane(_ sessionID: String?) -> SessionPaneSnapshot {
            SessionPaneSnapshot(kind: .localClaude, sessionID: sessionID)
        }
        let snap = SessionRestoreSnapshot(
            name: "counts",
            windows: [
                SessionWindowSnapshot(appBundleID: "a", frame: .zero, displayID: 1, yabaiSpace: 2, panes: [pane("s1"), pane("s2"), pane(nil)]),
                SessionWindowSnapshot(appBundleID: "a", frame: .zero, displayID: 1, yabaiSpace: 2, panes: [pane("s3")]),
                SessionWindowSnapshot(appBundleID: "a", frame: .zero, displayID: 7, yabaiSpace: nil, panes: [pane("s4"), pane("s5")]),
            ],
            launchCommand: nil
        )
        check("modelCounts: sessionPaneCount 只数带会话 pane", snap.sessionPaneCount == 5)
        check("modelCounts: spaceCount 去重且 nil space 不计", snap.spaceCount == 1)
        check("modelCounts: displayCount 去重两屏", snap.displayCount == 2)
        let empty = SessionRestoreSnapshot(name: "empty", windows: [], launchCommand: nil)
        check("modelCounts: 空快照三计数全 0",
              empty.sessionPaneCount == 0 && empty.spaceCount == 0 && empty.displayCount == 0)

        // --- 迁移器 shell-with-tty 分支：无 sessionID 有 tty → shell pane 带 tty；
        //     双无 → 裸 shell pane（此前只测过 localClaude 分支） ---
        let legacy = TerminalGridSnapshot(
            id: "legacy-shell", name: "legacy-shell", appBundleID: "com.apple.Terminal",
            displayID: 1, displayYabaiIndex: 1, rows: 1, cols: 2,
            cells: [
                TerminalGridCellSnapshot(index: 0, x: 0, y: 0, width: 100, height: 50,
                                         ttyPath: "/dev/ttys004", sessionID: nil, cwd: "/tmp", title: nil),
                TerminalGridCellSnapshot(index: 1, x: 100, y: 0, width: 100, height: 50,
                                         ttyPath: nil, sessionID: nil, cwd: "/var", title: nil),
            ],
            launchCommand: nil, capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let migrated = SessionSnapshotMigrator.migrateLegacy(legacy)
        check("modelCounts: 迁移 shell-with-tty 分支 tty/kind/cwd 保真",
              migrated.windows[0].panes[0].kind == .shell
              && migrated.windows[0].panes[0].tty == "/dev/ttys004"
              && migrated.windows[0].panes[0].cwd == "/tmp"
              && migrated.windows[0].panes[0].sessionID == nil)
        check("modelCounts: 迁移双无分支裸 shell pane",
              migrated.windows[1].panes[0].kind == .shell
              && migrated.windows[1].panes[0].tty == nil
              && migrated.windows[1].panes[0].cwd == "/var")
    }
}

// MARK: - B229：会话恢复域补口（脚本构造器/模型派生量/迁移 tty 分支/命令降级链/Store 落库）

extension RunnerHarness {
    func runSessionRestoreCoverageTopUps() {
        // A. PaneEnumeration 脚本构造器（纯字符串产物，此前 0 覆盖）
        let enumScript = PaneEnumeration.itermEnumerateSessions()
        check("paneScript: iTerm2 枚举面向 iterm2 + 三层循环 + tty/bounds/name 列",
              enumScript.contains("tell application id \"com.googlecode.iterm2\"")
              && enumScript.contains("repeat with w in windows")
              && enumScript.contains("repeat with t in tabs of w")
              && enumScript.contains("repeat with s in sessions of t")
              && enumScript.contains("tty of s")
              && enumScript.contains("linefeed"))
        let appendTab = PaneEnumeration.itermAppendTab(windowASID: "42", command: "say \"hi\"")
        check("paneScript: 追加 tab 指定 window id + create tab + 命令经 AppleScript 转义",
              appendTab.contains("tell window id 42")
              && appendTab.contains("create tab with default profile")
              && appendTab.contains(TerminalAutomationScript.appleScriptEscaped("say \"hi\"")))
        let writeSession = PaneEnumeration.itermWriteToSession(windowASID: "77", tabIndex: 2, sessionIndex: 3, command: "echo ok")
        check("paneScript: 定点 session 注入 tab/session 坐标正确",
              writeSession.contains("tell session 3 of tab 2 of window id 77")
              && writeSession.contains("write text"))
        check("paneScript: window 兜底委派 TerminalAutomationScript.itermInjectCommand",
              PaneEnumeration.itermWriteToWindow(windowASID: "9", command: "c1")
              == TerminalAutomationScript.itermInjectCommand(windowID: "9", command: "c1"))
        check("paneScript: Terminal 注入委派 TerminalAutomationScript.terminalInjectCommand",
              PaneEnumeration.terminalWriteToWindow(windowCGID: 88, command: "c2")
              == TerminalAutomationScript.terminalInjectCommand(windowID: 88, command: "c2"))

        // B. 模型派生量（frame setter / 三计数）
        var win = SessionWindowSnapshot(appBundleID: "t", frame: CGRect(x: 1, y: 2, width: 3, height: 4),
                                        displayID: 1, panes: [])
        win.frame = CGRect(x: 9, y: 8, width: 7, height: 6)
        check("model: frame setter 逐分量回写", win.x == 9 && win.y == 8 && win.width == 7 && win.height == 6)
        let snap = SessionRestoreSnapshot(name: "d", windows: [
            SessionWindowSnapshot(appBundleID: "t", frame: .zero, displayID: 1, yabaiSpace: 2, panes: [
                SessionPaneSnapshot(kind: .shell),
                SessionPaneSnapshot(kind: .localClaude, sessionID: "s1"),
            ]),
            SessionWindowSnapshot(appBundleID: "t", frame: .zero, displayID: 2, yabaiSpace: 3, panes: [
                SessionPaneSnapshot(kind: .localClaude, sessionID: "s2"),
                SessionPaneSnapshot(kind: .remoteSSH),
            ]),
            SessionWindowSnapshot(appBundleID: "t", frame: .zero, displayID: 2, yabaiSpace: nil, panes: []),
        ], launchCommand: nil)
        check("model: sessionPaneCount 只数有 sessionID 的 pane", snap.sessionPaneCount == 2)
        check("model: spaceCount 去重且 nil 不计", snap.spaceCount == 2)
        check("model: displayCount 去重", snap.displayCount == 2)

        // C. migrateLegacy tty-only 分支（此前 0 覆盖；sessionID 优先级不变量一并锁定）
        let legacy = TerminalGridSnapshot(name: "L", appBundleID: "com.apple.Terminal", displayID: 7,
                                          displayYabaiIndex: 1, rows: 1, cols: 3, cells: [
            TerminalGridCellSnapshot(index: 0, x: 0, y: 0, width: 10, height: 10, ttyPath: "/dev/ttys001", sessionID: "sid-1", cwd: "/a", title: "t1"),
            TerminalGridCellSnapshot(index: 1, x: 10, y: 0, width: 10, height: 10, ttyPath: "/dev/ttys002", sessionID: nil, cwd: "/b", title: "t2"),
            TerminalGridCellSnapshot(index: 2, x: 20, y: 0, width: 10, height: 10, ttyPath: nil, sessionID: nil, cwd: "/c", title: "t3"),
        ], launchCommand: "htop")
        let migrated = SessionSnapshotMigrator.migrateLegacy(legacy)
        check("migrate: 三 cell 升格三窗、kind 分流 localClaude/shell(tty)/shell(裸)",
              migrated.windows.count == 3
              && migrated.windows[0].panes[0].kind == .localClaude && migrated.windows[0].panes[0].sessionID == "sid-1"
              && migrated.windows[1].panes[0].kind == .shell && migrated.windows[1].panes[0].tty == "/dev/ttys002"
              && migrated.windows[2].panes[0].kind == .shell && migrated.windows[2].panes[0].tty == nil)
        check("migrate: id/launchCommand/yabai 平移无损",
              migrated.id == legacy.id && migrated.launchCommand == "htop"
              && migrated.windows.allSatisfy { $0.yabaiSpace == nil && $0.yabaiDisplay == 1 && $0.displayID == 7 })

        // D. SessionCommandBuilder 降级链补口（fallback / 远程四分支 / 端口提取）
        check("cmd: local 无 session 有 fallback → 启动命令",
              SessionCommandBuilder.localCommand(cwd: nil, sessionID: nil, fallback: "npm run dev") == "npm run dev")
        let remoteWithCwd = SessionPaneSnapshot(kind: .remoteSSH, cwd: "/remote", sshTarget: "u@h")
        check("cmd: 远程无会话有目录 → cd+启动命令（不猜 --resume）",
              SessionCommandBuilder.paneCommand(remoteWithCwd, launchCommand: "npm run dev")
              == "ssh -t u@h " + SessionCommandBuilder.shellQuoted("cd '/remote' && npm run dev"))
        let remoteNoTarget = SessionPaneSnapshot(kind: .remoteSSH, sessionID: "sid-9", cwd: "/r", sshCommand: "not-ssh")
        check("cmd: 有会话但 target 解析不出 → 原样回放 sshCommand",
              SessionCommandBuilder.paneCommand(remoteNoTarget, launchCommand: nil) == "not-ssh")
        let remoteFallbackTarget = SessionPaneSnapshot(kind: .remoteSSH, sessionID: "sid-9", sshCommand: "ssh u@h")
        check("cmd: target 从 sshCommand 兜底解析 → ssh -t 定点恢复",
              SessionCommandBuilder.paneCommand(remoteFallbackTarget, launchCommand: nil)
              == "ssh -t u@h " + SessionCommandBuilder.shellQuoted("claude --resume sid-9"))
        check("cmd: 远程全缺 → nil", SessionCommandBuilder.paneCommand(SessionPaneSnapshot(kind: .remoteSSH), launchCommand: nil) == nil)
        let remotePort = SessionPaneSnapshot(kind: .remoteSSH, sessionID: "sid-9", cwd: "/r", sshCommand: "ssh -p 2200 u@h")
        check("cmd: 显式端口从 sshCommand 提取 → -p 2200 前置",
              SessionCommandBuilder.paneCommand(remotePort, launchCommand: nil)
              == "ssh -p 2200 -t u@h " + SessionCommandBuilder.shellQuoted("cd '/r' && claude --resume sid-9"))
        check("port: sshCommand 缺 → nil", SessionPaneSnapshot(kind: .remoteSSH).sshTargetPort == nil)
        check("port: -p 显式端口解析", SessionPaneSnapshot(kind: .remoteSSH, sshCommand: "ssh -p 2200 u@h").sshTargetPort == "2200")

        // E. SessionRestoreStore 落库往返（临时 WindowStateStore 隔离，零触生产库）
        do {
            let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("vf-srstore-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let store = WindowStateStore(dbPath: dir + "/t.db")
            let sr = SessionRestoreStore(store: store)
            check("srStore: 空库快照为空 latest nil", sr.snapshots().isEmpty && sr.latest() == nil)

            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            let sA = SessionRestoreSnapshot(id: "a", name: "早", windows: [], launchCommand: nil, capturedAt: t0)
            let sB = SessionRestoreSnapshot(id: "b", name: "晚", windows: [], launchCommand: "htop",
                                            capturedAt: t0.addingTimeInterval(60))
            sr.upsert(sA)
            sr.upsert(sB)
            check("srStore: upsert 两条按 capturedAt 升序读回", sr.snapshots().map(\.id) == ["a", "b"])
            check("srStore: latest 取最新", sr.latest()?.id == "b")
            sr.upsert(SessionRestoreSnapshot(id: "a", name: "改名", windows: [], launchCommand: nil, capturedAt: t0))
            check("srStore: 同 id upsert 原位更新不追加",
                  sr.snapshots().count == 2 && sr.snapshots().first?.name == "改名")

            // merge 纯函数：同 id v2 优先、独有 legacy 尾随
            let dupLegacy = SessionRestoreSnapshot(id: "a", name: "legacy版", windows: [], launchCommand: nil, capturedAt: t0)
            let uniqLegacy = SessionRestoreSnapshot(id: "uniq", name: "独有", windows: [], launchCommand: nil, capturedAt: t0)
            let merged = SessionRestoreStore.merge(v2: [sA], legacyConverted: [dupLegacy, uniqLegacy])
            check("srStore: merge 同 id v2 优先、独有 legacy 尾随", merged.map(\.name) == ["早", "独有"])

            // 迁移视图：legacy JSON 并入（同 id v2 优先）
            let legacySnap = TerminalGridSnapshot(id: "legacy-1", name: "旧快照", appBundleID: "com.apple.Terminal",
                                                  displayID: 7, displayYabaiIndex: 1, rows: 1, cols: 1, cells: [
                TerminalGridCellSnapshot(index: 0, x: 0, y: 0, width: 10, height: 10, ttyPath: nil, sessionID: nil, cwd: nil, title: nil),
            ], launchCommand: nil, capturedAt: t0.addingTimeInterval(120))
            if let data = try? JSONEncoder().encode([legacySnap]),
               let json = String(data: data, encoding: .utf8) {
                store.savePreference(key: "terminalGridSnapshots", value: json)
                check("srStore: legacy 经迁移视图并入（capturedAt 排序尾随）",
                      sr.snapshots().map(\.id) == ["a", "b", "legacy-1"])
                // remove：v2+legacy 双库同清
                sr.remove(id: "legacy-1")
                check("srStore: remove 同步清 legacy 库（raw 过滤为空数组）",
                      store.loadPreference(key: "terminalGridSnapshots") == "[]"
                      && !sr.snapshots().contains { $0.id == "legacy-1" })
            }
            sr.remove(id: "b")
            check("srStore: remove v2 条目", sr.snapshots().map(\.id) == ["a"])

            // formatVersion 护栏：v1 存量直写 → 读视图过滤
            if let data = try? JSONEncoder().encode([sA]),
               let json = String(data: data, encoding: .utf8)?
                   .replacingOccurrences(of: "\"formatVersion\":2", with: "\"formatVersion\":1") {
                store.savePreference(key: "sessionRestoreSnapshotsV2", value: json)
                check("srStore: formatVersion≠2 存量被护栏过滤", sr.snapshots().isEmpty)
            }
        }

    }
}

// MARK: - B227：SessionRestoreSnapshot 派生量与 frame 存取（纯值模型）

extension RunnerHarness {
    func runSessionSnapshotDerivedTests() {
        print("\n=== SessionSnapshotDerived (B227) ===")

        // frame get/set 往返（Quartz 全局坐标，存散字段）
        var win = SessionWindowSnapshot(
            appBundleID: "com.apple.Terminal",
            frame: CGRect(x: 10, y: 20, width: 800, height: 500),
            displayID: 1,
            yabaiDisplay: 1,
            yabaiSpace: 3,
            panes: [SessionPaneSnapshot(kind: .shell, cwd: "/a")])
        win.frame = CGRect(x: -5, y: 600, width: 640, height: 400)
        check("derived: frame set 散字段同步",
              win.x == -5 && win.y == 600 && win.width == 640 && win.height == 400)
        check("derived: frame get 重组 CGRect",
              win.frame == CGRect(x: -5, y: 600, width: 640, height: 400))

        // 会话 pane 计数：仅 sessionID 非 nil 的 pane 计入
        let claudeWin = SessionWindowSnapshot(
            appBundleID: "com.googlecode.iterm2",
            frame: CGRect(x: 0, y: 0, width: 500, height: 300),
            displayID: 1,
            panes: [
                SessionPaneSnapshot(kind: .localClaude, sessionID: "s1", cwd: "/a"),
                SessionPaneSnapshot(kind: .shell, cwd: "/b"),
                SessionPaneSnapshot(kind: .remoteSSH, sessionID: "s2", sshTarget: "cc@host"),
            ])
        let snap = SessionRestoreSnapshot(
            id: "b227", name: "派生量", windows: [win, claudeWin],
            launchCommand: nil, capturedAt: Date())
        check("derived: sessionPaneCount 只数有会话 pane", snap.sessionPaneCount == 2)
        // space 去重（nil 不计）：win space 3、claudeWin space nil
        check("derived: spaceCount nil 不计", snap.spaceCount == 1)
        check("derived: displayCount 去重", snap.displayCount == 1)
    }
}

// MARK: - B234：SessionRestoreExecutor 分组提纯（组序 = 快照阅读序的契约锁）

extension RunnerHarness {
    func runSessionRestoreExecutorTests() {
        func item(_ display: Int?, _ space: Int?, index: Int) -> SessionRestorePlanner.Item {
            SessionRestorePlanner.Item(
                windowIndex: index,
                action: .create(commands: [nil]),
                targetYabaiDisplay: display,
                targetYabaiSpace: space,
                targetFrame: CGRect(x: 0, y: 0, width: 10, height: 10),
                notes: [])
        }
        // 组序 = 首次出现序（快照阅读序），同组多窗聚合
        let (order, groups) = SessionRestoreExecutor.groupByTargetSpace([
            item(1, 2, index: 0), item(2, 3, index: 1), item(1, 2, index: 2), item(1, 5, index: 3),
        ])
        check("srExec: 组序 = 首次出现序（阅读序不乱）", order == ["1:2", "2:3", "1:5"])
        check("srExec: 同组多窗聚合且组内有序",
              groups["1:2"]?.map(\.windowIndex) == [0, 2] && groups["2:3"]?.map(\.windowIndex) == [1]
              && groups["1:5"]?.map(\.windowIndex) == [3])
        // nil display/space → "-1:-1" 兜底组
        let (order2, groups2) = SessionRestoreExecutor.groupByTargetSpace([
            item(nil, nil, index: 7), item(1, nil, index: 8),
        ])
        check("srExec: nil 落 -1 兜底键", order2 == ["-1:-1", "1:-1"]
              && groups2["-1:-1"]?.map(\.windowIndex) == [7] && groups2["1:-1"]?.map(\.windowIndex) == [8])
        // 空输入 → 空组
        check("srExec: 空输入 → 空组序", SessionRestoreExecutor.groupByTargetSpace([]).groupOrder.isEmpty)
        // 非 create 动作由调用方先过滤（本函数契约：只收 create 项）——nil 值项同样按目标键分组
        check("srExec: notes 为空数组不变", SessionRestoreExecutor.groupByTargetSpace([item(3, 4, index: 9)]).groups["3:4"]?.first?.notes.isEmpty == true)
    }
}
