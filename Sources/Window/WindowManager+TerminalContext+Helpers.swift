// WindowManager+TerminalContext+Helpers.swift
// VibeFocus — 终端上下文窗口匹配的纯函数工具
// 从 WindowManager+TerminalContext.swift 中提取

import AppKit
import Foundation

@MainActor
extension WindowManager {

    // MARK: - TTY Normalization (唯一事实源，2.16a 第十八刀)

    /// 前缀半边：无 /dev/ 前缀则补全。输入契约：非可选、已验证的 TTY 串
    /// （iTerm2 匹配×3 与 TitleEditor TTY 写入的共用实现；格式校验归 isValidTTYPath）。
    static func fullDevicePath(_ tty: String) -> String {
        tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
    }

    /// 完整归一化：nil/空串/"not a tty"（精确匹配）→ nil；其余走 fullDevicePath 补全。
    /// 第十六刀曾因"生产零调用"误删——真实消费者 findWindowByTerminalContext 以内联
    /// 副本存在（连同其余 4 处共 5 份内联），本刀恢复为唯一事实源并全量接线。
    static func normalizeTTY(_ tty: String?) -> String? {
        guard let tty, !tty.isEmpty, tty != "not a tty" else { return nil }
        return fullDevicePath(tty)
    }

    // MARK: - Static Helpers (extracted for testability)

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
    func findWindowsForPID(_ pid: Int32) -> [WindowIdentity] {
        // P-INST-60: findWindowsForPID 耗时（cgWindowListAll P-INST-45 + NSRunningApplication + 可能 ps fork P-INST-49；findWindowByTerminalContext P-INST-39 子归因）。
        #if PERF_INSTRUMENT
        let fwspStart = Date()
        defer {
            log("[WindowManager] findWindowsForPID finished", level: .debug, fields: [
                "pid": String(pid),
                "durationMs": String(elapsedMilliseconds(since: fwspStart))
            ])
        }
        #endif
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

    // MARK: - Input Validation (defense-in-depth)

    /// Validate iTerm2 session UUID part — allowlist: hex digits and hyphens only.
    /// Prevents any metacharacter injection into AppleScript string interpolation.
    static func isValidUUIDPart(_ uuid: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        return uuid.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Validate TTY device path — allowlist: /dev/ttys### or /dev/pty### format.
    /// Prevents any metacharacter injection into AppleScript string interpolation.
    static func isValidTTYPath(_ path: String) -> Bool {
        let pattern = "^/dev/(tty[s\\d]+|pty[\\d]+)$"
        return path.range(of: pattern, options: .regularExpression) != nil
    }
}
