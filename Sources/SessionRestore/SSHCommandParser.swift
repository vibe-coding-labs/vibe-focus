import Foundation

// MARK: - SSH 命令行解析（纯函数）
/// 从 tty 的 ps 输出里认出 ssh 进程并拆出目的地。真机实锚（2026-09-13 用户 pane）：
/// `ssh -o StrictHostKeyChecking=no cc11001100@192.168.1.83`（wrapper 脚本
/// ~/bin/login-local-server-001 的子进程）。
/// 设计边界：只解析 OpenSSH 常用形态（-p/-l/-i/-F/-o 及其粘写、--、ssh:// URL）；
/// 解析不出目的地就如实返回 nil（调用方退化为原样回放整条命令行）。
enum SSHCommandParser {

    struct ParsedTarget: Equatable {
        /// `user@host:port` / `user@host` / `host`（已剥 ssh:// 前缀与端口段）
        var destination: String
        var user: String?
        var host: String
        var port: String?

        /// 组合命令用的目的地参数：`user@host` 形态（OpenSSH 的 ssh 不接受
        /// user@host:port——那是 scp 语法；显式端口由调用方单独拼 `-p <port>`）
        var destinationArg: String {
            user.map { "\($0)@\(host)" } ?? host
        }
    }

    /// ps 一行命令行是否为 ssh 客户端进程（basename 精确 "ssh"）。排除 sshd /
    /// sshfs / gnome-ssh-agent 等同前缀进程；argv[0] 带路径时取末段比较。
    static func isSSHProcess(commandLine: String) -> Bool {
        guard let first = commandLine.split(separator: " ").first else { return false }
        let basename = String(first).split(separator: "/").last.map(String.init) ?? String(first)
        return basename == "ssh"
    }

    /// 命令行 → 目的地。argv[0] 之后按 OpenSSH 语义逐 token 消化：
    /// - 带值短选项集合：p l i m S c F D E J L O R V w b e
    ///   （审计批 2026-09-26 补 -m MACs规格 / -S ctl：此前漏项会把 `ssh -m mymacs
    ///   host` 的 mymacs 误认成目的地=错连风险，而非诚实降级）
    /// - 无值短选项集合：其余单字母（-t -T -A -C -f -g -G -K -k -M -N -n -q -s -S -v -W -x -X -Y -4 -6 ...）
    ///   （多字母如 -46 按「整段无值」处理）
    /// - `-o`/`-oVALUE`、`--` 终结选项
    /// - 第一个非选项 token = destination，其后是远端命令（有远端命令说明不是
    ///   交互登录 pane，仍照常解析 destination，由调用方决定用途）
    static func parseDestination(commandLine: String) -> ParsedTarget? {
        var tokens = Array(commandLine.split(separator: " ").dropFirst()).map(String.init)
        var user: String?
        var port: String?
        let optionsWithValue = Set("plicmoSFcDEJLORVwbe".map { String($0) })

        while !tokens.isEmpty {
            let token = tokens.removeFirst()
            if token == "--" { break }
            if token.hasPrefix("--") { continue }
            guard token.hasPrefix("-"), token.count >= 2 else {
                // 第一个非选项 token 即 destination
                return finalize(token, user: user, port: port)
            }
            let flag = String(token.dropFirst().prefix(1))
            // 粘写带值（-p2222 / -oStrictHostKeyChecking=no）：值就在同 token 里
            if token.count > 2, optionsWithValue.contains(flag) {
                let inline = String(token.dropFirst(2))
                if flag == "p" { port = inline }
                if flag == "l" { user = inline }
                continue
            }
            if optionsWithValue.contains(flag) {
                if flag == "p" { port = tokens.isEmpty ? nil : tokens.removeFirst() }
                else if flag == "l" { user = tokens.isEmpty ? nil : tokens.removeFirst() }
                else if !tokens.isEmpty { tokens.removeFirst() }   // 其它带值选项吞掉值
                continue
            }
            // 无值选项（-t/-4/-vvv ...）继续
        }
        // 全是选项没有 destination（理论上 ssh 必有，防御）
        return tokens.isEmpty ? nil : finalize(tokens[0], user: user, port: port)
    }

    private static func finalize(_ raw: String, user: String?, port: String?) -> ParsedTarget? {
        var target = raw
        if target.hasPrefix("ssh://") { target = String(target.dropFirst("ssh://".count)) }
        // URL 形态的端口段 user@host:port —— 冒号后为纯数字才认作端口
        // （IPv6 裸地址不含冒号写法不在此解析范围，如实交给回放降级）
        var explicitPort = port
        if let colon = target.lastIndex(of: ":") {
            let suffix = target[target.index(after: colon)...]
            let hostPart = target[target.startIndex..<colon]
            if !suffix.isEmpty, suffix.allSatisfy(\.isNumber), !hostPart.contains(":") {
                explicitPort = explicitPort ?? String(suffix)
                target = String(hostPart)
            }
        }
        guard !target.isEmpty else { return nil }
        var parsedUser = user
        var host = target
        if let at = target.firstIndex(of: "@") {
            parsedUser = String(target[target.startIndex..<at])
            host = String(target[target.index(after: at)...])
        }
        guard !host.isEmpty else { return nil }
        return ParsedTarget(destination: raw, user: parsedUser, host: host, port: explicitPort)
    }
}
