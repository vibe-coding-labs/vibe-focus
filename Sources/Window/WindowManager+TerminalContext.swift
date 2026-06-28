import AppKit
import ApplicationServices.HIServices
import Foundation
import SwiftUI

// MARK: - Terminal Context Window Matching
// 通过 PID/TTY 精确定位终端窗口
// 纯函数工具已移至 WindowManager+TerminalContext+Helpers.swift
// iTerm2/TTY/AppleScript 匹配已移至 WindowManager+TerminalContext+iTerm2.swift

@MainActor
extension WindowManager {

    // MARK: - Terminal Context Window Matching

    /// 通过 hook 辅助脚本捕获的终端上下文精确定位窗口
    /// 解决多工作区/多 Claude Code 实例场景下的窗口匹配问题
    func findWindowByTerminalContext(_ ctx: TerminalContext) -> WindowIdentity? {
        // P-INST-39: findWindowByTerminalContext 总耗时（SessionStart 本地绑定核心；进程树 ps fork + CGWindowList + 可能 AppleScript；归因 handleSessionStart durationMs 中的窗口匹配阶段，匹配 strategy 见各 case log）。
        let fwtcStart = Date()
        defer {
            log("[WindowManager] findWindowByTerminalContext finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: fwtcStart))
            ])
        }
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
}
