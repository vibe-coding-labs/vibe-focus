import Foundation

// MARK: - 恢复命令构建器（纯函数）
/// pane 形态 → 写进终端的 shell 命令行。转义三层各管各的，互不冲突：
/// 1. 本层产出「终端里要执行的原生 shell 串」（远程 pane 产出 ssh 完整命令行，
///    远端命令段用 shellQuoted 单引号包裹后交给本地 shell，`$`/空格/引号全保真）；
/// 2. AppleScript 层逃逸由建窗/写文本处统一做（appleScriptEscaped 只动反斜杠与
///    双引号）；
/// 3. 会话段 `claude --resume <id>`：sessionID 是 UUID，无需转义，但防御性拒绝
///    含空白/分号的值（快照文件被手改时的注入护栏）。
enum SessionCommandBuilder {

    /// POSIX 单引号包裹（与 TerminalAutomationScript.shellQuoted 同义；此处独立
    /// 存在是因为本模块纯函数层无 MainActor 隔离，不能调用 @MainActor 静态）
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// sessionID 的安全形态（UUID/字母数字-，拒绝空白与 shell 元字符）
    static func isSafeSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// 单 pane 的恢复命令。nil = 无可执行内容（纯 shell 又无目录/启动命令）。
    /// - Parameters:
    ///   - launchCommand: 快照级默认启动命令（shell pane 用）
    static func paneCommand(_ pane: SessionPaneSnapshot, launchCommand: String?) -> String? {
        switch pane.kind {
        case .localClaude:
            return localCommand(cwd: pane.cwd, sessionID: pane.sessionID, fallback: launchCommand)
        case .shell:
            return shellCommand(cwd: pane.cwd, launchCommand: launchCommand)
        case .remoteSSH:
            return remoteCommand(pane: pane, launchCommand: launchCommand)
        }
    }

    /// 窗口首 pane 命令（建窗脚本的 command 参数）
    static func windowCommand(_ window: SessionWindowSnapshot, launchCommand: String?) -> String? {
        guard let pane = window.panes.first else { return nil }
        return paneCommand(pane, launchCommand: launchCommand)
    }

    /// 附加 pane（tab）命令列表（第 2..N pane）
    static func additionalPaneCommands(_ window: SessionWindowSnapshot, launchCommand: String?) -> [String?] {
        guard window.panes.count > 1 else { return [] }
        return window.panes.dropFirst().map { paneCommand($0, launchCommand: launchCommand) }
    }

    // MARK: 形态组合

    /// 本地：cd [+ --resume | 启动命令]
    static func localCommand(cwd: String?, sessionID: String?, fallback: String?) -> String? {
        var parts: [String] = []
        if let cwd, !cwd.isEmpty { parts.append("cd \(Self.shellQuoted(cwd))") }
        if let sessionID, !sessionID.isEmpty {
            guard isSafeSessionID(sessionID) else { return parts.isEmpty ? nil : parts.joined(separator: " && ") }
            parts.append("claude --resume \(sessionID)")
        } else if let fallback, !fallback.isEmpty {
            parts.append(fallback)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " && ")
    }

    /// 纯 shell：cd [+ 启动命令]
    static func shellCommand(cwd: String?, launchCommand: String?) -> String? {
        var parts: [String] = []
        if let cwd, !cwd.isEmpty { parts.append("cd \(Self.shellQuoted(cwd))") }
        if let launchCommand, !launchCommand.isEmpty { parts.append(launchCommand) }
        return parts.isEmpty ? nil : parts.joined(separator: " && ")
    }

    /// 远程：定位到会话 → `ssh [-p port] -t <user@host> '<远端命令>'`（-t 保证
    /// 分配交互 tty，claude 需要远端 TTY）；未定位到 → 原样回放捕获到的 ssh 命令行
    /// （保真降级：回 wrapper 里的完整选项）；连原命令行都没有 → 裸 `ssh -t target`。
    static func remoteCommand(pane: SessionPaneSnapshot, launchCommand: String?) -> String? {
        let remoteSegment: String?
        if let sessionID = pane.sessionID, !sessionID.isEmpty, isSafeSessionID(sessionID) {
            var parts: [String] = []
            if let cwd = pane.cwd, !cwd.isEmpty { parts.append("cd \(Self.shellQuoted(cwd))") }
            parts.append("claude --resume \(sessionID)")
            remoteSegment = parts.joined(separator: " && ")
        } else if let cwd = pane.cwd, !cwd.isEmpty {
            // 无会话但有远程目录：cd 过去（有启动命令带上），不猜 --resume
            remoteSegment = shellCommand(cwd: cwd, launchCommand: launchCommand)
        } else {
            remoteSegment = nil
        }

        if let remoteSegment {
            guard let target = pane.sshTarget ?? fallbackTarget(from: pane.sshCommand), !target.isEmpty else {
                return pane.sshCommand
            }
            var argv = ["ssh"]
            if let port = pane.sshTargetPort, !port.isEmpty { argv += ["-p", port] }
            argv += ["-t", target, Self.shellQuoted(remoteSegment)]
            return argv.joined(separator: " ")
        }
        // 降级链：原样回放 > 裸 ssh
        if let raw = pane.sshCommand, !raw.isEmpty { return raw }
        if let target = pane.sshTarget ?? fallbackTarget(from: pane.sshCommand), !target.isEmpty {
            return "ssh -t \(target)"
        }
        return nil
    }

    /// sshTarget 缺席时从原始命令行兜底解析（快照由旧版本/迁移路径产出时）
    private static func fallbackTarget(from sshCommand: String?) -> String? {
        guard let sshCommand else { return nil }
        return parseTarget(from: sshCommand)?.destinationArg
    }

    /// 解析目标（暴露给捕获编排复用）
    static func parseTarget(from sshCommand: String) -> SSHCommandParser.ParsedTarget? {
        guard SSHCommandParser.isSSHProcess(commandLine: sshCommand) else { return nil }
        return SSHCommandParser.parseDestination(commandLine: sshCommand)
    }
}

extension SessionPaneSnapshot {
    /// 从 sshCommand 提取的显式端口（组合命令拼 -p 用；sshTarget 本身存 user@host）
    var sshTargetPort: String? {
        guard let sshCommand,
              let parsed = SessionCommandBuilder.parseTarget(from: sshCommand) else { return nil }
        return parsed.port
    }
}
