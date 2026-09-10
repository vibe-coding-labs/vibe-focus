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
