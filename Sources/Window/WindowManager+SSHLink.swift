import Foundation

// WindowManager+SSHLink.swift
// B125：SSH 连接指纹 → 本机终端窗口（远程会话动态绑定通道）。
// 静态 label→窗 映射在「一台服务器多开 ssh 窗 + 多并发 claude 会话」时必然
// 张冠李戴（2026-09-11 真机实锤：8 个项目会话全部解析到同一个 chat-show 窗，
// Stop/UPS 把它来回搬）。动态通道：远程 hook 的 terminal_ctx 带 SSH_CLIENT
// （客户端 ip:port = Mac 侧 ssh 进程的本地 TCP 端口）→ lsof 反查 established
// 连接里本地端口吻合的 ssh 进程 → 进程 tty → 终端 app 的 tty→窗口映射。
// 每条远程会话精确落在它真正所在的窗，静态映射降级为 tmux 等场景的兜底。

@MainActor
extension WindowManager {

    struct SSHLinkParse {
        /// lsof -nP -iTCP:<port> -sTCP:ESTABLISHED 输出 → 本地端口吻合的 ssh 进程 pid。
        /// 行形如：`ssh 9101 user 7u IPv4 ... TCP 192.168.1.12:54321->192.168.1.83:22 (ESTABLISHED)`
        static func parseEstablishedSSHPid(_ output: String, serverIP: String, clientPort: String) -> pid_t? {
            guard !clientPort.isEmpty, !serverIP.isEmpty else { return nil }
            for line in output.split(whereSeparator: \.isNewline) {
                guard let tcp = line.range(of: " TCP ") else { continue }
                let namePart = line[tcp.upperBound...]
                guard let arrow = namePart.range(of: "->") else { continue }
                let local = namePart[..<arrow.lowerBound]
                let remote = namePart[arrow.upperBound...]
                guard remote.hasPrefix("\(serverIP):") else { continue }
                let localPort = local.split(separator: ":").last.map(String.init) ?? ""
                guard localPort == clientPort else { continue }
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2, let pid = pid_t(parts[1]) else { continue }
                return pid
            }
            return nil
        }

        /// `ps -o tty=` 输出 → 规整 tty 设备路径（"ttys001" → "/dev/ttys001"；"??" 无 tty）。
        static func parseTTYOfPid(_ psOutput: String) -> String? {
            let t = psOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.hasPrefix("ttys") || t.hasPrefix("/dev/ttys") else { return nil }
            return t.hasPrefix("/dev/") ? t : "/dev/" + t
        }

        /// iTerm2 枚举输出（每行 `窗口ID|tty|会话名`）→ tty 对应的窗口 ID。
        static func parseTTYWindowMap(_ output: String, tty: String) -> UInt32? {
            for line in output.split(whereSeparator: \.isNewline) {
                let parts = line.components(separatedBy: "|")
                guard parts.count >= 2 else { continue }
                let lineTTY = parts[1].trimmingCharacters(in: .whitespaces)
                guard lineTTY == tty,
                      let id = UInt32(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
                return id
            }
            return nil
        }
    }

    /// 按 SSH 连接指纹解析远程会话所在的本地终端窗口。任一环缺失/不吻合返回 nil
    ///（调用方降级静态映射），绝不猜测窗口。
    func resolveWindowBySSHLink(clientIP: String, clientPort: String, serverIP: String) -> WindowIdentity? {
        let rStart = Date()
        defer {
            log("[WindowManager] resolveWindowBySSHLink finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: rStart)),
                "clientIP": clientIP, "clientPort": clientPort, "serverIP": serverIP
            ])
        }
        guard !clientPort.isEmpty, !serverIP.isEmpty else { return nil }

        // 1) established 连接反查 ssh 进程 pid（本地端口 == 远程 SSH_CLIENT 的 client_port）
        guard let lsofOut = runShellCommand("/usr/sbin/lsof", args: [
            "-nP", "-iTCP:22", "-sTCP:ESTABLISHED"
        ]) else { return nil }
        guard let sshPid = SSHLinkParse.parseEstablishedSSHPid(lsofOut, serverIP: serverIP, clientPort: clientPort) else {
            log("[WindowManager] resolveWindowBySSHLink: no established ssh match", level: .debug, fields: [
                "clientPort": clientPort, "serverIP": serverIP
            ])
            return nil
        }

        // 2) 进程 tty
        guard let psOut = runShellCommand("/bin/ps", args: ["-o", "tty=", "-p", String(sshPid)]),
              let tty = SSHLinkParse.parseTTYOfPid(psOut) else { return nil }

        // 3) iTerm2 tty→窗口映射（AppleScript 窗口 id == CGWindowID，真机互查实证）
        let script = """
        osascript -e 'tell application "iTerm2"
        set out to ""
        repeat with w in windows
        repeat with t in tabs of w
        repeat with s in sessions of t
        try
        set out to out & (id of w) & "|" & (tty of s) & "|" & (name of s) & linefeed
        end try
        end repeat
        end repeat
        end repeat
        return out
        end tell'
        """
        guard let mapOut = runShellCommand("/bin/bash", args: ["-c", script]),
              let windowID = SSHLinkParse.parseTTYWindowMap(mapOut, tty: tty),
              let identity = findWindowByCGWindowID(windowID) else {
            log("[WindowManager] resolveWindowBySSHLink: tty not in iTerm2 map", level: .debug, fields: [
                "tty": tty, "sshPid": String(sshPid)
            ])
            return nil
        }
        log("[WindowManager] resolveWindowBySSHLink resolved", fields: [
            "tty": tty, "windowID": String(identity.windowID),
            "title": identity.title ?? "nil", "sshPid": String(sshPid)
        ])
        return identity
    }
}
