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

    /// 进程树向上查找终端 PID 的纯行走核心（2.16a 第二十刀从 findTerminalPID 抽出）。
    /// 每轮先判 isTerminal（命中即返回），否则沿 parentPID 上溯；
    /// 父链断裂（nil）、ppid ≤ 1、自环（ppid == 当前）三重守卫即止；至多 maxDepth 轮
    /// （maxDepth < 1 归一为 1）。返回 (命中 pid 或 nil, 实际行走轮数)。
    /// parent/isTerminal 谓词注入：fork 型 ps 查询留在 findTerminalPID，行走语义可穷尽测试。
    static func walkToTerminalPID(
        startPID: Int32,
        parentPID: (Int32) -> Int32?,
        isTerminal: (Int32) -> Bool,
        maxDepth: Int = 10
    ) -> (pid: Int32?, depth: Int) {
        var currentPID = startPID
        var depth = 0
        for _ in 0..<max(1, maxDepth) {
            depth += 1
            if isTerminal(currentPID) { return (currentPID, depth) }
            guard let ppid = parentPID(currentPID), ppid > 1, ppid != currentPID else { break }
            currentPID = ppid
        }
        return (nil, depth)
    }

    static func findTerminalPID(from startPID: Int32) -> Int32? {
        // P-INST-59: findTerminalPID 进程树遍历耗时（循环最多 10 次，每次 isTerminalPID + getParentPID 各一次 ps fork；findWindowByTerminalContext P-INST-39 的进程树解析核心，ps fork 累积是 SessionStart 耗时主因）。
        let ftpStart = Date()
        // 行走语义走纯函数（2.16a 第二十刀）：isTerminalPID/getParentPID 作为谓词注入，
        // ps fork 仍由本函数的私有查询承担，fork 次数契约见 TerminalTreeWalkTests。
        let walk = walkToTerminalPID(
            startPID: startPID,
            parentPID: getParentPID,
            isTerminal: isTerminalPID
        )
        defer {
            log("[TerminalRegistry] findTerminalPID finished", level: .debug, fields: [
                "startPID": String(startPID),
                "depth": String(walk.depth),
                "found": String(walk.pid != nil),
                "durationMs": String(elapsedMilliseconds(since: ftpStart))
            ])
        }
        return walk.pid
    }

    // MARK: - Private

    private static func getProcessComm(_ pid: Int32) -> String? {
        // P-INST-248: 终端进程 comm 查询耗时（/bin/ps -o comm= fork + stdout 解析；终端上下文识别 parent chain walk 循环调用，每次 fork 可阻塞；slow-op ≥50ms warn）。
        #if PERF_INSTRUMENT
        let gpcStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: gpcStart)
            if durMs >= 50 { log("[TerminalRegistry] getProcessComm slow", level: .warn, fields: ["pid": String(pid), "durationMs": String(durMs)]) }
        }
        #endif
        let output = ShellRunner.run(executable: "/bin/ps", arguments: ["-o", "comm=", "-p", String(pid)])?
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty ? nil : output
    }

    private static func getParentPID(_ pid: Int32) -> Int32? {
        // P-INST-249: 终端进程父 PID 查询耗时（/bin/ps -o ppid= fork + stdout 解析；终端上下文识别 parent chain walk 循环调用，每次 fork 可阻塞；slow-op ≥50ms warn）。
        #if PERF_INSTRUMENT
        let gppStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: gppStart)
            if durMs >= 50 { log("[TerminalRegistry] getParentPID slow", level: .warn, fields: ["pid": String(pid), "durationMs": String(durMs)]) }
        }
        #endif
        let output = ShellRunner.run(executable: "/bin/ps", arguments: ["-o", "ppid=", "-p", String(pid)])?
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Int32(output)
    }
}
