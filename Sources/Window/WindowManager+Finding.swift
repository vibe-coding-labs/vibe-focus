import SwiftUI
import AppKit
import Carbon
import ApplicationServices.HIServices
import CoreFoundation
import Foundation

// MARK: - Window Finding
// 窗口查找：捕获聚焦窗口、查找 Claude Code 窗口
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
        for info in windowList {
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue } // 只看普通窗口

            guard let windowID = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else {
                continue
            }

            let appName = info[kCGWindowOwnerName as String] as? String ?? ""
            let title = info["kCGWindowName"] as? String ?? info["name"] as? String ?? ""
            let isOnMainScreen = isWindowOnMainScreen(windowID: windowID)

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
            windowNumber: nil,
            title: candidate.title,
            capturedAt: Date()
        )
    }

    /// 通过 CGWindowID 查找窗口 — 遍历 CGWindowList 按 PID+bounds 匹配到 AXUIElement
    func findWindowByCGWindowID(_ targetWindowID: UInt32) -> WindowIdentity? {
        let windowListOption = CGWindowListOption(arrayLiteral: .optionAll)
        guard let windowList = CGWindowListCopyWindowInfo(windowListOption, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for windowInfo in windowList {
            guard let cgID = windowInfo[kCGWindowNumber as String] as? UInt32, cgID == targetWindowID else {
                continue
            }
            guard let pid = windowInfo[kCGWindowOwnerPID as String] as? Int32 else { return nil }
            let appName = windowInfo[kCGWindowOwnerName as String] as? String
            let title = windowInfo["kCGWindowName"] as? String ?? windowInfo["name"] as? String
            let bundleID: String? = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier

            return WindowIdentity(
                windowID: targetWindowID,
                pid: pid,
                bundleIdentifier: bundleID,
                appName: appName,
                windowNumber: Int(targetWindowID),
                title: title,
                capturedAt: Date()
            )
        }
        return nil
    }
}
