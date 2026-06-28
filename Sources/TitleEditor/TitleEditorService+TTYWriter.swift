import Darwin
import Foundation

// MARK: - Title Editor TTY Writer
// 通过 TTY 设备写入 OSC 转义序列设置终端窗口标题
@MainActor
extension TitleEditorService {

    func applyViaTTY(_ title: String, pid: pid_t) -> Bool {
        // P-INST-48: TTY title 写入耗时（resolveTTYPath: ps/pgrep fork 递归 + writeTTYSequence open/write 设备；applyTitle P-INST-40 总耗时归因 TTY 路，fork 累积可阻塞）。
        let ttyStart = Date()
        var ttyOutcome = "unknown"
        defer {
            log("[TitleEditorService] applyViaTTY finished", level: .debug, fields: [
                "pid": String(pid),
                "outcome": ttyOutcome,
                "durationMs": String(elapsedMilliseconds(since: ttyStart))
            ])
        }
        guard let ttyPath = resolveTTYPath(for: pid) else {
            ttyOutcome = "no_tty"
            log(
                "[TitleEditorService] applyViaTTY: could not resolve TTY",
                level: .debug,
                fields: ["pid": String(pid)]
            )
            return false
        }

        log(
            "[TitleEditorService] applyViaTTY: resolved TTY",
            fields: ["ttyPath": ttyPath, "pid": String(pid)]
        )

        let sequence = "\u{1B}]0;\(title)\u{07}"
        let written = writeTTYSequence(sequence, to: ttyPath)
        ttyOutcome = written ? "written" : "write_failed"
        return written
    }

    func resolveTTYPath(for pid: pid_t) -> String? {
        // P-INST-72: TTY 路径解析耗时（ttyForPID /bin/ps fork + searchChildTTY pgrep 递归 fork 最多 3 层；applyViaTTY P-INST-48 子阶段，fork 累积可阻塞）。
        let rtpStart = Date()
        var found = false
        defer {
            log("[TitleEditorService] resolveTTYPath finished", level: .debug, fields: [
                "pid": String(pid),
                "found": String(found),
                "durationMs": String(elapsedMilliseconds(since: rtpStart))
            ])
        }
        // Try the process itself first (works if pid is a shell, not a GUI terminal)
        if let tty = ttyForPID(pid) { found = true; return tty }

        // GUI terminal apps don't have TTYs — search child processes
        if let tty = searchChildTTY(parentPID: pid, depth: 0) { found = true; return tty }
        return nil
    }

    private func ttyForPID(_ pid: pid_t) -> String? {
        let output = WindowManager.shared.runShellCommand("/bin/ps", args: ["-o", "tty=", "-p", String(pid)])
        let tty = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if tty.isEmpty || tty == "??" || tty == "?" { return nil }
        return tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
    }

    private func searchChildTTY(parentPID: pid_t, depth: Int) -> String? {
        guard depth < 3 else { return nil }

        let output = WindowManager.shared.runShellCommand("/usr/bin/pgrep", args: ["-P", String(parentPID)])
        let childPIDs = output?.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines) ?? []

        for childPIDStr in childPIDs {
            let trimmed = childPIDStr.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let childPID = pid_t(trimmed) else { continue }

            if let tty = ttyForPID(childPID) { return tty }
            if let tty = searchChildTTY(parentPID: childPID, depth: depth + 1) { return tty }
        }

        return nil
    }

    func writeTTYSequence(_ sequence: String, to ttyPath: String) -> Bool {
        // P-INST-72: TTY 设备写耗时（open O_WRONLY + write OSC 序列；applyViaTTY P-INST-48 子阶段，设备繁忙可阻塞）。
        let wtsStart = Date()
        defer {
            log("[TitleEditorService] writeTTYSequence finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: wtsStart))
            ])
        }
        guard let data = sequence.data(using: .utf8) else { return false }

        let fd = open(ttyPath, O_WRONLY | O_NOCTTY)
        guard fd >= 0 else {
            log(
                "[TitleEditorService] writeTTYSequence: open() failed",
                level: .warn,
                fields: ["ttyPath": ttyPath, "errno": String(errno)]
            )
            return false
        }
        defer { close(fd) }

        let written = data.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress, ptr.count)
        }

        let success = written >= 0
        if !success {
            log(
                "[TitleEditorService] writeTTYSequence: write() failed",
                level: .warn,
                fields: ["ttyPath": ttyPath, "errno": String(errno)]
            )
        }
        return success
    }
}
