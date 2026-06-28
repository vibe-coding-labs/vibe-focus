import SwiftUI
import AppKit
import ApplicationServices.HIServices
import Foundation

// MARK: - Window Finding
// 窗口查找：捕获聚焦窗口、查找 Claude Code 窗口
@MainActor
extension WindowManager {

    struct WindowCandidate {
        let windowID: UInt32
        let pid: pid_t
        let appName: String
        let bundleIdentifier: String?
        let title: String
        let isOnMainScreen: Bool
    }

    /// Pure strategy logic for findClaudeCodeWindow — extracted for testability.
    /// Returns the index of the best matching candidate, or nil if no match.
    static func findBestCandidate(
        candidates: [WindowCandidate],
        cwd: String?,
        isHostApp: (WindowCandidate) -> Bool
    ) -> WindowCandidate? {
        let projectName = cwd?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .components(separatedBy: "/")
            .last?
            .lowercased()

        // Strategy 1: Host app + cwd project name in title
        if let projectName, !projectName.isEmpty {
            if let match = candidates.first(where: { c in
                return isHostApp(c) && c.title.lowercased().contains(projectName)
            }) {
                return match
            }
        }

        // Strategy 2: Host app + "Claude Code" in title
        if let match = candidates.first(where: { c in
            return isHostApp(c) && c.title.lowercased().contains("claude code")
        }) {
            return match
        }

        return nil
    }

