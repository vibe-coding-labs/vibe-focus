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
        // P-INST-59: findTerminalPID 进程树遍历耗时（循环最多 10 次，每次 isTerminalPID + getParentPID 各一次 ps fork；findWindowByTerminalContext P-INST-39 的进程树解析核心，ps fork 累积是 SessionStart 耗时主因）。
        let ftpStart = Date()
        var depth = 0
        var found = false
        defer {
            log("[TerminalRegistry] findTerminalPID finished", level: .debug, fields: [
                "startPID": String(startPID),
                "depth": String(depth),
                "found": String(found),
                "durationMs": String(elapsedMilliseconds(since: ftpStart))
            ])
        }
        var currentPID = startPID
        for _ in 0..<10 {
            depth += 1
            if isTerminalPID(currentPID) { found = true; return currentPID }
            guard let ppid = getParentPID(currentPID), ppid > 1, ppid != currentPID else { break }
            currentPID = ppid
        }
        return nil
    }

    // MARK: - Private

    private static func getProcessComm(_ pid: Int32) -> String? {
        // P-INST-248: 终端进程 comm 查询耗时（/bin/ps -o comm= fork + stdout 解析；终端上下文识别 parent chain walk 循环调用，每次 fork 可阻塞；slow-op ≥50ms warn）。
        let gpcStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: gpcStart)
            if durMs >= 50 { log("[TerminalRegistry] getProcessComm slow", level: .warn, fields: ["pid": String(pid), "durationMs": String(durMs)]) }
        }
        let output = ShellRunner.run(executable: "/bin/ps", arguments: ["-o", "comm=", "-p", String(pid)])?
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty ? nil : output
    }

    private static func getParentPID(_ pid: Int32) -> Int32? {
        // P-INST-249: 终端进程父 PID 查询耗时（/bin/ps -o ppid= fork + stdout 解析；终端上下文识别 parent chain walk 循环调用，每次 fork 可阻塞；slow-op ≥50ms warn）。
        let gppStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: gppStart)
            if durMs >= 50 { log("[TerminalRegistry] getParentPID slow", level: .warn, fields: ["pid": String(pid), "durationMs": String(durMs)]) }
        }
        let output = ShellRunner.run(executable: "/bin/ps", arguments: ["-o", "ppid=", "-p", String(pid)])?
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Int32(output)
    }
}
