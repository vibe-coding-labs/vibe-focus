// WindowManager+TerminalContext+Helpers.swift
// VibeFocus — 终端上下文窗口匹配的纯函数工具
// 从 WindowManager+TerminalContext.swift 中提取

import AppKit
import Foundation

@MainActor
extension WindowManager {

    // MARK: - TTY Normalization (extracted for testability)

    /// Normalize a TTY string to a full device path.
    /// Returns nil for empty, "not a tty", or nil input.
    static func normalizeTTY(_ tty: String?) -> String? {
        guard let tty, !tty.isEmpty, tty != "not a tty" else { return nil }
        return tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
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
