import Foundation

/// Single shared shell command runner — replaces duplicate Process+Pipe+waitUntilExit boilerplate
enum ShellRunner {
    /// 子进程超时（与 YabaiClient.commandTimeout 对齐）。
    /// yabai / scripting-addition 抖动时防止 waitUntilExit 无限阻塞主线程
    /// （2026-06-12 性能审核瓶颈 C，toggle 间歇 spike 嫌疑之一）。
    static let commandTimeout: TimeInterval = 2.0

    @discardableResult
    static func run(executable: String, arguments: [String]) -> YabaiClient.YabaiResult? {
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

        // 超时保护：yabai / scripting-addition 抖动时 waitUntilExit() 会无限阻塞主线程，
        // 是 toggle 间歇性 spike（实测 1-2.7s）的嫌疑之一（见 2026-06-12 审核瓶颈 C）。
        // 与 YabaiClient.commandTimeout(2.0s) 对齐：超时后 terminate 并返回 nil，调用方走 fallback。
        let sem = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in sem.signal() }
        if sem.wait(timeout: .now() + commandTimeout) == .timedOut {
            process.terminate()
            return nil
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        return YabaiClient.YabaiResult(
            exitCode: process.terminationStatus,
            stdout: String(data: output, encoding: .utf8) ?? "",
            stderr: String(data: errorData, encoding: .utf8) ?? ""
        )
    }

    @discardableResult
    static func run(executable: String, arguments: [String], stdin: String) -> YabaiClient.YabaiResult? {
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

        // 超时保护（同 run(executable:arguments:)，见瓶颈 C 说明）
        let sem = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in sem.signal() }
        if sem.wait(timeout: .now() + commandTimeout) == .timedOut {
            process.terminate()
            return nil
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        return YabaiClient.YabaiResult(
            exitCode: process.terminationStatus,
            stdout: String(data: output, encoding: .utf8) ?? "",
            stderr: String(data: errorData, encoding: .utf8) ?? ""
        )
    }

    static func runShell(_ command: String) -> String? {
        guard let result = run(executable: "/bin/bash", arguments: ["-c", command]),
              result.exitCode == 0 else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
