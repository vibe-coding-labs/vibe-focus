import AppKit
import Foundation

/// Registry of known terminal application PIDs, bundle IDs, and process tree utilities.
/// 终端/IDE 应用单一事实来源 — 所有需要判断终端 PID 或 bundleID 的地方统一使用这个
enum TerminalRegistry {

    // MARK: - Terminal Apps

    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "com.electron.hyper",
        "org.tabby",
    ]

    static let terminalAppNames: Set<String> = [
        "Terminal", "iTerm2", "Warp", "Ghostty", "Alacritty", "kitty",
        "WezTerm", "Hyper", "Tabby",
    ]

    // MARK: - IDE Apps

    static let ideBundleIDs: Set<String> = [
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",
    ]

    static let ideAppNames: Set<String> = [
        "Cursor", "Code", "Visual Studio Code",
    ]

    // MARK: - Combined

    static var allTerminalAndIDEBundleIDs: Set<String> {
        terminalBundleIDs.union(ideBundleIDs)
    }

    static var allTerminalAndIDEAppNames: Set<String> {
        terminalAppNames.union(ideAppNames)
    }

    // MARK: - PID Resolution

    static func isTerminalPID(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        if let app = NSRunningApplication(processIdentifier: pid) {
            if let bid = app.bundleIdentifier, terminalBundleIDs.contains(bid) { return true }
            if let name = app.localizedName, terminalAppNames.contains(name) { return true }
        }
        if let comm = getProcessComm(pid) {
            let basename = URL(fileURLWithPath: comm).lastPathComponent
            return terminalAppNames.contains(basename)
        }
        return false
    }

    static func isTerminalOrIDEApp(appName: String?, bundleIdentifier: String?) -> Bool {
        if let appName, terminalAppNames.contains(appName) || ideAppNames.contains(appName) { return true }
        if let bundleIdentifier, terminalBundleIDs.contains(bundleIdentifier) || ideBundleIDs.contains(bundleIdentifier) { return true }
        return false
    }

    static func isTerminalBundleID(_ bundleID: String) -> Bool {
        return terminalBundleIDs.contains(bundleID)
    }

    static func findTerminalPID(from startPID: Int32) -> Int32? {
        var currentPID = startPID
        for _ in 0..<10 {
            if isTerminalPID(currentPID) { return currentPID }
            guard let ppid = getParentPID(currentPID), ppid > 1, ppid != currentPID else { break }
            currentPID = ppid
        }
        return nil
    }

    // MARK: - Private

    private static func getProcessComm(_ pid: Int32) -> String? {
        let output = ShellRunner.run(executable: "/bin/ps", arguments: ["-o", "comm=", "-p", String(pid)])?
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty ? nil : output
    }

    private static func getParentPID(_ pid: Int32) -> Int32? {
        let output = ShellRunner.run(executable: "/bin/ps", arguments: ["-o", "ppid=", "-p", String(pid)])?
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Int32(output)
    }
}
