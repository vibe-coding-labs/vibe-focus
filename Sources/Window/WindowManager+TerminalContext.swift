import SwiftUI
import AppKit
import ApplicationServices.HIServices
import Foundation

// MARK: - Terminal Context Window Matching
// 通过 PID/TTY 精确定位终端窗口
@MainActor
extension WindowManager {

    // MARK: - TTY Normalization (extracted for testability)

    /// Normalize a TTY string to a full device path.
    /// Returns nil for empty, "not a tty", or nil input.
    static func normalizeTTY(_ tty: String?) -> String? {
        guard let tty, !tty.isEmpty, tty != "not a tty" else { return nil }
        return tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
    }

    // MARK: - Terminal Context Window Matching

    /// 通过 hook 辅助脚本捕获的终端上下文精确定位窗口
    /// 解决多工作区/多 Claude Code 实例场景下的窗口匹配问题
    func findWindowByTerminalContext(_ ctx: TerminalContext) -> WindowIdentity? {
        log(
            "[WindowManager] findWindowByTerminalContext called",
            level: .debug,
            fields: [
                "tty": ctx.tty ?? "nil",
                "ppid": ctx.ppid ?? "nil",
                "termSessionID": ctx.termSessionID ?? "nil",
                "itermSessionID": ctx.itermSessionID ?? "nil"
            ]
        )

        // 步骤 1: 从 PPID 向上遍历进程树，找到终端 App 的 PID
        // 进程链: hook-forwarder.sh → bash → node (hook runner) → node (Claude Code) → bash/zsh → Terminal.app
        guard let ppidStr = ctx.ppid, let startPID = Int32(ppidStr), startPID > 1 else {
            log(
                "[WindowManager] findWindowByTerminalContext: no valid PPID",
                level: .warn,
                fields: ["ppid": ctx.ppid ?? "nil"]
            )
            return nil
        }

        guard let terminalPID = TerminalRegistry.findTerminalPID(from: startPID) else {
            log(
                "[WindowManager] findWindowByTerminalContext: no terminal app found in process tree",
                level: .warn,
                fields: ["startPID": ppidStr]
            )
            return nil
        }

        let terminalAppName = NSRunningApplication(processIdentifier: terminalPID)?.localizedName
            ?? (runShellCommand("/bin/ps", args: ["-o", "comm=", "-p", String(terminalPID)])?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown")

        log(
            "[WindowManager] findWindowByTerminalContext: resolved terminal app",
            level: .debug,
            fields: [
                "terminalPID": String(terminalPID),
                "terminalApp": terminalAppName
            ]
        )

        // 步骤 2: 通过终端 App PID 查 CGWindowList 获取该 PID 下的所有窗口
        let windows = findWindowsForPID(terminalPID)
        if windows.isEmpty {
            log(
                "[WindowManager] findWindowByTerminalContext: terminal PID has no windows",
                level: .warn,
                fields: ["terminalPID": String(terminalPID)]
            )
            return nil
        }

        // 步骤 3: 精确匹配
        // 如果只有一个窗口 → 直接用（PID 级别精确）
        if windows.count == 1, let match = windows.first {
            log(
                "[WindowManager] findWindowByTerminalContext: single window for terminal PID",
                fields: ["terminalPID": String(terminalPID), "windowID": String(match.windowID)]
            )
            return match
        }

        // 多个窗口 → 用 TTY 做精确区分
        // 先解析 TTY：直接取或沿进程树解析
        let resolvedTTY: String? = {
            if let tty = ctx.tty, !tty.isEmpty, tty != "not a tty" {
                return tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
            }
            // 沿进程树向上找有效 TTY
            var currentPID = startPID
            for _ in 0..<10 {
                if let tty = resolveTTY(forPID: currentPID) {
                    return tty
                }
                let ppidOutput = runShellCommand("/bin/ps", args: ["-o", "ppid=", "-p", String(currentPID)])
                guard let nextPIDStr = ppidOutput?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let nextPID = Int32(nextPIDStr), nextPID > 1, nextPID != currentPID else {
                    break
                }
                currentPID = nextPID
            }
            return nil
        }()

        guard let tty = resolvedTTY else {
            log(
                "[WindowManager] findWindowByTerminalContext: multiple windows but no TTY to distinguish",
                level: .warn,
                fields: ["terminalPID": String(terminalPID), "windowCount": String(windows.count)]
            )
            return nil
        }

        // 用 TTY 上的进程 command 精确匹配窗口标题
        let matchedWindow = matchWindowByTTYProcess(tty: tty, windows: windows)
        if let match = matchedWindow {
            log(
                "[WindowManager] findWindowByTerminalContext: matched window by TTY process",
                fields: ["tty": tty, "windowID": String(match.windowID)]
            )
            return match
        }

        log(
            "[WindowManager] findWindowByTerminalContext: TTY process match failed, trying iTerm2 session ID",
            level: .debug,
            fields: ["tty": tty, "terminalApp": terminalAppName, "hasItermSessionID": String(ctx.itermSessionID?.isEmpty == false)]
        )

        // iTerm2: 用 ITERM_SESSION_ID 通过 AppleScript 精确匹配
        if let itermSID = ctx.itermSessionID, !itermSID.isEmpty {
            let iTerm2Start = Date()
            if let match = matchiTerm2WindowBySessionID(itermSessionID: itermSID, windows: windows) {
                log(
                    "[WindowManager] findWindowByTerminalContext: matched iTerm2 window by session ID",
                    fields: ["itermSessionID": itermSID, "windowID": String(match.windowID), "durationMs": String(elapsedMilliseconds(since: iTerm2Start))]
                )
                return match
            }
            log(
                "[WindowManager] findWindowByTerminalContext: iTerm2 AppleScript match failed",
                level: .debug,
                fields: ["itermSessionID": itermSID, "durationMs": String(elapsedMilliseconds(since: iTerm2Start))]
            )
        }

        // Fallback: Terminal.app 的 CGWindowList 无窗口标题，用 AppleScript 按 TTY 查窗口 ID
        if let match = matchTerminalWindowByAppleScript(tty: tty, terminalPID: terminalPID, windows: windows) {
            log(
                "[WindowManager] findWindowByTerminalContext: matched window by AppleScript TTY lookup",
                fields: ["tty": tty, "windowID": String(match.windowID)]
            )
            return match
        }

        log(
            "[WindowManager] findWindowByTerminalContext: all matching methods failed among \(windows.count) windows",
            level: .warn,
            fields: [
                "tty": tty,
                "terminalPID": String(terminalPID),
                "terminalApp": terminalAppName,
                "itermSessionID": ctx.itermSessionID ?? "nil",
                "strategiesAttempted": "TTY_process,iTerm2_applescript,Terminal_applescript"
            ]
        )
        return nil
    }

    /// Filter CGWindowEntry list to visible windows for a given PID — extracted for testability.
    static func filterWindowsByPID(
        entries: [CGWindowEntry],
        targetPID: Int32,
        appName: String?,
        bundleID: String?
    ) -> [WindowIdentity] {
        entries.filter { $0.layer == 0 && $0.ownerPID == targetPID }.map { entry in
            WindowIdentity(
                windowID: entry.windowID,
                pid: entry.ownerPID,
                bundleIdentifier: bundleID,
                appName: appName,
                title: entry.name
            )
        }
    }

    /// Match a command name against window title patterns — extracted for testability.
    static func matchCommandToWindowTitle(
        commands: [String],
        windows: [WindowIdentity]
    ) -> WindowIdentity? {
        for cmd in commands.reversed() {
            for win in windows {
                let titleLower = win.title?.lowercased() ?? ""
                if titleLower.contains("— \(cmd)") || titleLower.contains("— \(cmd) ◂") {
                    return win
                }
            }
        }
        return nil
    }

    /// Extract command basenames from ps output lines — extracted for testability.
    static func parseCommandBasename(from psOutput: String) -> [String] {
        var commands: [String] = []
        for line in psOutput.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let basename = URL(fileURLWithPath: String(trimmed.split(separator: " ").first ?? Substring(trimmed))).lastPathComponent
            commands.append(basename)
        }
        return commands
    }

