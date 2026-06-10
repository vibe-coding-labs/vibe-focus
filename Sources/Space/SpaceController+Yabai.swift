// SpaceController+Yabai.swift
// VibeFocus — Yabai 命令执行与解码
// 从 SpaceController.swift 中提取

import Foundation

@MainActor
extension SpaceController {

    // MARK: - Scripting Addition Detection

    func isScriptingAdditionError(_ result: ShellResult) -> Bool {
        let text = "\(result.stdout)\n\(result.stderr)".lowercased()
        return text.contains("scripting-addition")
    }

    // MARK: - Yabai Command Execution

    func runYabai(
        arguments: [String],
        operation: String? = nil,
        operationID: String? = nil,
        logSuccess: Bool = false
    ) -> ShellResult? {
        let op = operationID ?? "none"
        guard let yabaiPath = locateYabai() else {
            log(
                "[SpaceController] yabai command skipped: executable not found",
                level: .error,
                fields: [
                    "op": op,
                    "operation": operation ?? "unknown",
                    "args": arguments.joined(separator: " ")
                ]
            )
            return nil
        }
        let startedAt = Date()
        guard let result = runProcess(executable: yabaiPath, arguments: arguments) else {
            log(
                "[SpaceController] failed to launch yabai command",
                level: .error,
                fields: [
                    "op": op,
                    "operation": operation ?? "unknown",
                    "args": arguments.joined(separator: " ")
                ]
            )
            return nil
        }

        let durationMs = elapsedMilliseconds(since: startedAt)
        let isSlow = durationMs >= 180

        if result.exitCode != 0 || logSuccess || isSlow {
            let stderr = truncateForLog(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), limit: 220)
            let stdout = truncateForLog(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), limit: 220)
            let level: LogLevel = result.exitCode == 0 ? (isSlow ? .warn : .info) : .warn
            log(
                isSlow && result.exitCode == 0 ? "[SpaceController] yabai command slow" : "[SpaceController] yabai command result",
                level: level,
                fields: [
                    "op": op,
                    "operation": operation ?? "unknown",
                    "exitCode": String(result.exitCode),
                    "durationMs": String(durationMs),
                    "args": arguments.joined(separator: " "),
                    "stderr": stderr.isEmpty ? "-" : stderr,
                    "stdout": stdout.isEmpty ? "-" : stdout
                ]
            )
        }

        return result
    }

    func runYabaiVariants(
        variants: [[String]],
        operation: String,
        operationID: String? = nil
    ) -> (success: Bool, failure: ShellResult?) {
        let op = operationID ?? "none"
        var lastFailure: ShellResult?
        var recoveredOnce = false

        for arguments in variants {
            while true {
                guard let result = runYabai(
                    arguments: arguments,
                    operation: operation,
                    operationID: op,
                    logSuccess: true
                ) else {
                    log(
                        "[SpaceController] operation failed to launch",
                        level: .error,
                        fields: [
                            "op": op,
                            "operation": operation,
                            "args": arguments.joined(separator: " ")
                        ]
                    )
                    break
                }

                if result.exitCode == 0 {
                    return (true, nil)
                }

                lastFailure = result
                let stderr = truncateForLog(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), limit: 220)
                let stdout = truncateForLog(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), limit: 220)
                log(
                    "[SpaceController] operation failed",
                    level: .warn,
                    fields: [
                        "op": op,
                        "operation": operation,
                        "exitCode": String(result.exitCode),
                        "args": arguments.joined(separator: " "),
                        "stderr": stderr.isEmpty ? "-" : stderr,
                        "stdout": stdout.isEmpty ? "-" : stdout
                    ]
                )

                if !recoveredOnce, isScriptingAdditionError(result), attemptScriptingAdditionRecovery(trigger: operation, operationID: op) {
                    recoveredOnce = true
                    log(
                        "[SpaceController] retrying after scripting-addition recovery",
                        fields: [
                            "op": op,
                            "operation": operation
                        ]
                    )
                    continue
                }

                break
            }
        }

        return (false, lastFailure)
    }

    // MARK: - Error Reporting

    func markOperationError(from result: ShellResult?, fallback: String, operationID: String? = nil) {
        let op = operationID ?? "none"
        if let result {
            if isScriptingAdditionError(result) {
                lastErrorMessage = "yabai scripting-addition 不可用，跨工作区恢复功能受限。请在设置中加载 scripting-addition。"
                canControlSpaces = false
            } else {
                lastErrorMessage = Self.formatErrorMessage(stdout: result.stdout, stderr: result.stderr)
            }
        } else {
            lastErrorMessage = fallback
        }
        log(
            "[SpaceController] operation error",
            level: .error,
            fields: [
                "op": op,
                "fallback": fallback,
                "lastError": lastErrorMessage ?? "nil"
            ]
        )
    }

    func markOperationError(_ message: String, operationID: String? = nil) {
        let op = operationID ?? "none"
        lastErrorMessage = message
        log(
            "[SpaceController] operation error",
            level: .error,
            fields: [
                "op": op,
                "message": message
            ]
        )
    }

    // MARK: - Process & Decoding Utilities

    func runProcess(executable: String, arguments: [String]) -> ShellResult? {
        return ShellRunner.run(executable: executable, arguments: arguments)
    }

    func decodeSingleOrFirst<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        Self.staticDecodeSingleOrFirst(type, from: text)
    }

    func decodeArray<T: Decodable>(_ type: T.Type, from text: String) -> [T]? {
        let data = Data(text.utf8)
        let decoder = JSONDecoder()
        if let array = try? decoder.decode([T].self, from: data) {
            return array
        }
        return nil
    }

    static func staticDecodeSingleOrFirst<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        let data = Data(text.utf8)
        let decoder = JSONDecoder()
        if let single = try? decoder.decode(T.self, from: data) {
            return single
        }
        if let array = try? decoder.decode([T].self, from: data) {
            return array.first
        }
        return nil
    }

    static func formatErrorMessage(stdout: String, stderr: String) -> String {
        let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedStderr.isEmpty {
            return trimmedStderr
        }
        if !trimmedStdout.isEmpty {
            return trimmedStdout
        }
        return "yabai returned empty error output"
    }
}
