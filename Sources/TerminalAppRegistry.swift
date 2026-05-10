import Foundation
import AppKit

/// 终端应用名单一事实来源 — 所有需要判断终端 PID 的地方统一使用这个
enum TerminalAppRegistry {
    static let appNames: Set<String> = [
        "Terminal", "iTerm2", "Warp", "Ghostty", "Alacritty", "kitty",
        "WezTerm", "Hyper", "Tabby"
    ]

    static let bundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
    ]

    /// 检查 PID 是否属于终端应用
    static func isTerminalPID(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        if let app = NSRunningApplication(processIdentifier: pid) {
            if let bid = app.bundleIdentifier, bundleIDs.contains(bid) { return true }
            if let name = app.localizedName, appNames.contains(name) { return true }
        }
        if let comm = getProcessComm(pid) {
            let basename = URL(fileURLWithPath: comm).lastPathComponent
            return appNames.contains(basename)
        }
        return false
    }

    /// 从进程树向上查找终端 PID
    static func findTerminalPID(from startPID: Int32) -> Int32? {
        var currentPID = startPID
        for _ in 0..<10 {
            if isTerminalPID(currentPID) { return currentPID }
            guard let ppid = getParentPID(currentPID), ppid > 1, ppid != currentPID else { break }
            currentPID = ppid
        }
        return nil
    }

    private static func getProcessComm(_ pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "comm=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty ? nil : output
    }

    private static func getParentPID(_ pid: Int32) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "ppid=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Int32(output)
    }
}
