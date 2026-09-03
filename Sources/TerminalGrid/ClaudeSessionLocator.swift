import Foundation

// MARK: - Claude Code session 定位器
/// TTY → 该终端里运行的 claude 进程 → cwd → `~/.claude/projects/<escaped>/` 最新
/// `<sessionID>.jsonl`（本机实证：文件名即 sessionID；目录名映射规则为
/// 非 [A-Za-z0-9_-] 一律替换为 '-'，如 /Users/x/.local/bin → -Users-x--local-bin）。
/// 主路径是 Hook 链路（windows 表已有 session_id），本定位器是"没装 Hook"的兜底。
enum ClaudeSessionLocator {

    /// cwd → projects 目录名。实证规则：字母/数字/'-'/'_' 保留，其余（含 '/'、'.'、空格）替换为 '-'。
    static func escapedProjectDir(forCWD cwd: String) -> String {
        String(cwd.map { character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "-"
        })
    }

    /// session jsonl 文件名 → sessionID（文件名即 sessionID，见实证）。
    static func sessionID(fromSessionFileName fileName: String) -> String? {
        guard fileName.hasSuffix(".jsonl") else { return nil }
        let stem = String(fileName.dropLast(".jsonl".count))
        return stem.isEmpty ? nil : stem
    }

    /// 判断 ps 输出的一行是否为 claude CLI 进程（basename == "claude" 或以 /claude 结尾
    /// 的路径组件），避免误吞命令行里含 "claude" 字样的其它进程。
    static func isClaudeProcess(commandLine: String) -> Bool {
        let tokens = commandLine.split(separator: " ")
        return tokens.contains { token in
            let t = String(token)
            return t == "claude" || t.hasSuffix("/claude")
        }
    }

    /// 在指定 TTY 上找 claude 进程 PID（ps -t ttysNNN）。找不到返回 nil。
    static func claudePID(
        onTTY ttyPath: String,
        runner: (String, [String]) -> YabaiClient.YabaiResult? = { ShellRunner.run(executable: $0, arguments: $1) }
    ) -> Int32? {
        let shortTTY = ttyPath.hasPrefix("/dev/") ? String(ttyPath.dropFirst("/dev/".count)) : ttyPath
        guard let result = runner("/bin/ps", ["-t", shortTTY, "-o", "pid=,command="]), result.exitCode == 0 else {
            return nil
        }
        for line in result.stdout.split(separator: "\n") {
            let trimmed = line.drop(while: { $0 == " " })
            guard let spaceIndex = trimmed.firstIndex(of: " ") else { continue }
            guard let pid = Int32(trimmed[trimmed.startIndex..<spaceIndex]) else { continue }
            let commandLine = String(trimmed[trimmed.index(after: spaceIndex)...])
            if isClaudeProcess(commandLine: commandLine) {
                return pid
            }
        }
        return nil
    }

    /// 进程 cwd（lsof -Fn）。失败返回 nil。
    static func workingDirectory(
        ofPID pid: Int32,
        runner: (String, [String]) -> YabaiClient.YabaiResult? = { ShellRunner.run(executable: $0, arguments: $1) }
    ) -> String? {
        guard let result = runner("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]),
              result.exitCode == 0 else {
            return nil
        }
        // 输出行形如 "p123" / "n/Users/xxx"（n 前缀行携带路径）
        for line in result.stdout.split(separator: "\n") {
            let line = String(line)
            if line.hasPrefix("n"), line.count > 1 {
                return String(line.dropFirst())
            }
        }
        return nil
    }

    /// projects 目录下最新（30 天内）session jsonl 的 sessionID。
    static func latestSessionID(
        inProjectDir projectDir: String,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> String? {
        let dirURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects/\(projectDir)")
        guard let items = try? fileManager.contentsOfDirectory(atPath: dirURL.path) else {
            return nil
        }
        let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
        let candidates: [(name: String, modified: Date)] = items.compactMap { item in
            guard sessionID(fromSessionFileName: item) != nil else { return nil }
            let itemURL = dirURL.appendingPathComponent(item)
            guard let attributes = try? fileManager.attributesOfItem(atPath: itemURL.path),
                  let modified = attributes[.modificationDate] as? Date,
                  modified >= cutoff else {
                return nil
            }
            return (item, modified)
        }
        return candidates
            .max { $0.modified < $1.modified }
            .flatMap { sessionID(fromSessionFileName: $0.name) }
    }

    /// tty 上的登录 shell PID（basename ∈ 常见 shell 集合的最小 pid；login 包装进程
    /// 会被排除——Terminal 的 tty 上进程链是 login → zsh → claude）。
    static func shellPID(
        onTTY ttyPath: String,
        runner: (String, [String]) -> YabaiClient.YabaiResult? = { ShellRunner.run(executable: $0, arguments: $1) }
    ) -> Int32? {
        let shortTTY = ttyPath.hasPrefix("/dev/") ? String(ttyPath.dropFirst("/dev/".count)) : ttyPath
        guard let result = runner("/bin/ps", ["-t", shortTTY, "-o", "pid=,command="]), result.exitCode == 0 else {
            return nil
        }
        let shellNames: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "pwsh"]
        var best: (pid: Int32, name: String)?
        for line in result.stdout.split(separator: "\n") {
            let trimmed = line.drop(while: { $0 == " " })
            guard let spaceIndex = trimmed.firstIndex(of: " ") else { continue }
            guard let pid = Int32(trimmed[trimmed.startIndex..<spaceIndex]) else { continue }
            let commandLine = String(trimmed[trimmed.index(after: spaceIndex)...])
            // login shell 的 argv[0] 带前导 '-'（如 "-zsh"），必须剥掉再匹配
            let basename = commandLine.split(separator: " ").first.map { String($0) }.map { path in
                path.split(separator: "/").last.map { String($0) } ?? path
            }.map { name in
                name.hasPrefix("-") ? String(name.dropFirst()) : name
            } ?? commandLine
            guard shellNames.contains(basename) else { continue }
            if best == nil || pid < best!.pid {
                best = (pid, basename)
            }
        }
        return best?.pid
    }

    /// tty 上登录 shell 的 cwd——纯 shell 格子没有 session 也要记住目录。
    static func shellWorkingDirectory(
        onTTY ttyPath: String,
        runner: (String, [String]) -> YabaiClient.YabaiResult? = { ShellRunner.run(executable: $0, arguments: $1) },
        fileManager: FileManager = .default
    ) -> String? {
        guard let pid = shellPID(onTTY: ttyPath, runner: runner) else { return nil }
        return workingDirectory(ofPID: pid, runner: runner)
    }

    /// 组合入口：tty → sessionID（任一环节失败即 nil，调用方降级为"无会话"格子）。
    static func locateSessionID(
        ttyPath: String,
        runner: (String, [String]) -> YabaiClient.YabaiResult? = { ShellRunner.run(executable: $0, arguments: $1) },
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> (sessionID: String, cwd: String?)? {
        guard let pid = claudePID(onTTY: ttyPath, runner: runner) else { return nil }
        let cwd = workingDirectory(ofPID: pid, runner: runner)
        let projectDir = cwd.map { escapedProjectDir(forCWD: $0) } ?? ""
        let sessionID: String?
        if !projectDir.isEmpty {
            sessionID = latestSessionID(inProjectDir: projectDir, now: now, fileManager: fileManager)
        } else {
            sessionID = nil
        }
        guard let sessionID else { return nil }
        return (sessionID, cwd)
    }
}
