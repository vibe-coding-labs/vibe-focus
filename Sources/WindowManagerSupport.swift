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
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        guard let windowAX = focusedWindow(for: frontApp.processIdentifier) else {
            return nil
        }
        guard let windowID = windowHandle(for: windowAX) else {
            return nil
        }
        return WindowIdentity(
            windowID: windowID,
            pid: frontApp.processIdentifier,
            bundleIdentifier: frontApp.bundleIdentifier,
            appName: frontApp.localizedName,
            windowNumber: windowNumber(for: windowAX),
            title: title(of: windowAX),
            capturedAt: Date()
        )
    }

    /// 在所有窗口中查找最可能是 Claude Code 会话对应的窗口
    /// 策略优先级：
    ///   0. 通过终端上下文（TTY/SESSION_ID）精确匹配（command-type hook 提供）
    ///   1. Terminal/Cursor 等 IDE 窗口中标题包含 cwd 项目名的窗口（在非主屏幕上）
    ///   2. 任意窗口中标题包含 cwd 项目名（在非主屏幕上）
    ///   3. 包含 "Claude Code" 关键词的窗口（在非主屏幕上）
    ///   4. 当前前台窗口
    func findClaudeCodeWindow(cwd: String?) -> WindowIdentity? {
        let options = CGWindowListOption(arrayLiteral: .optionAll)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
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

        // 策略 1：Claude Host App 窗口中标题包含 cwd 项目名且在非主屏幕
        if let projectName, !projectName.isEmpty {
            let match = candidates.first(where: { c in
                let isHostApp = (c.bundleIdentifier.map { claudeHostApps.contains($0) } ?? false)
                    || c.appName == "Terminal" || c.appName == "iTerm2" || c.appName == "Cursor"
                    || c.appName == "Warp" || c.appName == "Ghostty" || c.appName == "Alacritty"
                return isHostApp && !c.isOnMainScreen && c.title.lowercased().contains(projectName)
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

        // 策略 2：任意窗口标题包含 cwd 项目名且在非主屏幕
        if let projectName, !projectName.isEmpty {
            let match = candidates.first(where: { c in
                !c.isOnMainScreen && c.title.lowercased().contains(projectName)
            })
            if let match {
                log(
                    "[WindowManager] findClaudeCodeWindow matched strategy 2: anyApp+cwd",
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

        // 策略 3：包含 "Claude Code" 关键词的窗口（在非主屏幕上）
        let claudeMatch = candidates.first(where: { c in
            !c.isOnMainScreen && c.title.lowercased().contains("claude code")
        })
        if let claudeMatch {
            log(
                "[WindowManager] findClaudeCodeWindow matched strategy 3: claudeCode keyword",
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
        let output = runShellCommand("/bin/ps", args: ["-o", "tty=", "-p", String(pid)])
        let tty = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if tty.isEmpty || tty == "??" || tty == "?" {
            return nil
        }
        return tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
    }

    /// 通过 TTY 查找 Terminal.app / iTerm2 窗口
    /// 每个终端标签页有唯一的 TTY 设备，通过 JXA 查询匹配
    private func findWindowByTTY(_ tty: String) -> WindowIdentity? {
        let fullTTY = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"

        // 尝试 Terminal.app
        if let identity = findTerminalAppWindowByTTY(fullTTY) {
            return identity
        }

        // 尝试 iTerm2
        if let identity = findiTerm2WindowByTTY(fullTTY) {
            return identity
        }

        return nil
    }

    /// 通过 CGWindowList 检查指定窗口是否当前在主屏幕上
    /// 用于 hook 路径在执行窗口移动前的预检，避免对已在主屏的窗口执行无意义的移动
    func isWindowOnMainScreen(windowID: UInt32) -> Bool {
        let options = CGWindowListOption(arrayLiteral: .optionAll)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        guard let mainScreen = getMainScreen() else { return false }
        let mainScreenFrame = mainScreen.frame

        for info in windowList {
            guard let id = info[kCGWindowNumber as String] as? UInt32,
                  id == windowID else { continue }
            let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
            guard let bounds else { return false }
            let windowFrame = CGRect(
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0
            )
            let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
            return mainScreenFrame.contains(center)
        }
        return false
    }

    /// 通过 TTY 在 Terminal.app 中查找窗口
    private func findTerminalAppWindowByTTY(_ fullTTY: String) -> WindowIdentity? {
        let script = """
        const terminal = Application('Terminal');
        const windows = terminal.windows();
        for (let i = 0; i < windows.length; i++) {
            const w = windows[i];
            const tabs = w.tabs();
            for (let j = 0; j < tabs.length; j++) {
                try {
                    if (tabs[j].tty() === '\(fullTTY)') {
                        JSON.stringify({found: true, windowName: w.name()});
                    }
                } catch(e) {}
            }
        }
        JSON.stringify({found: false});
        """

        guard let output = runJXAScript(script) else { return nil }

        // 解析 JXA 结果
        struct TTYMatchResult: Decodable {
            let found: Bool
            let windowName: String?
        }

        guard let data = output.data(using: .utf8),
              let result = try? JSONDecoder().decode(TTYMatchResult.self, from: data),
              result.found,
              let windowName = result.windowName else {
            return nil
        }

        // 在 CGWindowList 中查找 Terminal.app 窗口，匹配窗口名称
        return findWindowInCGList(ownerName: "Terminal", windowTitle: windowName)
    }

    /// 通过 TTY 在 iTerm2 中查找窗口
    private func findiTerm2WindowByTTY(_ fullTTY: String) -> WindowIdentity? {
        let script = """
        const iterm = Application('iTerm');
        const windows = iterm.windows();
        for (let i = 0; i < windows.length; i++) {
            const w = windows[i];
            const tabs = w.tabs();
            for (let j = 0; j < tabs.length; j++) {
                const sessions = tabs[j].sessions();
                for (let k = 0; k < sessions.length; k++) {
                    try {
                        if (sessions[k].tty() === '\(fullTTY)') {
                            JSON.stringify({found: true, windowName: w.name()});
                        }
                    } catch(e) {}
                }
            }
        }
        JSON.stringify({found: false});
        """

        guard let output = runJXAScript(script) else { return nil }

        struct TTYMatchResult: Decodable {
            let found: Bool
            let windowName: String?
        }

        guard let data = output.data(using: .utf8),
              let result = try? JSONDecoder().decode(TTYMatchResult.self, from: data),
              result.found,
              let windowName = result.windowName else {
            return nil
        }

        return findWindowInCGList(ownerName: "iTerm2", windowTitle: windowName)
    }

    /// 在 CGWindowList 中按 owner + title 查找窗口
    private func findWindowInCGList(ownerName: String, windowTitle: String) -> WindowIdentity? {
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
        let pid = pid_t(identity.pid)
        if let focused = focusedWindow(for: pid),
           let focusedID = windowHandle(for: focused),
           focusedID == identity.windowID {
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

        // 检查窗口是否已在主屏幕上
        // 如果已经在目标位置，跳过移动，避免覆盖已有的 saved state（原来的副屏位置）
        if let mainScreen = getMainScreen() {
            let mainScreenFrame = mainScreen.frame
            let windowCenter = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
            if mainScreenFrame.contains(windowCenter) {
                log(
                    "[WindowManager] moveWindowToMainScreen skipped: already on main screen",
                    fields: [
                        "op": op,
                        "windowID": String(identity.windowID),
                        "reason": reason.rawValue
                    ]
                )
                return true
            }
        }

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

        guard apply(frame: targetFrame, to: windowAX, operationID: op, stage: "move_to_main_apply_frame"),
              let appliedFrame = frame(of: windowAX),
              framesMatch(appliedFrame, targetFrame) else {
            log(
                "moveWindowToMainScreen failed: frame verification mismatch",
                level: .error,
                fields: [
                    "op": op,
                    "targetFrame": String(describing: targetFrame)
                ]
            )
            return false
        }

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
                "targetDisplayIndex": String(describing: targetDisplayIndex)
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
            targetFrame: RectPayload(targetFrame),
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
        hydrateMemory(from: persistedState, window: windowAX)
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

    private func allWindows(for pid: pid_t) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard status == .success, let windowsRef else {
            return []
        }

        return windowsRef as? [AXUIElement] ?? []
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
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        for (index, screen) in NSScreen.screens.enumerated() {
            let displayFrame = screen.frame
            if displayFrame.contains(center) || displayFrame.intersects(frame) {
                let displayID = (screen.deviceDescription[key] as? NSNumber)?.uint32Value
                return (index, displayID)
            }
        }
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
        if lastWindowToken == nil || lastWindowFrame == nil || lastTargetFrame == nil {
            if shouldRestoreCurrentWindowViaSystemEvents() == false {
                log("No saved window to restore via System Events")
                return
            }
        }

        guard let token = lastWindowToken,
              let frame = lastWindowFrame,
              let frontApp = NSWorkspace.shared.frontmostApplication,
              let snapshot = systemEventsSnapshot(forPID: frontApp.processIdentifier),
              snapshot.windowID == token.windowID else {
            log("No active window state to restore via System Events")
            return
        }

        log("Restoring with System Events using window handle match")
        guard systemEventsApply(frame: frame, toPID: frontApp.processIdentifier) else {
            log("System Events fallback failed to restore window")
            return
        }

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
            log("Cannot get stable window handle from AXUIElement: \(status.rawValue)")
            return nil
        }
        return windowID
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
            return nil
        }

        let axValue = frameRef as! AXValue
        var frame = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &frame) else {
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

        for attempt in 1...maxAttempts {
            var targetSize = CGSize(width: targetFrame.width, height: targetFrame.height)
            guard let sizeValue = AXValueCreate(.cgSize, &targetSize) else {
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
                return false
            }

            var targetOrigin = CGPoint(x: targetFrame.origin.x, y: targetFrame.origin.y)
            guard let originValue = AXValueCreate(.cgPoint, &targetOrigin) else {
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
                return false
            }

            usleep(settleDelayMicros)

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
                        "[WindowManager] apply frame matched target",
                        fields: [
                            "op": op,
                            "stage": stage,
                            "attempt": String(attempt),
                            "durationMs": String(elapsedMilliseconds(since: startedAt))
                        ]
                    )
                    return true
                }
            }
        }

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
            let handle = windowHandle(for: resolvedWindow)
            if handle == nil && state.windowID != nil {
                // AX 元素已失效（返回 nil windowID），清除缓存
                log(
                    "hydrateMemory: cached AX element is stale, clearing",
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
