// WindowManager+TerminalContext+iTerm2.swift
// VibeFocus — iTerm2/TTY/AppleScript 窗口匹配
// 从 WindowManager+TerminalContext.swift 中提取

import AppKit
import Foundation

@MainActor
extension WindowManager {

    /// 通过 ITERM_SESSION_ID 用 iTerm2 AppleScript API 查找窗口
    /// ITERM_SESSION_ID 格式: w{N}t{N}p{N}:{UUID}
    /// 遍历 iTerm2 所有窗口的 session，匹配 UUID 部分找到目标窗口
    func matchiTerm2WindowBySessionID(itermSessionID: String, windows: [WindowIdentity]) -> WindowIdentity? {
        // P-INST-90: iTerm2 session UUID 窗口匹配耗时（runShellCommand /bin/bash -c osascript fork 遍历 iTerm2 windows/tabs/sessions 匹配 UUID；findWindowByTerminalContext P-INST-39 的 iTerm2 AppleScript 策略子归因；osascript IPC 到 iTerm2 进程是主要成本）。
        let mtwStart = Date()
        defer {
            log("[WindowManager] matchiTerm2WindowBySessionID finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: mtwStart))
            ])
        }
        guard let uuidPart = Self.parseItermSessionUUID(itermSessionID) else { return nil }

        // Allowlist validation: iTerm2 session UUID 只含 hex + hyphen
        guard Self.isValidUUIDPart(uuidPart) else {
            log(
                "[WindowManager] matchiTerm2WindowBySessionID: invalid UUID format, skipping",
                level: .warn,
                fields: ["itermSessionID": String(itermSessionID.prefix(8)) + "..."]
            )
            return nil
        }

        let escapedUUID = uuidPart
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        osascript -e 'tell application "iTerm2"
            set targetUUID to "\(escapedUUID)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set sid to (id of s) as text
                        if sid contains targetUUID then
                            return (id of w) as text
                        end if
                    end repeat
                end repeat
            end repeat
            return ""
        end tell'
        """
        let result = runShellCommand("/bin/bash", args: ["-c", script])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !result.isEmpty, let windowID = UInt32(result) {
            log(
                "[WindowManager] matchiTerm2WindowBySessionID: found window by iTerm2 AppleScript",
                fields: ["itermSessionID": itermSessionID, "windowID": String(windowID)]
            )
            if let match = windows.first(where: { $0.windowID == windowID }) {
                return match
            }
            let appName = "iTerm2"
            let bundleID = "com.googlecode.iterm2"
            return WindowIdentity(
                windowID: windowID,
                pid: windows.first?.pid ?? 0,
                bundleIdentifier: bundleID,
                appName: appName,
                title: nil
            )
        }

        log(
            "[WindowManager] matchiTerm2WindowBySessionID: AppleScript returned no match",
            level: .debug,
            fields: ["itermSessionID": itermSessionID, "result": result.isEmpty ? "(empty)" : result]
        )
        return nil
    }

    /// 通过 Shell 命令查询 Terminal.app 窗口，按 TTY 精确匹配
    /// Terminal.app 不在 CGWindowList 中暴露窗口标题，用 osascript 获取 TTY→窗口ID 映射
    func matchTerminalWindowByAppleScript(tty: String, terminalPID: Int32, windows: [WindowIdentity]) -> WindowIdentity? {
        // P-INST-91: Terminal.app TTY 窗口匹配耗时（runShellCommand /bin/bash -c osascript fork 遍历 Terminal windows/tabs 按 tty 匹配；findWindowByTerminalContext P-INST-39 的 Terminal AppleScript 策略子归因；osascript IPC 到 Terminal.app 是主要成本）。
        let mtwaStart = Date()
        defer {
            log("[WindowManager] matchTerminalWindowByAppleScript finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: mtwaStart))
            ])
        }
        let fullTTY = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"

        // Allowlist validation: TTY 必须匹配 /dev/ttys### 或 /dev/pty### 格式
        guard Self.isValidTTYPath(fullTTY) else {
            log(
                "[WindowManager] matchTerminalWindowByAppleScript: invalid TTY format, skipping",
                level: .warn,
                fields: ["tty": String(fullTTY.prefix(16))]
            )
            return nil
        }

        // 对 TTY 路径做 AppleScript 转义：替换双引号和反斜杠，防止注入
        let escapedTTY = fullTTY
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        osascript -e 'tell application "Terminal"
            set winCount to count of windows
            repeat with i from 1 to winCount
                try
                    repeat with tb in tabs of window i
                        if tty of tb is "\(escapedTTY)" then
                            return (id of window i) as text
                        end if
                    end repeat
                end try
            end repeat
            return ""
        end tell'
        """
        let scriptResult = runShellCommand("/bin/bash", args: ["-c", script])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !scriptResult.isEmpty, let windowID = UInt32(scriptResult) {
            log(
                "[WindowManager] matchTerminalWindowByShellScript: found window by osascript",
                fields: ["tty": fullTTY, "windowID": String(windowID)]
            )
            if let match = windows.first(where: { $0.windowID == windowID }) {
                return match
            }
            let appName = NSRunningApplication(processIdentifier: terminalPID)?.localizedName ?? "Terminal"
            let bundleID = NSRunningApplication(processIdentifier: terminalPID)?.bundleIdentifier
            return WindowIdentity(
                windowID: windowID,
                pid: terminalPID,
                bundleIdentifier: bundleID,
                appName: appName,
                title: nil
            )
        }