    /// 通过 PID 查询 CGWindowList 中属于该 PID 的所有窗口
    private func findWindowsForPID(_ pid: Int32) -> [WindowIdentity] {
        let windows = cgWindowListAll()
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName
            ?? (runShellCommand("/bin/ps", args: ["-o", "comm=", "-p", String(pid)])?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown")
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        return Self.filterWindowsByPID(entries: windows, targetPID: pid, appName: appName, bundleID: bundleID)
    }

    /// Extract UUID part from iTerm2 session ID (format: w{N}t{N}p{N}:{UUID})
    static func parseItermSessionUUID(_ sessionID: String) -> String? {
        let uuidPart: String
        if let colonRange = sessionID.range(of: ":") {
            uuidPart = String(sessionID[colonRange.upperBound...])
        } else {
            uuidPart = sessionID
        }
        return uuidPart.isEmpty ? nil : uuidPart
    }

    /// 通过 ITERM_SESSION_ID 用 iTerm2 AppleScript API 查找窗口
    /// ITERM_SESSION_ID 格式: w{N}t{N}p{N}:{UUID}
    /// 遍历 iTerm2 所有窗口的 session，匹配 UUID 部分找到目标窗口
    private func matchiTerm2WindowBySessionID(itermSessionID: String, windows: [WindowIdentity]) -> WindowIdentity? {
        guard let uuidPart = Self.parseItermSessionUUID(itermSessionID) else { return nil }

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
    /// 如果 osascript 权限不足，则按 TTY 进程在 CGWindowList 窗口中的顺序推断
    private func matchTerminalWindowByAppleScript(tty: String, terminalPID: Int32, windows: [WindowIdentity]) -> WindowIdentity? {
        let fullTTY = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"

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
    private func matchWindowByTTYProcess(tty: String, windows: [WindowIdentity]) -> WindowIdentity? {
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
    private func resolveTTY(forPID pid: Int32) -> String? {
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
