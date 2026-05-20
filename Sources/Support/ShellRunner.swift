import Foundation

/// Single shared shell command runner — replaces duplicate Process+Pipe+waitUntilExit boilerplate
enum ShellRunner {
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

        process.waitUntilExit()

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