    func captureFocusedWindowIdentity() -> WindowIdentity? {
        // P-INST-25: captureFocusedWindowIdentity 耗时（4 个 AX 调用 focusedWindow+windowHandle+windowNumber+title，副屏可能阻塞；hook 路径）。
        let cfStart = Date()
        log(
            "[WindowManager] captureFocusedWindowIdentity called",
            level: .debug
        )
        // windowID 必须用 AX windowHandle —— resolveWindow(identity:) 后续用 AX focusedWindow +
        // windowHandle 匹配，windowID 必须同源。CGWindowList 无法可靠识别多窗口 app 的 focused
        // 窗口（iTerm2 first match 181 ≠ AX focused 170），误拿会导致 resolveWindow 找不到窗口。
        // 因此这里保留 AX（focusedWindow + windowHandle），不能换 CGWindowList。
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
            title: title(of: windowAX)
        )
        log(
            "[WindowManager] captureFocusedWindowIdentity result",
            level: .debug,
            fields: [
                "windowID": String(identity.windowID),
                "pid": String(identity.pid),
                "bundleID": identity.bundleIdentifier ?? "nil",
                "title": truncateForLog(identity.title ?? "", limit: 60),
                "durationMs": String(elapsedMilliseconds(since: cfStart))
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
        // P-INST-26: findClaudeCodeWindow 耗时（cgWindowListAll 全扫 + 候选构建 + 策略匹配；hook 路径）。
        let fcStart = Date()
        log(
            "[WindowManager] findClaudeCodeWindow called",
            level: .debug,
            fields: ["cwd": cwd ?? "nil"]
        )
        let cgListStart = Date()
        let windows = cgWindowListAll()
        let cgListMs = elapsedMilliseconds(since: cgListStart)

        // 从 cwd 中提取项目名（最后一段路径）
        let projectName = cwd?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .components(separatedBy: "/")
            .last?
            .lowercased()

        // Claude Code 常用的终端/IDE — 通过 TerminalRegistry 统一判断
        let isHostApp = { (c: WindowCandidate) in
            TerminalRegistry.isTerminalOrIDEApp(appName: c.appName, bundleIdentifier: c.bundleIdentifier)
        }

        // 构建候选窗口列表
        var candidates: [WindowCandidate] = []
        for entry in windows {
            guard entry.layer == 0 else { continue }

            let appName = entry.ownerName ?? ""
            let title = entry.name ?? ""
            // 复用已查询的 entry.bounds，避免循环内对每个窗口再调 isWindowOnMainScreen →
            // cgWindowListAll() 全量重扫（N 窗口 × 每次全量扫 = O(N²)）。
            let isOnMainScreen = entry.bounds.map { CoordinateKit.isOnMainScreen($0) } ?? false

            let bundleIdentifier: String?
            if let app = NSRunningApplication(processIdentifier: entry.ownerPID) {
                bundleIdentifier = app.bundleIdentifier
            } else {
                bundleIdentifier = nil
            }

            candidates.append(WindowCandidate(
                windowID: entry.windowID,
                pid: entry.ownerPID,
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                title: title,
                isOnMainScreen: isOnMainScreen
            ))
        }

        // 策略 1：Claude Host App 窗口中标题包含 cwd 项目名
        if let projectName, !projectName.isEmpty {
            let match = candidates.first(where: { c in
                return isHostApp(c) && c.title.lowercased().contains(projectName)
            })
            if let match {
                log(
                    "[WindowManager] findClaudeCodeWindow matched strategy 1: hostApp+cwd",
                    fields: [
                        "app": match.appName,
                        "title": truncateForLog(match.title, limit: 80),
                        "windowID": String(match.windowID),
                        "projectName": projectName,
                        "cgListMs": String(cgListMs),
                        "durationMs": String(elapsedMilliseconds(since: fcStart))
                    ]
                )
                return makeIdentity(from: match)
            }
        }

        // 策略 2：Claude Host App 窗口中标题包含 "Claude Code" 且在非主屏幕
        let claudeMatch = candidates.first(where: { c in
            return isHostApp(c) && c.title.lowercased().contains("claude code")
        })
        if let claudeMatch {
            log(
                "[WindowManager] findClaudeCodeWindow matched strategy 2: hostApp+claudeCode",
                fields: [
                    "app": claudeMatch.appName,
                    "title": truncateForLog(claudeMatch.title, limit: 80),
                    "windowID": String(claudeMatch.windowID),
                    "cgListMs": String(cgListMs),
                    "durationMs": String(elapsedMilliseconds(since: fcStart))
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
                "candidateCount": String(candidates.count),
                "cgListMs": String(cgListMs),
                "durationMs": String(elapsedMilliseconds(since: fcStart))
            ]
        )
        return captureFocusedWindowIdentity()
    }

    private func makeIdentity(from candidate: WindowCandidate) -> WindowIdentity {
        // P-INST-166: candidate→WindowIdentity 构造耗时（NSRunningApplication(processIdentifier:) LaunchServices 进程元数据查询取 bundleIdentifier；findClaudeCodeWindow P-INST-26 候选构造调用）。
        let miStart = Date()
        let identity = WindowIdentity(
            windowID: candidate.windowID,
            pid: candidate.pid,
            bundleIdentifier: candidate.bundleIdentifier
                ?? NSRunningApplication(processIdentifier: candidate.pid)?.bundleIdentifier,
            appName: candidate.appName,
            title: candidate.title
        )
        log("[WindowManager] makeIdentity finished", level: .debug, fields: [
            "pid": String(candidate.pid),
            "durationMs": String(elapsedMilliseconds(since: miStart))
        ])
        return identity
    }

    /// 通过 CGWindowID 查找窗口 — 遍历 CGWindowList 按 PID+bounds 匹配到 AXUIElement
    func findWindowByCGWindowID(_ targetWindowID: UInt32) -> WindowIdentity? {
        // P-INST-167: 按 CGWindowID 查窗口耗时（cgWindowListAll 全扫 P-INST-45 + first(where:) 匹配 + NSRunningApplication LaunchServices 查 bundleIdentifier；restore 路径按 windowID 定位调用）。
        let fcgStart = Date()
        let result: WindowIdentity? = {
            let windows = cgWindowListAll()
            guard let entry = windows.first(where: { $0.windowID == targetWindowID }) else {
                return nil
            }
            let bundleID: String? = NSRunningApplication(processIdentifier: entry.ownerPID)?.bundleIdentifier

            return WindowIdentity(
                windowID: targetWindowID,
                pid: entry.ownerPID,
                bundleIdentifier: bundleID,
                appName: entry.ownerName,
                windowNumber: Int(targetWindowID),
                title: entry.name
            )
        }()
        log("[WindowManager] findWindowByCGWindowID finished", level: .debug, fields: [
            "windowID": String(targetWindowID),
            "found": String(result != nil),
            "durationMs": String(elapsedMilliseconds(since: fcgStart))
        ])
        return result
    }
}
