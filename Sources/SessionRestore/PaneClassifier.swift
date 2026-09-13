import Foundation

// MARK: - pane 进程分类（纯函数）
/// tty 的 `ps -t <tty> -o pid=,command=` 输出 → pane 形态判定。每个 tty 只 fork
/// 一次 ps，三种形态（本机 claude / ssh / 纯 shell）在同一次输出上判完。
enum PaneClassifier {

    struct Classification: Equatable {
        var kind: SessionPaneSnapshot.Kind
        /// 命中的进程 pid（claude / ssh / 登录 shell）
        var pid: Int32?
        /// ssh 进程完整命令行（remoteSSH 形态；原样回放降级用）
        var sshCommand: String?
        /// 解析出的 ssh 目的地
        var sshTarget: String?
    }

    /// ps 输出行流 → 分类。判定顺序：claude 优先（ssh 隧道里再套 claude 的
    /// 本地侧不会出现，但 ps 全量列出时同 tty 可能同时有 ssh 与本地 claude——
    /// 本机 claude 直接持有 tty 会话优先级更高）；其次 ssh；否则登录 shell。
    static func classify(processLines: [String]) -> Classification {
        var claudePID: Int32?
        var shellPID: Int32?
        var sshLine: String?
        var sshPID: Int32?
        for rawLine in processLines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let spaceIndex = line.firstIndex(of: " ") else { continue }
            guard let pid = Int32(line[line.startIndex..<spaceIndex]) else { continue }
            let commandLine = String(line[line.index(after: spaceIndex)...])
            if claudePID == nil, ClaudeSessionLocator.isClaudeProcess(commandLine: commandLine) {
                claudePID = pid
                continue
            }
            if sshLine == nil, SSHCommandParser.isSSHProcess(commandLine: commandLine) {
                sshPID = pid
                sshLine = commandLine
                continue
            }
            if shellPID == nil, isLoginShell(commandLine: commandLine) {
                shellPID = pid
            }
        }
        if let claudePID {
            return Classification(kind: .localClaude, pid: claudePID, sshCommand: nil, sshTarget: nil)
        }
        if let sshLine {
            let target = SSHCommandParser.parseDestination(commandLine: sshLine)
            return Classification(
                kind: .remoteSSH,
                pid: sshPID,
                sshCommand: sshLine,
                sshTarget: target.map { "\($0.destinationArg)" }
            )
        }
        return Classification(kind: .shell, pid: shellPID, sshCommand: nil, sshTarget: nil)
    }

    /// 登录 shell 判定（与 ClaudeSessionLocator.shellPID 同一集合语义：argv[0]
    /// basename ∈ 常见 shell 集合，剥前导 '-'）
    static func isLoginShell(commandLine: String) -> Bool {
        let shellNames: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "pwsh"]
        guard let first = commandLine.split(separator: " ").first else { return false }
        let basename = String(first).split(separator: "/").last.map(String.init) ?? String(first)
        let stripped = basename.hasPrefix("-") ? String(basename.dropFirst()) : basename
        return shellNames.contains(stripped)
    }
}
