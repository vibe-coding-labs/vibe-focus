import SwiftUI
import AppKit
import ApplicationServices.HIServices
import Foundation

// MARK: - Terminal Context Window Matching
// 通过 PID/TTY 精确定位终端窗口
@MainActor
extension WindowManager {

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
                "strategiesAttempted": "TTY_process,iTerm2_applescript,Terminal_applescript,lsof_tty_ordering"
            ]
        )
        return nil
    }

    /// 通过 PID 查询 CGWindowList 中属于该 PID 的所有窗口
    private func findWindowsForPID(_ pid: Int32) -> [WindowIdentity] {
        let windows = cgWindowListAll()

        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName
            ?? (runShellCommand("/bin/ps", args: ["-o", "comm=", "-p", String(pid)])?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown")
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier

        var results: [WindowIdentity] = []
        for entry in windows {
            guard entry.layer == 0 else { continue }
            guard entry.ownerPID == pid else { continue }

            results.append(WindowIdentity(
                windowID: entry.windowID,
                pid: entry.ownerPID,
                bundleIdentifier: bundleID,
                appName: appName,
                title: entry.name
            ))
        }
        return results
    }

    /// 通过 ITERM_SESSION_ID 用 iTerm2 AppleScript API 查找窗口
    /// ITERM_SESSION_ID 格式: w{N}t{N}p{N}:{UUID}
    /// 遍历 iTerm2 所有窗口的 session，匹配 UUID 部分找到目标窗口
    private func matchiTerm2WindowBySessionID(itermSessionID: String, windows: [WindowIdentity]) -> WindowIdentity? {
        let uuidPart: String
        if let colonRange = itermSessionID.range(of: ":") {
            uuidPart = String(itermSessionID[colonRange.upperBound...])
        } else {
            uuidPart = itermSessionID
        }

        guard !uuidPart.isEmpty else { return nil }

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

        // 方法 2: osascript 权限不足时，用 TTY 上的 login 进程的 SID 推断窗口索引
        // Terminal.app 的每个 tab 有一个 login→zsh 进程链，按创建顺序对应窗口
        // 通过 ps 获取所有属于 Terminal 的 TTY，按 ttys 编号排序，推断窗口顺序
        log(
            "[WindowManager] matchTerminalWindowByShellScript: osascript failed, trying TTY ordering fallback",
            level: .debug,
            fields: ["tty": fullTTY, "terminalPID": String(terminalPID)]
        )

        // 获取 Terminal 下所有 TTY
        // Terminal 主进程没有 TTY，用 lsof 找它打开的 tty 设备
        let lsofOutput = runShellCommand("/usr/sbin/lsof", args: ["-p", String(terminalPID)])

        // 收集该 PID 的所有 ttys
        var ttys: [String] = []
        if let lsofOutput {
            for line in lsofOutput.components(separatedBy: "\n") {
                if line.contains("tty") || line.contains("/dev/ttys") {
                    let parts = line.split(separator: " ").filter { $0.hasPrefix("/dev/ttys") || $0.hasPrefix("ttys") }
                    for part in parts {
                        let tty = part.hasPrefix("/dev/") ? String(part) : "/dev/\(part)"
                        if !ttys.contains(tty) {
                            ttys.append(tty)
                        }
                    }
                }
            }
        }

        // 如果 lsof 没结果，用 ps 找该 PID 下所有子进程的 TTY
        if ttys.isEmpty {
            let childTTYs = runShellCommand("/bin/ps", args: ["-E", "-o", "tty=", "-p", String(terminalPID)]) ?? ""
            for part in childTTYs.components(separatedBy: .whitespaces) {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("ttys") || trimmed.hasPrefix("/dev/ttys") {
                    let tty = trimmed.hasPrefix("/") ? trimmed : "/dev/\(trimmed)"
                    if !ttys.contains(tty) {
                        ttys.append(tty)
                    }
                }
            }
        }

        if ttys.isEmpty {
            log(
                "[WindowManager] matchTerminalWindowByShellScript: no TTYs found for Terminal PID",
                level: .debug,
                fields: ["terminalPID": String(terminalPID)]
            )
            return nil
        }

        // 排序 TTY 并找到目标 TTY 的索引
        ttys.sort()
        guard let targetIndex = ttys.firstIndex(of: fullTTY) else {
            log(
                "[WindowManager] matchTerminalWindowByShellScript: target TTY not in Terminal's TTY list",
                level: .debug,
                fields: ["tty": fullTTY, "availableTTYs": ttys.joined(separator: ",")]
            )
            return nil
        }

        // 按窗口 ID 排序（Terminal 的窗口 ID 通常与 tab 创建顺序一致）
        let sortedWindows = windows.sorted { $0.windowID < $1.windowID }
        if targetIndex < sortedWindows.count {
            return sortedWindows[targetIndex]
        }

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

        var commands: [String] = []
        for line in psOutput.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let basename = URL(fileURLWithPath: String(trimmed.split(separator: " ").first ?? Substring(trimmed))).lastPathComponent
            commands.append(basename)
        }

        // 用 command basename 在窗口标题中精确匹配
        for cmd in commands.reversed() {
            for win in windows {
                let titleLower = win.title?.lowercased() ?? ""
                if titleLower.contains("— \(cmd)") || titleLower.contains("— \(cmd) ◂") {
                    return win
                }
            }
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
