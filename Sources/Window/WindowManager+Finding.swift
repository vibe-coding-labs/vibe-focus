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
    }

    /// 窗口定位命中策略（日志归因用，2.16a 第十九刀随决策纯函数化引入）
    enum ClaudeCodeMatchStrategy {
        case hostAppProjectName    // 策略 1：hostApp + 标题含 cwd 项目名
        case hostAppClaudeCodeTitle // 策略 2：hostApp + 标题含 "claude code"
    }

    /// cwd → 项目名（末段路径，小写归一）。nil/空串/全斜杠路径 → nil。
    /// 纯函数（2.16a 第十九刀从 findClaudeCodeWindow 内联抽出）。
    static func projectName(fromCwd cwd: String?) -> String? {
        guard let cwd else { return nil }
        let trimmed = cwd.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let last = trimmed.components(separatedBy: "/").last, !last.isEmpty else { return nil }
        return last.lowercased()
    }

    /// Claude Code 窗口三级策略的候选匹配（纯函数，hostApp 判定由调用方注入）。
    /// 策略 1（projectName 非空才启用）优先于策略 2，均未中返回 nil（调用方回退前台窗口）。
    /// 标题匹配均为小写化 contains 子串语义。
    static func matchClaudeCodeCandidate(
        _ candidates: [WindowCandidate],
        projectName: String?,
        isHostApp: (WindowCandidate) -> Bool
    ) -> (candidate: WindowCandidate, strategy: ClaudeCodeMatchStrategy)? {
        if let projectName, !projectName.isEmpty,
           let match = candidates.first(where: { isHostApp($0) && $0.title.lowercased().contains(projectName) }) {
            return (match, .hostAppProjectName)
        }
        if let match = candidates.first(where: { isHostApp($0) && $0.title.lowercased().contains("claude code") }) {
            return (match, .hostAppClaudeCodeTitle)
        }
        return nil
    }

    /// Capture the identity of the currently focused window.
    ///
    /// Uses AX (not CGWindowList) for windowID because `resolveWindow(identity:)` later
    /// matches via AX focusedWindow + windowHandle — IDs must be from the same source.
    /// CGWindowList cannot reliably identify the focused window in multi-window apps
    /// (e.g., iTerm2 first match ≠ AX focused).
    ///
    /// - Returns: WindowIdentity of the focused window, or nil if unavailable
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
    ///
    /// ## 场景
    /// - SessionStart hook 的 autoFocus 路径调用（定位要最大化的终端窗口）。
    ///
    /// ## 实际策略（与历史 doc 注释一致化）
    /// doc 曾宣称策略 0（TTY/SESSION_ID）/策略 2（任意窗口含 cwd）/策略 3（非主屏幕约束），
    /// 与实现不符已删除。真实执行顺序：
    ///   1. Terminal/IDE host app 窗口中标题包含 cwd 项目名
    ///   2. host app 窗口中标题包含 "Claude Code"
    ///   3. 回退当前前台窗口
    /// （TTY/SESSION_ID 精确匹配由 findWindowByTerminalContext 承担，不在本函数。）
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

        // 从 cwd 中提取项目名（末段路径，纯函数；nil 表示无可用的项目名约束）
        let projectName = Self.projectName(fromCwd: cwd)

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
                title: title
            ))
        }

        // 三级策略匹配（纯决策，2.16a 第十九刀抽出；策略顺序与匹配条件的唯一事实源）
        if let match = Self.matchClaudeCodeCandidate(candidates, projectName: projectName, isHostApp: isHostApp) {
            switch match.strategy {
            case .hostAppProjectName:
                // 策略 1：Claude Host App 窗口中标题包含 cwd 项目名
                log(
                    "[WindowManager] findClaudeCodeWindow matched strategy 1: hostApp+cwd",
                    fields: [
                        "app": match.candidate.appName,
                        "title": truncateForLog(match.candidate.title, limit: 80),
                        "windowID": String(match.candidate.windowID),
                        "projectName": projectName ?? "nil",
                        "cgListMs": String(cgListMs),
                        "durationMs": String(elapsedMilliseconds(since: fcStart))
                    ]
                )
            case .hostAppClaudeCodeTitle:
                // 策略 2：Claude Host App 窗口中标题包含 "claude code"（无屏幕约束）
                log(
                    "[WindowManager] findClaudeCodeWindow matched strategy 2: hostApp+claudeCode",
                    fields: [
                        "app": match.candidate.appName,
                        "title": truncateForLog(match.candidate.title, limit: 80),
                        "windowID": String(match.candidate.windowID),
                        "cgListMs": String(cgListMs),
                        "durationMs": String(elapsedMilliseconds(since: fcStart))
                    ]
                )
            }
            return makeIdentity(from: match.candidate)
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
