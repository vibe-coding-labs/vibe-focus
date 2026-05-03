import SwiftUI
import AppKit
import Carbon
import ApplicationServices.HIServices
import CoreFoundation
import Foundation

@MainActor
extension WindowManager {

    private struct WindowCandidate {
        let windowID: UInt32
        let pid: pid_t
        let appName: String
        let bundleIdentifier: String?
        let title: String
        let isOnMainScreen: Bool
    }

    func candidateApplications(for token: WindowToken) -> [NSRunningApplication] {
        var applications: [NSRunningApplication] = []

        func appendIfNeeded(_ app: NSRunningApplication?) {
            guard let app else { return }
            if !applications.contains(where: { $0.processIdentifier == app.processIdentifier }) {
                applications.append(app)
            }
        }

        appendIfNeeded(NSRunningApplication(processIdentifier: token.pid))

        if let bundleIdentifier = token.bundleIdentifier {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
                appendIfNeeded(app)
            }
        }

        if let appName = token.appName {
            for app in NSWorkspace.shared.runningApplications where app.localizedName == appName {
                appendIfNeeded(app)
            }
        }

        appendIfNeeded(NSWorkspace.shared.frontmostApplication)
        return applications
    }

    func captureFocusedWindowIdentity() -> WindowIdentity? {
        log(
            "[WindowManager] captureFocusedWindowIdentity called",
            level: .debug
        )
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            log(
                "[WindowManager] captureFocusedWindowIdentity: no frontmost app",
                level: .debug
            )
            return nil
        }
        guard let windowAX = focusedWindow(for: frontApp.processIdentifier) else {
            log(
                "[WindowManager] captureFocusedWindowIdentity: no focused window for pid",
                level: .debug,
                fields: ["pid": String(frontApp.processIdentifier)]
            )
            return nil
        }
        guard let windowID = windowHandle(for: windowAX) else {
            log(
                "[WindowManager] captureFocusedWindowIdentity: no window handle",
                level: .debug,
                fields: ["pid": String(frontApp.processIdentifier)]
            )
            return nil
        }
        let identity = WindowIdentity(
            windowID: windowID,
            pid: frontApp.processIdentifier,
            bundleIdentifier: frontApp.bundleIdentifier,
            appName: frontApp.localizedName,
            windowNumber: windowNumber(for: windowAX),
            title: title(of: windowAX),
            capturedAt: Date()
        )
        log(
            "[WindowManager] captureFocusedWindowIdentity result",
            level: .debug,
            fields: [
                "windowID": String(identity.windowID),
                "pid": String(identity.pid),
                "bundleID": identity.bundleIdentifier ?? "nil",
                "title": truncateForLog(identity.title ?? "", limit: 60)
            ]
        )
        return identity
    }

    /// 在所有窗口中查找最可能是 Claude Code 会话对应的窗口
    /// 策略优先级：
    ///   0. 通过终端上下文（TTY/SESSION_ID）精确匹配（command-type hook 提供）
    ///   1. Terminal/Cursor 等 IDE 窗口中标题包含 cwd 项目名的窗口（在非主屏幕上）
    ///   2. 任意窗口中标题包含 cwd 项目名（在非主屏幕上）
    ///   3. 包含 "Claude Code" 关键词的窗口（在非主屏幕上）
    ///   4. 当前前台窗口
    func findClaudeCodeWindow(cwd: String?) -> WindowIdentity? {
        log(
            "[WindowManager] findClaudeCodeWindow called",
            level: .debug,
            fields: ["cwd": cwd ?? "nil"]
        )
        let options = CGWindowListOption(arrayLiteral: .optionAll)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            log(
                "[WindowManager] findClaudeCodeWindow: CGWindowList returned nil",
                level: .debug
            )
            return nil
        }

        let mainScreen = getMainScreen()
        let mainScreenFrame = mainScreen?.frame

        // 从 cwd 中提取项目名（最后一段路径）
        let projectName = cwd?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .components(separatedBy: "/")
            .last?
            .lowercased()

        // Claude Code 常用的终端/IDE 的 bundleIdentifier
        let claudeHostApps: Set<String> = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.microsoft.VSCode",
            "com.todesktop.230313mzl4w4u92", // Cursor
            "dev.warp.Warp-Stable",
            "com.mitchellh.ghostty",
        ]

        // 构建候选窗口列表
        var candidates: [WindowCandidate] = []
        for info in windowList {
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue } // 只看普通窗口

            guard let windowID = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else {
                continue
            }

            let appName = info[kCGWindowOwnerName as String] as? String ?? ""
            let title = info["kCGWindowName"] as? String ?? info["name"] as? String ?? ""
            let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
            let isOnMainScreen: Bool
            if let bounds, let mainScreenFrame {
                let windowFrame = CGRect(
                    x: bounds["X"] ?? 0,
                    y: bounds["Y"] ?? 0,
                    width: bounds["Width"] ?? 0,
                    height: bounds["Height"] ?? 0
                )
                let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
                isOnMainScreen = mainScreenFrame.contains(center)
            } else {
                isOnMainScreen = false
            }

            // 获取 bundleIdentifier
            let bundleIdentifier: String?
            if let app = NSRunningApplication(processIdentifier: pid) {
                bundleIdentifier = app.bundleIdentifier
            } else {
                bundleIdentifier = nil
            }

            candidates.append(WindowCandidate(
                windowID: windowID,
                pid: pid,
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                title: title,
                isOnMainScreen: isOnMainScreen
            ))
        }

        // 策略 1：Claude Host App 窗口中标题包含 cwd 项目名
        if let projectName, !projectName.isEmpty {
            let match = candidates.first(where: { c in
                let isHostApp = (c.bundleIdentifier.map { claudeHostApps.contains($0) } ?? false)
                    || c.appName == "Terminal" || c.appName == "iTerm2" || c.appName == "Cursor"
                    || c.appName == "Warp" || c.appName == "Ghostty" || c.appName == "Alacritty"
                return isHostApp && c.title.lowercased().contains(projectName)
            })
            if let match {
                log(
                    "[WindowManager] findClaudeCodeWindow matched strategy 1: hostApp+cwd",
                    fields: [
                        "app": match.appName,
                        "title": truncateForLog(match.title, limit: 80),
                        "windowID": String(match.windowID),
                        "projectName": projectName
                    ]
                )
                return makeIdentity(from: match)
            }
        }

        // 策略 2：Claude Host App 窗口中标题包含 "Claude Code" 且在非主屏幕
        let claudeMatch = candidates.first(where: { c in
            let isHostApp = (c.bundleIdentifier.map { claudeHostApps.contains($0) } ?? false)
                || c.appName == "Terminal" || c.appName == "iTerm2" || c.appName == "Cursor"
                || c.appName == "Warp" || c.appName == "Ghostty" || c.appName == "Alacritty"
            return isHostApp && c.title.lowercased().contains("claude code")
        })
        if let claudeMatch {
            log(
                "[WindowManager] findClaudeCodeWindow matched strategy 2: hostApp+claudeCode",
                fields: [
                    "app": claudeMatch.appName,
                    "title": truncateForLog(claudeMatch.title, limit: 80),
                    "windowID": String(claudeMatch.windowID)
                ]
            )
            return makeIdentity(from: claudeMatch)
        }

        // 策略 4：回退到前台窗口
        log(
            "[WindowManager] findClaudeCodeWindow falling back to focused window",
            fields: [
                "cwd": cwd ?? "nil",
                "projectName": projectName ?? "nil",
                "candidateCount": String(candidates.count)
            ]
        )
        return captureFocusedWindowIdentity()
    }

    private func makeIdentity(from candidate: WindowCandidate) -> WindowIdentity {
        let bundleID = candidate.bundleIdentifier
            ?? NSRunningApplication(processIdentifier: candidate.pid)?.bundleIdentifier
        return WindowIdentity(
            windowID: candidate.windowID,
            pid: candidate.pid,
            bundleIdentifier: bundleID,
            appName: candidate.appName,
            windowNumber: nil,
            title: candidate.title,
            capturedAt: Date()
        )
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
        // 策略 1: 通过 TTY 匹配 Terminal.app / iTerm2 窗口（原始路径）
        if let tty = ctx.tty, !tty.isEmpty, tty != "not a tty" {
            if let identity = findWindowByTTY(tty) {
                log(
                    "[WindowManager] findWindowByTerminalContext matched by TTY",
                    fields: ["tty": tty, "app": identity.appName ?? "unknown"]
                )
                return identity
            }
        }

        // 策略 1.5: 通过 PPID 进程树向上遍历，每层尝试 TTY 解析
        // hook-forwarder 的 tty 返回 "not a tty"，直接 PPID 可能也没有 TTY
        // 但进程链上层的 bash/zsh 一定有关联 TTY
        // 进程链: hook-forwarder → node (hook runner) → node (Claude Code) → bash/zsh → Terminal.app
        if let ppidStr = ctx.ppid, let startPID = Int32(ppidStr), startPID > 1 {
            var currentPID = startPID
            var depth = 0
            while depth < 10 {
                if let resolvedTTY = resolveTTY(forPID: currentPID) {
                    if let identity = findWindowByTTY(resolvedTTY) {
                        log(
                            "[WindowManager] findWindowByTerminalContext matched by resolved TTY from PPID tree",
                            fields: [
                                "startPID": ppidStr,
                                "resolvedPID": String(currentPID),
                                "depth": String(depth),
                                "resolvedTTY": resolvedTTY,
                                "app": identity.appName ?? "unknown"
                            ]
                        )
                        return identity
                    }
                }
                // 向上移动到父进程
                let ppidOutput = runShellCommand("/bin/ps", args: ["-o", "ppid=", "-p", String(currentPID)])
                guard let nextPIDStr = ppidOutput?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let nextPID = Int32(nextPIDStr), nextPID > 1, nextPID != currentPID else {
                    break
                }
                currentPID = nextPID
                depth += 1
            }
        }

        // 策略 2: 通过 PPID 进程树匹配（适用于 IDE 集成终端等场景）
        if let ppidStr = ctx.ppid, let shellPID = Int32(ppidStr), shellPID > 1 {
            if let identity = findWindowByProcessAncestor(pid: shellPID) {
                log(
                    "[WindowManager] findWindowByTerminalContext matched by process ancestor",
                    fields: ["ppid": ppidStr, "app": identity.appName ?? "unknown"]
                )
                return identity
            }
        }

        log(
            "[WindowManager] findWindowByTerminalContext: no match",
            level: .warn,
            fields: [
                "tty": ctx.tty ?? "nil",
                "ppid": ctx.ppid ?? "nil",
                "termSessionID": ctx.termSessionID ?? "nil",
                "itermSessionID": ctx.itermSessionID ?? "nil"
            ]
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

    /// 通过 TTY 查找 Terminal.app / iTerm2 窗口
    /// 使用 CGWindowList + 进程信息匹配（避免 JXA 的 macOS Automation TCC 限制）
    private func findWindowByTTY(_ tty: String) -> WindowIdentity? {
        let fullTTY = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        log(
            "[WindowManager] findWindowByTTY called",
            level: .debug,
            fields: ["tty": fullTTY]
        )

        // 获取该 TTY 上的所有进程
        let ttyName = fullTTY.hasPrefix("/dev/") ? String(fullTTY.dropFirst(5)) : fullTTY
        let psOutput = runShellCommand("/bin/ps", args: ["-t", ttyName, "-o", "pid=,command="])
        guard let psOutput else {
            log(
                "[WindowManager] findWindowByTTY: ps -t returned nil",
                level: .warn,
                fields: ["tty": fullTTY]
            )
            return nil
        }

        // 解析进程列表，提取每个进程的 PID 和 command
        var ttyProcesses: [(pid: Int32, command: String)] = []
        for line in psOutput.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = Int32(parts[0]) else { continue }
            ttyProcesses.append((pid, String(parts[1])))
        }

        log(
            "[WindowManager] findWindowByTTY: parsed TTY processes",
            level: .debug,
            fields: [
                "tty": fullTTY,
                "processCount": String(ttyProcesses.count),
                "commands": ttyProcesses.map { "\($0.pid):\($0.command.prefix(40))" }.joined(separator: ", ")
            ]
        )

        // 在 CGWindowList 中找到终端窗口
        // 关键：Terminal.app/iTerm2 所有窗口共享一个 PID，所以需要通过标题区分
        let options = CGWindowListOption(arrayLiteral: .optionAll)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // 收集终端窗口
        let terminalAppNames: Set<String> = ["Terminal", "iTerm2", "Warp", "Ghostty", "Alacritty", "kitty"]
        var terminalWindows: [(windowID: UInt32, pid: pid_t, appName: String, title: String, bundleIdentifier: String?)] = []

        for info in windowList {
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }

            guard let windowID = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else {
                continue
            }

            let appName = info[kCGWindowOwnerName as String] as? String ?? ""
            let title = info["kCGWindowName"] as? String ?? info["name"] as? String ?? ""

            guard terminalAppNames.contains(appName) else { continue }

            let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            terminalWindows.append((windowID, pid, appName, title, bundleID))
        }

        if terminalWindows.isEmpty {
            log(
                "[WindowManager] findWindowByTTY: no terminal windows found in CGWindowList",
                level: .warn,
                fields: ["tty": fullTTY]
            )
            return nil
        }

        // 策略 1：通过 TTY 进程的 command 在窗口标题中做精确匹配
        // Terminal.app 窗口标题格式: "项目名 — ⠐ Claude Code — command ◂ args — 160×45"
        // 我们用 TTY 上运行的实际 command 来匹配
        for proc in ttyProcesses.reversed() {
            let command = proc.command
            // 提取 command 的 basename（例如 "claude" 从 "/usr/local/bin/claude"）
            let commandBasename = URL(fileURLWithPath: String(command.split(separator: " ").first ?? Substring(command))).lastPathComponent

            // 在标题中查找包含该 command 的终端窗口
            // 标题中的 command 部分通常是 "command ◂ args" 格式
            for win in terminalWindows {
                let titleLower = win.title.lowercased()
                // 精确匹配：标题中 "— command" 或 "— command ◂"
                if titleLower.contains("— \(commandBasename)") || titleLower.contains("— \(commandBasename) ◂") {
                    log(
                        "[WindowManager] findWindowByTTY matched by command in title",
                        level: .info,
                        fields: [
                            "tty": fullTTY,
                            "command": commandBasename,
                            "app": win.appName,
                            "title": truncateForLog(win.title, limit: 80),
                            "windowID": String(win.windowID)
                        ]
                    )
                    return WindowIdentity(
                        windowID: win.windowID,
                        pid: win.pid,
                        bundleIdentifier: win.bundleIdentifier,
                        appName: win.appName,
                        windowNumber: nil,
                        title: win.title,
                        capturedAt: Date()
                    )
                }
            }
        }

        // 策略 2：如果只有一个终端窗口，直接使用
        if terminalWindows.count == 1, let match = terminalWindows.first {
            log(
                "[WindowManager] findWindowByTTY: single terminal window",
                level: .info,
                fields: [
                    "tty": fullTTY,
                    "app": match.appName,
                    "title": truncateForLog(match.title, limit: 80),
                    "windowID": String(match.windowID)
                ]
            )
            return WindowIdentity(
                windowID: match.windowID,
                pid: match.pid,
                bundleIdentifier: match.bundleIdentifier,
                appName: match.appName,
                windowNumber: nil,
                title: match.title,
                capturedAt: Date()
            )
        }

        // 策略 3：用 CWD 匹配（最后手段，保留了旧逻辑作为兜底）
        let foregroundPID = getForegroundProcessOnTTY(fullTTY)
        let processCWD = foregroundPID.flatMap { getCWDOfProcess($0) }
        if let identity = findTerminalWindowByCWDMatch(processCWD: processCWD, tty: fullTTY) {
            return identity
        }

        log(
            "[WindowManager] findWindowByTTY: no match",
            level: .warn,
            fields: [
                "tty": fullTTY,
                "terminalWindowCount": String(terminalWindows.count),
                "ttyProcessCount": String(ttyProcesses.count)
            ]
        )
        return nil
    }

    /// 通过 ps 命令获取指定 TTY 上的前台进程 PID
    private func getForegroundProcessOnTTY(_ fullTTY: String) -> Int32? {
        let ttyName = fullTTY.hasPrefix("/dev/") ? String(fullTTY.dropFirst(5)) : fullTTY
        let output = runShellCommand("/bin/ps", args: ["-t", ttyName, "-o", "pid="])
        guard let output else { return nil }

        let pids = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 > 1 }

        return pids.last
    }

    /// 通过 lsof 获取进程的 CWD
    private func getCWDOfProcess(_ pid: Int32) -> String? {
        let output = runShellCommand("/usr/sbin/lsof", args: ["-p", String(pid), "-Fn"])
        guard let output else { return nil }

        let lines = output.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("n/") {
                return String(line.dropFirst(1))
            }
        }
        return nil
    }

    /// 在 CGWindowList 中通过 CWD 匹配 Terminal.app / iTerm2 窗口
    private func findTerminalWindowByCWDMatch(processCWD: String?, tty: String) -> WindowIdentity? {
        let options = CGWindowListOption(arrayLiteral: .optionAll)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let cwdBasename = processCWD?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .components(separatedBy: "/")
            .last?
            .lowercased()

        let terminalAppNames: Set<String> = ["Terminal", "iTerm2"]

        var candidates: [(windowID: UInt32, pid: pid_t, appName: String, title: String, cwdMatch: Bool)] = []

        for info in windowList {
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }

            guard let windowID = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else {
                continue
            }

            let appName = info[kCGWindowOwnerName as String] as? String ?? ""
            let title = info["kCGWindowName"] as? String ?? info["name"] as? String ?? ""

            guard terminalAppNames.contains(appName) else { continue }

            let cwdMatch: Bool
            if let cwdBasename, !cwdBasename.isEmpty {
                cwdMatch = title.lowercased().contains(cwdBasename)
            } else {
                cwdMatch = false
            }

            candidates.append((windowID, pid, appName, title, cwdMatch))
        }

        // 优先匹配 CWD basename 在标题中的窗口
        if let cwdBasename, !cwdBasename.isEmpty {
            if let match = candidates.first(where: { $0.cwdMatch }) {
                let bundleID = NSRunningApplication(processIdentifier: match.pid)?.bundleIdentifier
                log(
                    "[WindowManager] findWindowByTTY matched via CWD in title",
                    fields: [
                        "tty": tty,
                        "cwdBasename": cwdBasename,
                        "app": match.appName,
                        "title": truncateForLog(match.title, limit: 80),
                        "windowID": String(match.windowID)
                    ]
                )
                return WindowIdentity(
                    windowID: match.windowID,
                    pid: match.pid,
                    bundleIdentifier: bundleID,
                    appName: match.appName,
                    windowNumber: nil,
                    title: match.title,
                    capturedAt: Date()
                )
            }
        }

        // 如果只有一个终端窗口，直接使用
        if candidates.count == 1, let match = candidates.first {
            let bundleID = NSRunningApplication(processIdentifier: match.pid)?.bundleIdentifier
            log(
                "[WindowManager] findWindowByTTY: single terminal window",
                fields: [
                    "tty": tty,
                    "app": match.appName,
                    "title": truncateForLog(match.title, limit: 80),
                    "windowID": String(match.windowID)
                ]
            )
            return WindowIdentity(
                windowID: match.windowID,
                pid: match.pid,
                bundleIdentifier: bundleID,
                appName: match.appName,
                windowNumber: nil,
                title: match.title,
                capturedAt: Date()
            )
        }

        log(
            "[WindowManager] findWindowByTTY: no match",
            level: .warn,
            fields: [
                "tty": tty,
                "cwdBasename": cwdBasename ?? "nil",
                "candidateCount": String(candidates.count)
            ]
        )
        return nil
    }

    /// 通过 CGWindowList 检查指定窗口是否当前在主屏幕上
    /// 用于 hook 路径在执行窗口移动前的预检，避免对已在主屏的窗口执行无意义的移动
    func isWindowOnMainScreen(windowID: UInt32) -> Bool {
        log(
            "[WindowManager] isWindowOnMainScreen called",
            level: .debug,
            fields: ["windowID": String(windowID)]
        )
        let options = CGWindowListOption(arrayLiteral: .optionAll)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            log(
                "[WindowManager] isWindowOnMainScreen: CGWindowList returned nil",
                level: .debug
            )
            return false
        }
        guard let mainScreen = getMainScreen() else {
            log(
                "[WindowManager] isWindowOnMainScreen: no main screen",
                level: .debug
            )
            return false
        }
        let mainScreenFrame = mainScreen.frame

        for info in windowList {
            guard let id = info[kCGWindowNumber as String] as? UInt32,
                  id == windowID else { continue }
            let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
            guard let bounds else {
                log(
                    "[WindowManager] isWindowOnMainScreen: no bounds for window",
                    level: .debug,
                    fields: ["windowID": String(windowID)]
                )
                return false
            }
            let windowFrame = CGRect(
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0
            )
            let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
            let onMainScreen = mainScreenFrame.contains(center)
            log(
                "[WindowManager] isWindowOnMainScreen result",
                level: .debug,
                fields: [
                    "windowID": String(windowID),
                    "onMainScreen": String(onMainScreen),
                    "windowCenterX": "\(center.x)",
                    "windowCenterY": "\(center.y)"
                ]
            )
            return onMainScreen
        }
        log(
            "[WindowManager] isWindowOnMainScreen: window not found in list",
            level: .debug,
            fields: ["windowID": String(windowID)]
        )
        return false
    }

    /// 在 CGWindowList 中按 owner + title 查找窗口
    private func findWindowInCGList(ownerName: String, windowTitle: String) -> WindowIdentity? {
        log(
            "[WindowManager] findWindowInCGList called",
            level: .debug,
            fields: ["ownerName": ownerName, "windowTitle": truncateForLog(windowTitle, limit: 60)]
        )
        let options = CGWindowListOption(arrayLiteral: .optionAll)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in windowList {
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }

            let appName = info[kCGWindowOwnerName as String] as? String ?? ""
            let title = info["kCGWindowName"] as? String ?? info["name"] as? String ?? ""

            guard appName == ownerName && title == windowTitle else { continue }

            guard let windowID = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else {
                continue
            }

            let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            return WindowIdentity(
                windowID: windowID,
                pid: pid,
                bundleIdentifier: bundleID,
                appName: appName,
                windowNumber: nil,
                title: title,
                capturedAt: Date()
            )
        }

        return nil
    }

    /// 通过进程 PID 向上遍历进程树，找到终端/IDE 应用对应的窗口
    private func findWindowByProcessAncestor(pid: Int32) -> WindowIdentity? {
        log(
            "[WindowManager] findWindowByProcessAncestor called",
            level: .debug,
            fields: ["pid": String(pid)]
        )
        // 已知的终端和 IDE 应用名称
        let terminalAppNames: Set<String> = [
            "Terminal", "iTerm2", "Warp", "Ghostty", "Alacritty", "kitty",
            "Cursor", "Code", "Visual Studio Code",
            "com.apple.Terminal", "com.googlecode.iterm2",
            "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"
        ]

        // 向上遍历进程树，最多 10 层
        var currentPID = pid
        for _ in 0..<10 {
            // 获取进程名
            let nameOutput = runShellCommand("/bin/ps", args: ["-o", "comm=", "-p", String(currentPID)])
            let name = nameOutput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if terminalAppNames.contains(name) {
                // 找到终端/IDE 应用，查找其窗口
                return findWindowByPIDForTerminal(currentPID, appName: name)
            }

            // 获取父进程 PID
            let ppidOutput = runShellCommand("/bin/ps", args: ["-o", "ppid=", "-p", String(currentPID)])
            guard let ppidStr = ppidOutput?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let parentPID = Int32(ppidStr), parentPID > 1 else {
                break
            }
            currentPID = parentPID
        }

        return nil
    }

    /// 通过 PID 查找终端应用的窗口（优先选非主屏幕窗口）
    private func findWindowByPIDForTerminal(_ pid: Int32, appName: String) -> WindowIdentity? {
        log(
            "[WindowManager] findWindowByPIDForTerminal called",
            level: .debug,
            fields: ["pid": String(pid), "appName": appName]
        )
        let options = CGWindowListOption(arrayLiteral: .optionAll)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let mainScreen = getMainScreen()
        let mainScreenFrame = mainScreen?.frame

        var bestCandidate: (windowID: UInt32, title: String, isOnMainScreen: Bool)?

        for info in windowList {
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }

            guard let windowPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  windowPID == pid,
                  let windowID = info[kCGWindowNumber as String] as? UInt32 else {
                continue
            }

            let title = info["kCGWindowName"] as? String ?? info["name"] as? String ?? ""
            let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
            let isOnMainScreen: Bool
            if let bounds, let mainScreenFrame {
                let frame = CGRect(
                    x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                    width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0
                )
                isOnMainScreen = mainScreenFrame.contains(CGPoint(x: frame.midX, y: frame.midY))
            } else {
                isOnMainScreen = false
            }

            // 优先选非主屏幕窗口
            if bestCandidate == nil || (!isOnMainScreen && bestCandidate!.isOnMainScreen) {
                bestCandidate = (windowID, title, isOnMainScreen)
            }
        }

        guard let match = bestCandidate else { return nil }

        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        return WindowIdentity(
            windowID: match.windowID,
            pid: pid,
            bundleIdentifier: bundleID,
            appName: appName,
            windowNumber: nil,
            title: match.title,
            capturedAt: Date()
        )
    }

    /// 执行 shell 命令并返回输出
    private func runShellCommand(_ executable: String, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    func resolveWindow(identity: WindowIdentity) -> AXUIElement? {
        log(
            "[WindowManager] resolveWindow called",
            level: .debug,
            fields: [
                "windowID": String(identity.windowID),
                "pid": String(identity.pid),
                "bundleID": identity.bundleIdentifier ?? "nil",
                "title": truncateForLog(identity.title ?? "", limit: 60)
            ]
        )
        let pid = pid_t(identity.pid)
        if let focused = focusedWindow(for: pid),
           let focusedID = windowHandle(for: focused),
           focusedID == identity.windowID {
            log(
                "[WindowManager] resolveWindow: matched focused window",
                level: .debug,
                fields: ["windowID": String(identity.windowID)]
            )
            return focused
        }

        let windows = allWindows(for: pid)
        if let exactID = windows.first(where: { window in
            guard let currentID = windowHandle(for: window) else { return false }
            return currentID == identity.windowID
        }) {
            return exactID
        }

        if let number = identity.windowNumber,
           let matched = windows.first(where: { windowNumber(for: $0) == number }) {
            return matched
        }

        if let expectedTitle = identity.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !expectedTitle.isEmpty,
           let matched = windows.first(where: {
               self.title(of: $0)?.trimmingCharacters(in: .whitespacesAndNewlines) == expectedTitle
           }) {
            return matched
        }

        return windows.first
    }

    @discardableResult
    func moveWindowToMainScreen(
        identity: WindowIdentity,
        reason: WindowMoveReason,
        sessionID: String?,
        operationID: String? = nil
    ) -> Bool {
        let op = operationID ?? makeOperationID(prefix: "move")
        let startedAt = Date()
        log(
            "[WindowManager] moveWindowToMainScreen started",
            fields: [
                "op": op,
                "windowID": String(identity.windowID),
                "pid": String(identity.pid),
                "reason": reason.rawValue,
                "sessionID": sessionID ?? "nil"
            ]
        )

        guard hasAccessibilityPermission() else {
            log(
                "moveWindowToMainScreen failed: accessibility not granted",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            notifyAccessibilityPermissionRequired()
            return false
        }

        log(
            "[moveWindowToMainScreen] AX permission OK, resolving window",
            level: .debug,
            fields: [
                "op": op,
                "windowID": String(identity.windowID),
                "pid": String(identity.pid)
            ]
        )

        guard let windowAX = resolveWindow(identity: identity) else {
            log(
                "moveWindowToMainScreen failed: cannot resolve window",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            return false
        }

        log(
            "[moveWindowToMainScreen] resolved window AX element",
            level: .debug,
            fields: [
                "op": op,
                "windowID": String(identity.windowID)
            ]
        )

        guard let currentFrame = frame(of: windowAX) else {
            log(
                "moveWindowToMainScreen failed: cannot read current frame",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            return false
        }

        log(
            "[moveWindowToMainScreen] read current frame",
            level: .debug,
            fields: [
                "op": op,
                "currentFrame": String(describing: currentFrame)
            ]
        )

        // 检查窗口是否已在主屏幕上
        // 使用 yabai display 信息作为主要判断依据
        // AX frame 对非可见工作区的窗口不可靠（macOS 会报告错误的坐标）
        log(
            "[moveWindowToMainScreen] checking if window already on main screen",
            level: .debug,
            fields: ["op": op]
        )
        let yabaiDisplay = spaceController.windowDisplayIndex(windowID: identity.windowID)
        if let display = yabaiDisplay, display != 1 {
            // yabai 报告窗口在副显示器上，即使 AX frame 看起来在主屏也继续移动
            log(
                "[WindowManager] yabai reports window on secondary display, proceeding with move",
                fields: [
                    "op": op,
                    "windowID": String(identity.windowID),
                    "yabaiDisplay": String(display),
                    "axFrame": "\(currentFrame)"
                ]
            )
        } else if let mainScreen = getMainScreen() {
            let mainScreenFrame = mainScreen.frame
            let windowCenter = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
            if mainScreenFrame.contains(windowCenter) {
                log(
                    "[WindowManager] moveWindowToMainScreen skipped: already on main screen",
                    fields: [
                        "op": op,
                        "windowID": String(identity.windowID),
                        "reason": reason.rawValue,
                        "yabaiDisplay": yabaiDisplay.map(String.init) ?? "nil"
                    ]
                )
                return true
            }
        }

        log(
            "[moveWindowToMainScreen] window not on main screen, getting window handle",
            level: .debug,
            fields: ["op": op]
        )

        guard let currentWindowID = windowHandle(for: windowAX) else {
            log(
                "moveWindowToMainScreen failed: missing stable window handle",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            return false
        }

        guard isAttributeSettable(windowAX, attribute: kAXPositionAttribute),
              isAttributeSettable(windowAX, attribute: kAXSizeAttribute) else {
            log(
                "moveWindowToMainScreen failed: window attributes not settable",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            return false
        }

        log(
            "[moveWindowToMainScreen] got window handle, checking settable attributes",
            level: .debug,
            fields: [
                "op": op,
                "currentWindowID": String(currentWindowID)
            ]
        )

        let sourceContext = displayContext(for: currentFrame)
        let spaceCaptureStartAt = Date()
        let spaceContext = spaceController.captureSpaceContext(windowID: currentWindowID, operationID: op)
        log(
            "[WindowManager] captured source space context",
            fields: [
                "op": op,
                "durationMs": String(elapsedMilliseconds(since: spaceCaptureStartAt))
            ]
        )

        guard let mainScreen = getMainScreen() else {
            log(
                "moveWindowToMainScreen failed: cannot determine main screen",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            return false
        }

        let targetFrame = axFrame(forVisibleFrameOf: mainScreen)
        let targetDisplayID = displayID(for: mainScreen)
        let targetDisplayIndex = displayIndex(forDisplayID: targetDisplayID)

        log(
            "[moveWindowToMainScreen] computed target frame and display",
            level: .debug,
            fields: [
                "op": op,
                "targetFrame": String(describing: targetFrame),
                "targetDisplayID": String(describing: targetDisplayID),
                "targetDisplayIndex": String(describing: targetDisplayIndex)
            ]
        )

        // 尝试通过 AX 设置窗口位置
        // apply() 内部已含容差检查（高度 100px），返回 true 表示窗口已在目标位置附近
        log(
            "[moveWindowToMainScreen] calling apply() to set frame",
            level: .debug,
            fields: [
                "op": op,
                "targetFrame": String(describing: targetFrame)
            ]
        )
        let axApplySucceeded = apply(frame: targetFrame, to: windowAX, operationID: op, stage: "move_to_main_apply_frame")
        log(
            "[moveWindowToMainScreen] apply() returned",
            level: .debug,
            fields: [
                "op": op,
                "axApplySucceeded": String(axApplySucceeded)
            ]
        )

        if !axApplySucceeded {
            // apply 本身失败 — 尝试 CGWindowList 验证后重试
            log(
                "[WindowManager] AX apply failed, trying CGWindowList fallback + retry",
                level: .warn,
                fields: [
                    "op": op,
                    "windowID": String(identity.windowID)
                ]
            )

            usleep(100_000)

            let cgVerified = verifyWindowFrameViaCGWindowList(
                windowID: identity.windowID,
                targetFrame: targetFrame,
                operationID: op
            )

            if !cgVerified {
                usleep(150_000)
                let retrySucceeded = apply(frame: targetFrame, to: windowAX, operationID: op, stage: "move_to_main_apply_frame_retry")
                if !retrySucceeded {
                    log(
                        "moveWindowToMainScreen failed: all attempts exhausted",
                        level: .error,
                        fields: [
                            "op": op,
                            "targetFrame": String(describing: targetFrame)
                        ]
                    )
                    return false
                }
            }
        }

        // 使用实际应用的 frame（可能因 macOS 菜单栏调整而与理想 targetFrame 不同）
        let actualTargetFrame = frame(of: windowAX) ?? targetFrame

        log(
            "[moveWindowToMainScreen] move succeeded, capturing state for persistence",
            level: .debug,
            fields: [
                "op": op,
                "actualTargetFrame": String(describing: actualTargetFrame),
                "requestedTargetFrame": String(describing: targetFrame)
            ]
        )

        let resolvedWindowNumber = windowNumber(for: windowAX) ?? identity.windowNumber
        let resolvedTitle = title(of: windowAX) ?? identity.title
        log(
            "[WindowManager] moveWindowToMainScreen captured state",
            fields: [
                "op": op,
                "sourceSpace": String(describing: spaceContext.sourceSpaceIndex),
                "targetSpace": String(describing: spaceContext.targetSpaceIndex),
                "sourceYabaiDisplay": String(describing: spaceContext.sourceDisplayIndex),
                "sourceDisplaySpace": String(describing: spaceContext.sourceDisplaySpaceIndex),
                "sourceDisplayID": String(describing: sourceContext.displayID),
                "sourceDisplayIndex": String(describing: sourceContext.index),
                "targetDisplayIndex": String(describing: targetDisplayIndex),
                "targetFrame": String(describing: targetFrame),
                "actualTargetFrame": String(describing: actualTargetFrame)
            ]
        )
        let savedState = SavedWindowState(
            id: UUID().uuidString,
            pid: identity.pid,
            bundleIdentifier: identity.bundleIdentifier,
            appName: identity.appName,
            windowID: currentWindowID,
            windowNumber: resolvedWindowNumber,
            title: resolvedTitle,
            originalFrame: RectPayload(currentFrame),
            targetFrame: RectPayload(actualTargetFrame),
            sourceSpaceIndex: spaceContext.sourceSpaceIndex,
            targetSpaceIndex: spaceContext.targetSpaceIndex,
            sourceYabaiDisplayIndex: spaceContext.sourceDisplayIndex,
            sourceDisplaySpaceIndex: spaceContext.sourceDisplaySpaceIndex,
            sourceDisplayIndex: sourceContext.index,
            sourceDisplayID: sourceContext.displayID,
            targetDisplayIndex: targetDisplayIndex,
            restoreReason: reason.rawValue,
            sessionID: sessionID,
            savedAt: Date()
        )

        let persistedState = saveWindowState(savedState, window: windowAX)
        log(
            "[moveWindowToMainScreen] saved window state",
            level: .debug,
            fields: [
                "op": op,
                "stateID": persistedState.id
            ]
        )
        hydrateMemory(from: persistedState, window: windowAX)
        log(
            "[moveWindowToMainScreen] hydrated memory from persisted state",
            level: .debug,
            fields: [
                "op": op,
                "stateID": persistedState.id
            ]
        )
        log(
            "[WindowManager] moveWindowToMainScreen finished",
            fields: [
                "op": op,
                "savedStateID": persistedState.id,
                "windowID": String(currentWindowID),
                "durationMs": String(elapsedMilliseconds(since: startedAt))
            ]
        )
        return true
    }

    /// 通过 CGWindowList 验证窗口是否已移动到目标 frame
    /// CGWindowList 使用 WindowServer 的数据，不依赖 AX，对跨 space 窗口更可靠
    private func verifyWindowFrameViaCGWindowList(
        windowID: UInt32,
        targetFrame: CGRect,
        operationID: String
    ) -> Bool {
        let options = CGWindowListOption(arrayLiteral: .optionAll)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        for info in windowList {
            guard let id = info[kCGWindowNumber as String] as? UInt32,
                  id == windowID else { continue }

            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else {
                return false
            }

            let actualFrame = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )

            let positionMatches = abs(actualFrame.origin.x - targetFrame.origin.x) <= frameTolerance &&
                                 abs(actualFrame.origin.y - targetFrame.origin.y) <= frameTolerance
            let sizeClose = abs(actualFrame.width - targetFrame.width) <= frameTolerance * 2 &&
                           abs(actualFrame.height - targetFrame.height) <= 100

            log(
                "[WindowManager] CGWindowList frame verification",
                fields: [
                    "op": operationID,
                    "windowID": String(windowID),
                    "actualFrame": String(describing: actualFrame),
                    "targetFrame": String(describing: targetFrame),
                    "positionMatches": String(positionMatches),
                    "sizeClose": String(sizeClose)
                ]
            )

            return positionMatches && sizeClose
        }

        log(
            "[WindowManager] CGWindowList verification: window not found in list",
            level: .warn,
            fields: [
                "op": operationID,
                "windowID": String(windowID)
            ]
        )
        return false
    }

    private func allWindows(for pid: pid_t) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard status == .success, let windowsRef else {
            log(
                "[WindowManager] allWindows: AX query failed",
                level: .debug,
                fields: ["pid": String(pid), "axStatus": String(status.rawValue)]
            )
            return []
        }
        let windows = windowsRef as? [AXUIElement] ?? []
        log(
            "[WindowManager] allWindows result",
            level: .debug,
            fields: ["pid": String(pid), "count": String(windows.count)]
        )
        return windows
    }

    private func displayID(for screen: NSScreen) -> UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else {
            return nil
        }
        return number.uint32Value
    }

    private func displayIndex(forDisplayID displayID: UInt32?) -> Int? {
        guard let displayID else {
            return nil
        }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.enumerated().first(where: { _, screen in
            guard let number = screen.deviceDescription[key] as? NSNumber else {
                return false
            }
            return number.uint32Value == displayID
        })?.offset
    }

    private func displayContext(for frame: CGRect) -> (index: Int?, displayID: UInt32?) {
        log(
            "[WindowManager] displayContext called",
            level: .debug,
            fields: [
                "frame": String(describing: frame),
                "centerX": "\(frame.midX)",
                "centerY": "\(frame.midY)",
                "screenCount": String(NSScreen.screens.count)
            ]
        )
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        for (index, screen) in NSScreen.screens.enumerated() {
            let displayFrame = screen.frame
            if displayFrame.contains(center) || displayFrame.intersects(frame) {
                let displayID = (screen.deviceDescription[key] as? NSNumber)?.uint32Value
                log(
                    "[WindowManager] displayContext matched screen",
                    level: .debug,
                    fields: [
                        "index": String(index),
                        "displayID": String(describing: displayID)
                    ]
                )
                return (index, displayID)
            }
        }
        log(
            "[WindowManager] displayContext: no screen matched frame",
            level: .debug
        )
        return (nil, nil)
    }

    func moveToMainScreenViaSystemEvents() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            log("No frontmost app for System Events fallback")
            return
        }

        guard let snapshot = systemEventsSnapshot(forPID: frontApp.processIdentifier) else {
            log("System Events fallback could not read front window")
            notifyAccessibilityPermissionRequired()
            return
        }

        guard let mainScreen = getMainScreen() else {
            log("Cannot get main screen for System Events fallback")
            return
        }

        let targetFrame = axFrame(forVisibleFrameOf: mainScreen)
        let bundleIdentifier = frontApp.bundleIdentifier
        let appName = frontApp.localizedName ?? snapshot.appName
        let savedState = SavedWindowState(
            id: UUID().uuidString,
            pid: frontApp.processIdentifier,
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            windowID: snapshot.windowID,
            windowNumber: nil,
            title: snapshot.title,
            originalFrame: RectPayload(snapshot.frame),
            targetFrame: RectPayload(targetFrame),
            sourceSpaceIndex: nil,
            targetSpaceIndex: nil,
            sourceYabaiDisplayIndex: nil,
            sourceDisplaySpaceIndex: nil,
            sourceDisplayIndex: nil,
            sourceDisplayID: nil,
            targetDisplayIndex: nil,
            restoreReason: WindowMoveReason.manualHotkey.rawValue,
            sessionID: nil,
            savedAt: Date()
        )

        log("System Events snapshot frame: \(snapshot.frame)")
        log("System Events target frame: \(targetFrame)")

        guard systemEventsApply(frame: targetFrame, toPID: frontApp.processIdentifier) else {
            log("System Events fallback failed to move window")
            return
        }

        let persistedState = saveWindowState(savedState)
        hydrateMemory(from: persistedState, window: nil)
        log("✅ MOVED WITH SYSTEM EVENTS FALLBACK")
    }

    func restoreViaSystemEvents() {
        log(
            "[restoreViaSystemEvents] called",
            level: .debug,
            fields: [
                "hasToken": String(lastWindowToken != nil),
                "hasFrame": String(lastWindowFrame != nil),
                "hasTarget": String(lastTargetFrame != nil)
            ]
        )
        if lastWindowToken == nil || lastWindowFrame == nil || lastTargetFrame == nil {
            log(
                "[restoreViaSystemEvents] some state nil, calling shouldRestoreCurrentWindowViaSystemEvents",
                level: .debug
            )
            if shouldRestoreCurrentWindowViaSystemEvents() == false {
                log("No saved window to restore via System Events")
                return
            }
            log(
                "[restoreViaSystemEvents] shouldRestoreCurrentWindowViaSystemEvents succeeded",
                level: .debug
            )
        }

        guard let token = lastWindowToken,
              let frame = lastWindowFrame,
              let frontApp = NSWorkspace.shared.frontmostApplication,
              let snapshot = systemEventsSnapshot(forPID: frontApp.processIdentifier),
              snapshot.windowID == token.windowID else {
            log(
                "[restoreViaSystemEvents] guard failed: missing token/frame/app/snapshot",
                level: .warn,
                fields: [
                    "hasToken": String(lastWindowToken != nil),
                    "hasFrame": String(lastWindowFrame != nil),
                    "hasFrontApp": String(NSWorkspace.shared.frontmostApplication != nil)
                ]
            )
            log("No active window state to restore via System Events")
            return
        }

        log(
            "[restoreViaSystemEvents] matched window, applying frame",
            level: .debug,
            fields: [
                "windowID": String(describing: token.windowID),
                "frame": String(describing: frame)
            ]
        )
        log("Restoring with System Events using window handle match")
        guard systemEventsApply(frame: frame, toPID: frontApp.processIdentifier) else {
            log(
                "[restoreViaSystemEvents] systemEventsApply failed",
                level: .error
            )
            log("System Events fallback failed to restore window")
            return
        }

        log(
            "[restoreViaSystemEvents] systemEventsApply succeeded, resetting context",
            level: .debug
        )
        resetActiveWindowContext(removeState: true)
        log("✅ RESTORED WITH SYSTEM EVENTS FALLBACK")
    }

    func shouldRestoreCurrentWindowViaSystemEvents() -> Bool {
        guard !savedWindowStates.isEmpty,
              let frontApp = NSWorkspace.shared.frontmostApplication,
              let snapshot = systemEventsSnapshot(forPID: frontApp.processIdentifier) else {
            return false
        }

        // 第一级匹配：通过 windowID
        if let currentWindowID = snapshot.windowID,
           let matchedState = savedWindowStates.reversed().first(where: { $0.windowID == currentWindowID }) {
            if isSavedStateCorrupted(matchedState) {
                log(
                    "System Events match found but state is corrupted, clearing",
                    level: .warn,
                    fields: ["stateID": matchedState.id, "windowID": String(describing: currentWindowID)]
                )
                clearSavedWindowState(id: matchedState.id)
            } else {
                hydrateMemory(from: matchedState, window: nil)
                log("Detected moved window state via System Events handle: \(currentWindowID)")
                return true
            }
        }

        // 第二级匹配：通过 PID + 窗口标题 + 大致位置
        let positionTolerance: CGFloat = 50.0
        if let matchedState = savedWindowStates.reversed().first(where: { state in
            guard state.pid == frontApp.processIdentifier else { return false }
            let stateTitle = state.title ?? ""
            let currentTitle = snapshot.title ?? ""
            guard stateTitle == currentTitle else { return false }

            // 检查当前位置是否接近保存的 targetFrame
            let targetFrame = state.targetFrame.cgRect
            let xDiff = abs(snapshot.x - targetFrame.origin.x)
            let yDiff = abs(snapshot.y - targetFrame.origin.y)
            return xDiff <= positionTolerance && yDiff <= positionTolerance
        }) {
            if isSavedStateCorrupted(matchedState) {
                log(
                    "System Events fallback match found but state is corrupted, clearing",
                    level: .warn,
                    fields: ["stateID": matchedState.id]
                )
                clearSavedWindowState(id: matchedState.id)
            } else {
                hydrateMemory(from: matchedState, window: nil)
                log("Detected moved window state via System Events fallback matching (PID+title+position)")
                return true
            }
        }

        return false
    }

    func systemEventsSnapshot(forPID pid: pid_t) -> ScriptWindowSnapshot? {
        // 先尝试通过 CGWindow 获取 windowID
        let windowID = systemEventsGetWindowID(forPID: pid)

        let script = """
        const se = Application('System Events');
        const pid = \(pid);
        const proc = se.applicationProcesses.whose({ unixId: pid })[0];
        if (!proc) throw new Error('NO_PROCESS');
        const win = proc.windows[0];
        if (!win) throw new Error('NO_WINDOW');
        JSON.stringify({
          windowID: null,
          appName: proc.name(),
          title: (() => { try { return win.name(); } catch (_) { return ""; } })(),
          x: win.position()[0],
          y: win.position()[1],
          width: win.size()[0],
          height: win.size()[1]
        });
        """

        guard let output = runJXAScript(script),
              let data = output.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(ScriptWindowSnapshot.self, from: data) else {
            return nil
        }

        // 将从 CGWindow 获取的 windowID 注入结果
        return ScriptWindowSnapshot(
            windowID: windowID,
            appName: snapshot.appName,
            title: snapshot.title,
            x: snapshot.x,
            y: snapshot.y,
            width: snapshot.width,
            height: snapshot.height
        )
    }

    /// 通过 CGWindowList 获取窗口 ID（备用方案）
    private func systemEventsGetWindowID(forPID pid: pid_t) -> UInt32? {
        // 获取该 PID 的所有窗口
        let options = CGWindowListOption(arrayLiteral: .optionAll)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // 找到属于该 PID 且是可见的普通窗口
        for windowInfo in windowList {
            if let windowPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
               windowPID == pid,
               let windowID = windowInfo[kCGWindowNumber as String] as? UInt32 {
                // 过滤掉系统 UI 元素（如菜单栏、Dock）
                let layer = windowInfo[kCGWindowLayer as String] as? Int ?? 0
                if layer == 0 {
                    return windowID
                }
            }
        }
        return nil
    }

    func systemEventsApply(frame targetFrame: CGRect, toPID pid: pid_t) -> Bool {
        let script = """
        const se = Application('System Events');
        const pid = \(pid);
        const proc = se.applicationProcesses.whose({ unixId: pid })[0];
        if (!proc) throw new Error('NO_PROCESS');
        const win = proc.windows[0];
        if (!win) throw new Error('NO_WINDOW');
        win.position = [\(Int(targetFrame.origin.x.rounded())), \(Int(targetFrame.origin.y.rounded()))];
        win.size = [\(Int(targetFrame.width.rounded())), \(Int(targetFrame.height.rounded()))];
        JSON.stringify({
          appName: proc.name(),
          title: (() => { try { return win.name(); } catch (_) { return ""; } })(),
          x: win.position()[0],
          y: win.position()[1],
          width: win.size()[0],
          height: win.size()[1]
        });
        """

        guard let output = runJXAScript(script),
              let data = output.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(ScriptWindowSnapshot.self, from: data) else {
            return false
        }

        return framesMatch(snapshot.frame, targetFrame)
    }

    func windowHandle(for window: AXUIElement) -> UInt32? {
        var windowID: CGWindowID = 0
        let status = _AXUIElementGetWindow(window, &windowID)
        guard status == .success, windowID != 0 else {
            log(
                "[WindowManager] windowHandle: _AXUIElementGetWindow failed",
                level: .debug,
                fields: ["axStatus": String(status.rawValue)]
            )
            return nil
        }
        return windowID
    }

    /// 验证 AXUIElement 是否仍然有效（底层窗口未被销毁）
    func isValidAXElement(_ element: AXUIElement) -> Bool {
        var windowID: CGWindowID = 0
        let status = _AXUIElementGetWindow(element, &windowID)
        guard status == .success, windowID != 0 else {
            log(
                "[WindowManager] isValidAXElement: _AXUIElementGetWindow failed",
                level: .debug,
                fields: ["axStatus": String(status.rawValue)]
            )
            return false
        }
        let valid = validateWindowExists(windowID: windowID)
        log(
            "[WindowManager] isValidAXElement result",
            level: .debug,
            fields: ["windowID": String(windowID), "valid": String(valid)]
        )
        return valid
    }

    struct CGWindowSnapshot {
        let windowID: UInt32
        let title: String?
        let frame: CGRect
        let ownerPID: pid_t
        let layer: Int
    }


    func runJXAScript(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript"]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            log("Failed to launch osascript: \(error.localizedDescription)")
            return nil
        }

        if let data = script.data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(data)
        }
        try? inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let errorText = String(data: errorData, encoding: .utf8) ?? "unknown error"
            log("osascript failed (exit \(process.terminationStatus), scriptLength=\(script.count)): \(errorText.trimmingCharacters(in: .whitespacesAndNewlines))")
            return nil
        }

        return String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func windowNumber(for window: AXUIElement) -> Int? {
        var numberRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(window, axWindowNumberAttribute as CFString, &numberRef)
        guard status == .success, let number = numberRef as? NSNumber else {
            return nil
        }
        return number.intValue
    }

    func title(of window: AXUIElement) -> String? {
        var titleRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        guard status == .success else {
            return nil
        }
        return titleRef as? String
    }

    func frame(of window: AXUIElement) -> CGRect? {
        var frameRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(window, axFrameAttribute as CFString, &frameRef)
        guard status == .success, let frameRef else {
            log(
                "[WindowManager] frame: AX read failed",
                level: .debug,
                fields: ["axStatus": String(status.rawValue)]
            )
            return nil
        }

        let axValue = frameRef as! AXValue
        var frame = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &frame) else {
            log(
                "[WindowManager] frame: AXValueGetValue failed",
                level: .debug
            )
            return nil
        }
        return frame
    }

    func isAttributeSettable(_ element: AXUIElement, attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        if status != .success {
            log("Settable check failed for \(attribute): \(status.rawValue)")
            return false
        }
        return settable.boolValue
    }

    func apply(
        frame targetFrame: CGRect,
        to window: AXUIElement,
        operationID: String? = nil,
        stage: String = "apply_frame"
    ) -> Bool {
        let op = operationID ?? "none"
        let startedAt = Date()
        var lastAppliedFrame: CGRect?
        let maxAttempts = 3
        let settleDelayMicros: useconds_t = 25_000

        log(
            "[apply] starting frame application",
            level: .debug,
            fields: [
                "op": op,
                "stage": stage,
                "targetFrame": String(describing: targetFrame),
                "maxAttempts": String(maxAttempts)
            ]
        )

        for attempt in 1...maxAttempts {
            log(
                "[apply] attempt started",
                level: .debug,
                fields: [
                    "op": op,
                    "stage": stage,
                    "attempt": String(attempt)
                ]
            )
            var targetSize = CGSize(width: targetFrame.width, height: targetFrame.height)
            guard let sizeValue = AXValueCreate(.cgSize, &targetSize) else {
                log(
                    "[apply] AXValueCreate for size returned nil",
                    level: .error,
                    fields: [
                        "op": op,
                        "stage": stage,
                        "attempt": String(attempt),
                        "targetWidth": "\(targetFrame.width)",
                        "targetHeight": "\(targetFrame.height)"
                    ]
                )
                return false
            }

            let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            log(
                "[WindowManager] set size result",
                fields: [
                    "op": op,
                    "stage": stage,
                    "attempt": String(attempt),
                    "status": String(sizeResult.rawValue)
                ]
            )
            guard sizeResult == .success else {
                log(
                    "[apply] AXUIElementSetAttributeValue for size failed",
                    level: .error,
                    fields: [
                        "op": op,
                        "stage": stage,
                        "attempt": String(attempt),
                        "sizeResult": String(sizeResult.rawValue)
                    ]
                )
                return false
            }

            log(
                "[apply] size set OK, setting position",
                level: .debug,
                fields: [
                    "op": op,
                    "stage": stage,
                    "attempt": String(attempt)
                ]
            )

            var targetOrigin = CGPoint(x: targetFrame.origin.x, y: targetFrame.origin.y)
            guard let originValue = AXValueCreate(.cgPoint, &targetOrigin) else {
                log(
                    "[apply] AXValueCreate for position returned nil",
                    level: .error,
                    fields: [
                        "op": op,
                        "stage": stage,
                        "attempt": String(attempt),
                        "targetX": "\(targetFrame.origin.x)",
                        "targetY": "\(targetFrame.origin.y)"
                    ]
                )
                return false
            }

            let positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue)
            log(
                "[WindowManager] set position result",
                fields: [
                    "op": op,
                    "stage": stage,
                    "attempt": String(attempt),
                    "status": String(positionResult.rawValue)
                ]
            )
            guard positionResult == .success else {
                log(
                    "[apply] AXUIElementSetAttributeValue for position failed",
                    level: .error,
                    fields: [
                        "op": op,
                        "stage": stage,
                        "attempt": String(attempt),
                        "positionResult": String(positionResult.rawValue)
                    ]
                )
                return false
            }

            log(
                "[apply] position set OK, waiting settle delay",
                level: .debug,
                fields: [
                    "op": op,
                    "stage": stage,
                    "attempt": String(attempt),
                    "settleDelayMs": String(settleDelayMicros / 1000)
                ]
            )

            usleep(settleDelayMicros)

            log(
                "[apply] reading back frame after settle",
                level: .debug,
                fields: ["op": op, "stage": stage, "attempt": String(attempt)]
            )
            if let appliedFrame = frame(of: window) {
                log(
                    "[WindowManager] applied frame snapshot",
                    fields: [
                        "op": op,
                        "stage": stage,
                        "attempt": String(attempt),
                        "frame": String(describing: appliedFrame)
                    ]
                )
                lastAppliedFrame = appliedFrame
                if framesMatch(appliedFrame, targetFrame) {
                    log(
                        "[apply] frame matched on attempt, returning true",
                        level: .debug,
                        fields: [
                            "op": op,
                            "stage": stage,
                            "attempt": String(attempt)
                        ]
                    )
                    return true
                }
                log(
                    "[apply] frame did not match on attempt, checking tolerance",
                    level: .debug,
                    fields: [
                        "op": op,
                        "stage": stage,
                        "attempt": String(attempt),
                        "appliedFrame": String(describing: appliedFrame),
                        "targetFrame": String(describing: targetFrame)
                    ]
                )
            } else {
                log(
                    "[apply] could not read back frame on attempt",
                    level: .warn,
                    fields: [
                        "op": op,
                        "stage": stage,
                        "attempt": String(attempt)
                    ]
                )
            }
        }

        log(
            "[apply] all attempts exhausted, checking tolerance as final fallback",
            level: .debug,
            fields: [
                "op": op,
                "stage": stage,
                "hasLastAppliedFrame": String(lastAppliedFrame != nil)
            ]
        )

        // 如果精确匹配失败，但窗口已成功应用了接近的尺寸（可能是窗口有最小尺寸限制）
        // 我们也认为是成功的
        if let lastFrame = lastAppliedFrame {
            // 检查是否在合理范围内（位置正确，大小接近）
            let positionMatches = abs(lastFrame.origin.x - targetFrame.origin.x) <= frameTolerance &&
                                 abs(lastFrame.origin.y - targetFrame.origin.y) <= frameTolerance
            let sizeCloseEnough = abs(lastFrame.width - targetFrame.width) <= frameTolerance * 2 &&
                                 abs(lastFrame.height - targetFrame.height) <= 100 // 允许高度有较大偏差（最小尺寸限制）

            if positionMatches && sizeCloseEnough {
                log(
                    "[WindowManager] apply frame within tolerance",
                    level: .warn,
                    fields: [
                        "op": op,
                        "stage": stage,
                        "frame": String(describing: lastFrame),
                        "target": String(describing: targetFrame),
                        "durationMs": String(elapsedMilliseconds(since: startedAt))
                    ]
                )
                return true
            }
        }

        log(
            "[WindowManager] apply frame failed",
            level: .error,
            fields: [
                "op": op,
                "stage": stage,
                "target": String(describing: targetFrame),
                "lastFrame": String(describing: lastAppliedFrame),
                "durationMs": String(elapsedMilliseconds(since: startedAt))
            ]
        )
        return false
    }

    func axFrame(forVisibleFrameOf screen: NSScreen) -> CGRect {
        let visibleFrame = screen.visibleFrame
        // 使用当前屏幕的 frame.maxY 进行坐标转换
        let screenMaxY = screen.frame.maxY
        return CGRect(
            x: visibleFrame.origin.x,
            y: screenMaxY - visibleFrame.maxY,
            width: visibleFrame.width,
            height: visibleFrame.height
        )
    }

    func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= frameTolerance &&
        abs(lhs.origin.y - rhs.origin.y) <= frameTolerance &&
        abs(lhs.width - rhs.width) <= frameTolerance &&
        abs(lhs.height - rhs.height) <= frameTolerance
    }

    @discardableResult
    func saveWindowState(_ state: SavedWindowState, window: AXUIElement? = nil) -> SavedWindowState {
        // 先清理过期 state
        let maxAge: TimeInterval = 24 * 60 * 60
        let now = Date()
        let expiredBefore = savedWindowStates.count
        savedWindowStates.removeAll { existing in
            now.timeIntervalSince(existing.savedAt) > maxAge
        }
        let expiredRemoved = expiredBefore - savedWindowStates.count

        savedWindowStates.removeAll { existing in
            shouldReplaceSavedState(existing, with: state, currentWindow: window)
        }
        savedWindowStates.append(state)
        savedWindowStates.sort { $0.savedAt < $1.savedAt }

        if let window {
            windowElementsByStateID[state.id] = window
        }

        persistSavedWindowStates()
        log(
            "Persisted window states to UserDefaults: \(savedWindowStates.count)",
            fields: expiredRemoved > 0 ? ["expiredEvicted": String(expiredRemoved)] : [:]
        )
        return state
    }

    func loadSavedWindowStates() -> [SavedWindowState] {
        guard let data = UserDefaults.standard.data(forKey: savedStatesKey),
              let states = try? JSONDecoder().decode([SavedWindowState].self, from: data) else {
            return []
        }
        return states.filter { $0.windowID != nil }
    }

    func persistSavedWindowStates() {
        guard let data = try? JSONEncoder().encode(savedWindowStates) else {
            log("Failed to encode saved window states")
            return
        }
        UserDefaults.standard.set(data, forKey: savedStatesKey)
    }

    func clearSavedWindowState(id: String?) {
        guard let id else { return }
        savedWindowStates.removeAll { $0.id == id }
        windowElementsByStateID.removeValue(forKey: id)
        persistSavedWindowStates()
        log("Cleared persisted window state: \(id)")
    }

    func resetActiveWindowContext(removeState: Bool) {
        let activeStateID = lastWindowToken?.stateID
        lastWindowElement = nil
        lastWindowToken = nil
        lastWindowFrame = nil
        lastTargetFrame = nil
        lastSourceSpaceIndex = nil
        lastTargetSpaceIndex = nil
        lastSourceYabaiDisplayIndex = nil
        lastSourceDisplaySpaceIndex = nil
        if removeState {
            clearSavedWindowState(id: activeStateID)
        }
    }

    func hydrateMemory(from state: SavedWindowState, window: AXUIElement?) {
        let cachedElement = windowElementsByStateID[state.id]
        let resolvedWindow = window ?? cachedElement

        // 验证缓存的 AX 元素是否仍然有效
        var effectiveWindow: AXUIElement? = resolvedWindow
        if let resolvedWindow {
            if !isValidAXElement(resolvedWindow) {
                log(
                    "hydrateMemory: cached AX element is stale, clearing",
                    level: .warn,
                    fields: [
                        "stateID": state.id,
                        "expectedWindowID": String(describing: state.windowID)
                    ]
                )
                windowElementsByStateID.removeValue(forKey: state.id)
                effectiveWindow = nil
            }
        }

        // 如果没有有效 AX 元素，尝试按 PID + windowID 主动查找
        if effectiveWindow == nil, let windowID = state.windowID {
            effectiveWindow = findWindowByPID(state.pid, windowID: windowID)
            if let found = effectiveWindow {
                log(
                    "hydrateMemory: re-resolved window by PID enumeration",
                    fields: [
                        "stateID": state.id,
                        "windowID": String(windowID)
                    ]
                )
                windowElementsByStateID[state.id] = found
            }
        }

        lastWindowElement = effectiveWindow
        lastWindowToken = WindowToken(
            stateID: state.id,
            pid: state.pid,
            bundleIdentifier: state.bundleIdentifier,
            appName: state.appName,
            windowID: state.windowID,
            windowNumber: state.windowNumber,
            title: state.title
        )
        lastWindowFrame = state.originalFrame.cgRect
        lastTargetFrame = state.targetFrame.cgRect
        lastSourceSpaceIndex = state.sourceSpaceIndex
        lastTargetSpaceIndex = state.targetSpaceIndex
        lastSourceYabaiDisplayIndex = state.sourceYabaiDisplayIndex
        lastSourceDisplaySpaceIndex = state.sourceDisplaySpaceIndex
    }

    func shouldReplaceSavedState(
        _ existing: SavedWindowState,
        with incoming: SavedWindowState,
        currentWindow: AXUIElement?
    ) -> Bool {
        if existing.id == incoming.id {
            return true
        }

        if let currentWindow,
           let cachedWindow = windowElementsByStateID[existing.id],
           CFEqual(cachedWindow, currentWindow) {
            return true
        }

        guard let existingID = existing.windowID,
              let incomingID = incoming.windowID else {
            return false
        }

        return existingID == incomingID
    }

}
