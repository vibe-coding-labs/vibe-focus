import Foundation

/// Single shared shell command runner — replaces duplicate Process+Pipe+waitUntilExit boilerplate
enum ShellRunner {
    /// 子进程超时（与 YabaiClient.commandTimeout 对齐）。
    /// yabai / scripting-addition 抖动时防止 waitUntilExit 无限阻塞主线程
    /// （2026-06-12 性能审核瓶颈 C，toggle 间歇 spike 嫌疑之一）。
    static let commandTimeout: TimeInterval = 2.0

    /// 并发排空缓冲盒：单写者（排空队列）+ DispatchGroup.wait 建立先序后调用线程才读。
    /// @unchecked Sendable：数据竞争安全性由「单写者 + group 先序」约定保证（见上），
    /// 编译器无法验证该协议，2026-09-16 零警告门禁补标。
    private final class DrainBox: @unchecked Sendable {
        var data = Data()
    }

    @discardableResult
    static func run(executable: String, arguments: [String], timeout: TimeInterval = commandTimeout) -> YabaiClient.YabaiResult? {
        // P-INST-49: ShellRunner fork 耗时（ps/pgrep/外部命令底层 fork；被 runShellCommand 包装，findWindowByTerminalContext 进程树/applyViaTTY 等多路径调用；slow-op ≥50ms warn 抓阻塞或超时=2000ms）。
        #if PERF_INSTRUMENT
        let shellStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: shellStart)
            if durMs >= 50 {
                log("[ShellRunner] run slow fork", level: .warn, fields: [
                    "executable": executable,
                    "args": arguments.joined(separator: " "),
                    "durationMs": String(durMs)
                ])
            }
        }
        #endif
        // B190 常开埋点（不走 PERF_INSTRUMENT——装机版默认不开，legacy P-INST 日志全是死代码）：
        // 每次 fork 计入 shell.<bin> / shell.main.<bin> 直方图（主线程 fork 独立分桶，
        // 「谁在主线程 fork、典型 vs 最差」直接进 perf-snapshot.json 与停顿报告 top=[...]）；
        // 主线程 ≥100ms 另打 [PERF][FORK-ON-MAIN] WARN 行，逐次留痕不必等 250ms 停顿兜底。
        let perfForkStart = Date()
        defer {
            let durMs = Double(elapsedMilliseconds(since: perfForkStart))
            PerfMonitor.shared.record(
                PerfMonitorLogic.shellCounterName(executable: executable, isMainThread: Thread.isMainThread),
                durationMs: durMs)
            if PerfMonitorLogic.shouldWarnMainFork(isMainThread: Thread.isMainThread, durationMs: durMs) {
                log("[PERF][FORK-ON-MAIN]", level: .warn, fields: [
                    "executable": executable,
                    "args": arguments.prefix(4).joined(separator: " "),
                    "durationMs": String(Int(durMs))
                ])
                PerfMonitor.shared.journal(String(format: "fork.main %@ %.0fms", (executable as NSString).lastPathComponent, durMs))
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        // 经典 Process+Pipe 死锁修复（2026-09-14 真机实锤）：子进程输出超过管道缓冲
        // （macOS 默认 16KB；ssh 远程探针 23KB、大桌面 yabai query JSON 都在这条线
        // 以上）时写端阻塞、子进程永不退出——「等退出再读」恒超时返 nil。读必须与
        // 子进程生命周期并发；正常退出后 EOF 天然到达。
        let outputBox = DrainBox()
        let errorBox = DrainBox()
        let drainGroup = DispatchGroup()
        for (pipe, box) in [(outputPipe, outputBox), (errorPipe, errorBox)] {
            drainGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                drainGroup.leave()
            }
        }

        // 超时保护：yabai / scripting-addition 抖动时 waitUntilExit() 会无限阻塞主线程，
        // 是 toggle 间歇性 spike（实测 1-2.7s）的嫌疑之一（见 2026-06-12 审核瓶颈 C）。
        // 与 YabaiClient.commandTimeout(2.0s) 对齐：超时后 terminate 并返回 nil，调用方走 fallback。
        let sem = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in sem.signal() }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        // 退出后子进程写端关闭 → EOF 立即到达；grace 只为孙进程继承写端不退的
        // 病态场景兜底（超时语义与旧实现一致 = nil）
        guard drainGroup.wait(timeout: .now() + 1.0) == .success else {
            return nil
        }

        return YabaiClient.YabaiResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outputBox.data, encoding: .utf8) ?? "",
            stderr: String(data: errorBox.data, encoding: .utf8) ?? ""
        )
    }

    @discardableResult
    static func run(executable: String, arguments: [String], stdin: String) -> YabaiClient.YabaiResult? {
        // P-INST-49: ShellRunner fork + stdin 耗时（同 run(executable:arguments:) slow-op ≥50ms warn）。
        #if PERF_INSTRUMENT
        let shellStdinStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: shellStdinStart)
            if durMs >= 50 {
                log("[ShellRunner] run(stdin) slow fork", level: .warn, fields: [
                    "executable": executable,
                    "args": arguments.joined(separator: " "),
                    "durationMs": String(durMs)
                ])
            }
        }
        #endif
        // B190 常开埋点（语义同 run(executable:arguments:) 的 B190 段）。
        let perfStdinStart = Date()
        defer {
            let durMs = Double(elapsedMilliseconds(since: perfStdinStart))
            PerfMonitor.shared.record(
                PerfMonitorLogic.shellCounterName(executable: executable, isMainThread: Thread.isMainThread),
                durationMs: durMs)
            if PerfMonitorLogic.shouldWarnMainFork(isMainThread: Thread.isMainThread, durationMs: durMs) {
                log("[PERF][FORK-ON-MAIN]", level: .warn, fields: [
                    "executable": executable,
                    "args": arguments.prefix(4).joined(separator: " "),
                    "durationMs": String(Int(durMs)),
                    "stdin": "yes"
                ])
                PerfMonitor.shared.journal(String(format: "fork.main %@ %.0fms", (executable as NSString).lastPathComponent, durMs))
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        if let data = stdin.data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(data)
        }
        try? inputPipe.fileHandleForWriting.close()

        // 并发排空（死锁修复同 run(executable:arguments:)，见该处注记）
        let outputBox = DrainBox()
        let errorBox = DrainBox()
        let drainGroup = DispatchGroup()
        for (pipe, box) in [(outputPipe, outputBox), (errorPipe, errorBox)] {
            drainGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                drainGroup.leave()
            }
        }

        // 超时保护（同 run(executable:arguments:)，见瓶颈 C 说明）
        let sem = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in sem.signal() }
        if sem.wait(timeout: .now() + commandTimeout) == .timedOut {
            process.terminate()
            return nil
        }
        guard drainGroup.wait(timeout: .now() + 1.0) == .success else {
            return nil
        }

        return YabaiClient.YabaiResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outputBox.data, encoding: .utf8) ?? "",
            stderr: String(data: errorBox.data, encoding: .utf8) ?? ""
        )
    }

    static func runShell(_ command: String) -> String? {
        // P-INST-197: bash -c 命令执行耗时（委托 run(executable:arguments:) fork P-INST-49；shell 一行命令便捷入口，≥50ms warn 归因调用点）。
        let rshStart = Date()
        guard let result = run(executable: "/bin/bash", arguments: ["-c", command]),
              result.exitCode == 0 else { return nil }
        let durMs = elapsedMilliseconds(since: rshStart)
        if durMs >= 50 { log("[ShellRunner] runShell slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
