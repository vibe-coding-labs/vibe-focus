import Darwin
import Foundation

// MARK: - Title Editor TTY Writer
// 通过 TTY 设备写入 OSC 转义序列设置终端窗口标题
@MainActor
extension TitleEditorService {

    func applyViaTTY(_ title: String, pid: pid_t) -> Bool {
        guard let ttyPath = resolveTTYPath(for: pid) else {
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
        return writeTTYSequence(sequence, to: ttyPath)
    }

    func resolveTTYPath(for pid: pid_t) -> String? {
        // Try the process itself first (works if pid is a shell, not a GUI terminal)
        if let tty = ttyForPID(pid) { return tty }

        // GUI terminal apps don't have TTYs — search child processes
        return searchChildTTY(parentPID: pid, depth: 0)
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