        log(
            "[WindowManager] matchTerminalWindowByShellScript: osascript failed",
            level: .debug,
            fields: ["tty": fullTTY, "terminalPID": String(terminalPID)]
        )

        return nil
    }

    /// 通过 TTY 上的进程 command 在候选窗口中精确匹配
    func matchWindowByTTYProcess(tty: String, windows: [WindowIdentity]) -> WindowIdentity? {
        // P-INST-55: matchWindowByTTYProcess 耗时（ps -t fork + 命令匹配；findWindowByTerminalContext P-INST-39 的 TTY 策略子归因；底层 ps fork P-INST-49 slow-op 覆盖）。
        let mwtpStart = Date()
        defer {
            log("[WindowManager] matchWindowByTTYProcess finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: mwtpStart))
            ])
        }
        let fullTTY = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        let ttyName = String(fullTTY.dropFirst(5))

        // 获取该 TTY 上的进程
        let psOutput = runShellCommand("/bin/ps", args: ["-t", ttyName, "-o", "command="])
        guard let psOutput else {
            log(
                "[WindowManager] matchWindowByTTYProcess: ps returned no output",
                level: .debug,
                fields: ["tty": fullTTY]
            )
            return nil
        }

        let commands = Self.parseCommandBasename(from: psOutput)
        if let match = Self.matchCommandToWindowTitle(commands: commands, windows: windows) {
            return match
        }

        log(
            "[WindowManager] matchWindowByTTYProcess: no title match found",
            level: .debug,
            fields: ["tty": fullTTY, "commands": commands.joined(separator: ","), "windowCount": String(windows.count)]
        )
        return nil
    }

    /// 通过 ps 命令解析指定 PID 进程关联的 TTY 设备
    /// Claude Code (node) 由终端启动，ps -o tty= 可返回有效 TTY（如 ttys001）
    /// 即使 hook-forwarder 自身 tty 命令返回 "not a tty"
    func resolveTTY(forPID pid: Int32) -> String? {
        // P-INST-56: resolveTTY 耗时（ps -o tty= fork；findWindowByTerminalContext P-INST-39 进程树 TTY 解析子归因）。
        let rtStart = Date()
        defer {
            log("[WindowManager] resolveTTY finished", level: .debug, fields: [
                "pid": String(pid),
                "durationMs": String(elapsedMilliseconds(since: rtStart))
            ])
        }
        log(
            "[WindowManager] resolveTTY called",
            level: .debug,
            fields: ["pid": String(pid)]
        )
        let output = runShellCommand("/bin/ps", args: ["-o", "tty=", "-p", String(pid)])
        let tty = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if tty.isEmpty || tty == "??" || tty == "?" {
            log(
                "[WindowManager] resolveTTY: no TTY for pid",
                level: .debug,
                fields: ["pid": String(pid), "rawTTY": tty]
            )
            return nil
        }
        let resolved = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        log(
            "[WindowManager] resolveTTY resolved",
            level: .debug,
            fields: ["pid": String(pid), "tty": resolved]
        )
        return resolved
    }
}
