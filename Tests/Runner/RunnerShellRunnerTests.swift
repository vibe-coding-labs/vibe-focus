import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerShellRunnerTests.swift — B128：ShellRunner 全分支直测。
// ShellRunner 是全库 shell 执行唯一原语（yabai/ps/lsof/osascript 底座），
// 此前 0 直测（37% 覆盖全靠别的测试路过）。用真实短进程穷尽：成功/非零退出/
// stderr 捕获/可执行文件不存在/超时 terminate/stdin 三态/trim 便捷入口。

extension RunnerHarness {
    func runShellRunnerTests() {
        // 1. 成功路径：stdout/stderr/exitCode 三元组
        do {
            let r = ShellRunner.run(executable: "/bin/echo", arguments: ["hello-shell"])
            check("shellRunner: echo 成功 exitCode=0 stdout 捕获",
                  r != nil && r!.exitCode == 0 && r!.stdout == "hello-shell\n")
            let r2 = ShellRunner.run(executable: "/bin/sh", arguments: ["-c", "echo out; echo err >&2"])
            check("shellRunner: stdout/stderr 分别捕获",
                  r2?.stdout == "out\n" && r2?.stderr == "err\n" && r2?.exitCode == 0)
        }

        // 2. 非零退出：exitCode 如实透传（不吞不翻）
        check("shellRunner: 非零退出如实透传",
              ShellRunner.run(executable: "/usr/bin/false", arguments: [])?.exitCode == 1)

        // 3. 可执行文件不存在 → run 抛错 → nil（调用方走 fallback 的依据）
        check("shellRunner: 可执行文件不存在 → nil",
              ShellRunner.run(executable: "/nonexistent/vf-no-such-bin", arguments: []) == nil)

        // 4. 超时：sleep 超过 timeout → terminate + nil（不再阻塞调用方）
        do {
            let t0 = Date()
            let r = ShellRunner.run(executable: "/bin/sleep", arguments: ["5"], timeout: 0.3)
            let wall = Date().timeIntervalSince(t0)
            check("shellRunner: 超时 terminate → nil 且按时返回",
                  r == nil && wall < 2.0 && wall >= 0.25)
        }

        // 5. stdin 变体：载荷到达子进程 stdin
        check("shellRunner(stdin): cat 回显载荷",
              ShellRunner.run(executable: "/bin/cat", arguments: [], stdin: "vf-载荷-🚀")?
                  .stdout == "vf-载荷-🚀")
        check("shellRunner(stdin): 空字符串载荷照常写 stdin",
              ShellRunner.run(executable: "/bin/cat", arguments: [], stdin: "")?.stdout == "")

        // 6. runShell 便捷入口：成功 trim、失败 nil
        check("shellRunner: runShell 成功且 trim 首尾空白",
              ShellRunner.runShell("echo '  vf-trim  '") == "vf-trim")
        check("shellRunner: runShell 非零退出 → nil",
              ShellRunner.runShell("exit 3") == nil)
        check("shellRunner: runShell 语法错误 → nil",
              ShellRunner.runShell(" vf-双引号\"断裂") == nil)
    }
}

// MARK: - B134：ExitJournal 信号行编码 + ClaudeSessionLocator 组合链（home 注入）

extension RunnerHarness {
    func runB134SmallTopUps() {
        // ExitJournal.cCharLineForSignal：CChar 数组可无损还原为 exitLine + 换行、无 NUL 尾巴
        let chars = ExitJournal.cCharLineForSignal(pid: 4242, signal: 11, name: "SIGSEGV")
        let restored = String(cString: chars + [0])
        check("exitJournal: 信号行编码含 pid/signal/name 且无 NUL 尾巴",
              restored.contains("4242") && restored.contains("11") && restored.contains("SIGSEGV")
              && restored.hasSuffix("\n"))
        check("exitJournal: 编码长度 = 行内容 utf8 精确长度（utf8CString 去尾 NUL）",
              chars.count == restored.utf8.count)

        // ClaudeSessionLocator.locateSessionID 组合链（runner/home 双注入）
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "vf-b134-loc-\(UUID().uuidString)"
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let proj = home + "/.claude/projects/-tmp-vf-b134"
        try? fm.createDirectory(atPath: proj, withIntermediateDirectories: true)
        fm.createFile(atPath: proj + "/sid-b134.jsonl", contents: Data("{}".utf8))
        try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-30)], ofItemAtPath: proj + "/sid-b134.jsonl")

        func makeRunner(psOut: String?, lsofCWD: String?) -> (String, [String]) -> YabaiClient.YabaiResult? {
            { exec, _ in
                if exec == "/bin/ps", let psOut {
                    return YabaiClient.YabaiResult(exitCode: 0, stdout: psOut, stderr: "")
                }
                if exec == "/usr/sbin/lsof", let lsofCWD {
                    return YabaiClient.YabaiResult(exitCode: 0, stdout: "p7777\nn\(lsofCWD)", stderr: "")
                }
                return YabaiClient.YabaiResult(exitCode: 1, stdout: "", stderr: "")
            }
        }

        let hit = ClaudeSessionLocator.locateSessionID(
            ttyPath: "/dev/ttys099",
            runner: makeRunner(psOut: "  7777 claude --resume sid-b134\n  7800 -zsh", lsofCWD: "/tmp/vf-b134"),
            fileManager: fm, now: now, home: home)
        check("locator: tty→claude 进程→lsof cwd→最新会话 jsonl 三段全通",
              hit != nil && hit!.sessionID == "sid-b134" && hit!.cwd == "/tmp/vf-b134")

        let miss = ClaudeSessionLocator.locateSessionID(
            ttyPath: "/dev/ttys099",
            runner: makeRunner(psOut: "  7800 -zsh", lsofCWD: nil),
            fileManager: fm, now: now, home: home)
        check("locator: tty 上无 claude 进程 → nil",
              miss == nil)

        // B136：claude 进程在但 lsof cwd 失败 → projectDir 空 → nil
        let noCwd = ClaudeSessionLocator.locateSessionID(
            ttyPath: "/dev/ttys099",
            runner: makeRunner(psOut: "  7777 claude", lsofCWD: nil),
            fileManager: fm, now: now, home: home)
        check("locator: claude 在但 lsof 失败 → nil", noCwd == nil)

        // B136：claude+cwd 在但 projects 目录无会话 → nil
        let noSession = ClaudeSessionLocator.locateSessionID(
            ttyPath: "/dev/ttys099",
            runner: makeRunner(psOut: "  7777 claude", lsofCWD: "/tmp/vf-never"),
            fileManager: fm, now: now, home: home)
        check("locator: claude+cwd 在但无会话目录 → nil", noSession == nil)
        try? fm.removeItem(atPath: home)
    }
}
