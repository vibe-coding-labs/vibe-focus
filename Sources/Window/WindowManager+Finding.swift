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
            title: title(of: windowAX)
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
        let windows = cgWindowListAll()

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
            let isOnMainScreen = isWindowOnMainScreen(windowID: entry.windowID)

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
                        "projectName": projectName
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
            title: candidate.title
        )
    }

    /// 通过 CGWindowID 查找窗口 — 遍历 CGWindowList 按 PID+bounds 匹配到 AXUIElement
    func findWindowByCGWindowID(_ targetWindowID: UInt32) -> WindowIdentity? {
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
    }
}
