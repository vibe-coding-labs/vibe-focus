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
        // P-INST-27: runYabaiVariants 总耗时（多 variant 尝试 + SA recovery 重试的累积成本；单 variant 成功时 ≈ 单个 runYabai durationMs）。
        let variantsStart = Date()
        var lastFailure: ShellResult?
        var recoveredOnce = false
        var finalSuccess = false
        defer {
            log("[SpaceController] runYabaiVariants finished", level: .debug, fields: [
                "op": op, "operation": operation,
                "success": String(finalSuccess), "recovered": String(recoveredOnce),
                "durationMs": String(elapsedMilliseconds(since: variantsStart))
            ])
        }

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
                    finalSuccess = true
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
        // P-INST-194: SpaceController 进程执行入口耗时（委托 ShellRunner.run fork P-INST-49；yabai 查询/SA 探测等 SpaceController 路径调用，≥50ms warn 归因调用点）。
        let rpStart = Date()
        let result = ShellRunner.run(executable: executable, arguments: arguments)
        let durMs = elapsedMilliseconds(since: rpStart)
        if durMs >= 50 { log("[SpaceController] runProcess slow", level: .warn, fields: ["executable": executable, "durationMs": String(durMs)]) }
        return result
    }

    func decodeSingleOrFirst<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        Self.staticDecodeSingleOrFirst(type, from: text)
    }

    func decodeArray<T: Decodable>(_ type: T.Type, from text: String) -> [T]? {
        // P-INST-223: yabai 结果数组解码耗时（JSONDecoder.decode [T]；yabai query 返回大窗口列表时 decode 可能累积；slow-op ≥5ms warn）。
        let daStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: daStart)
            if durMs >= 5 { log("[SpaceController+Yabai] decodeArray slow", level: .warn, fields: ["textLen": String(text.count), "durationMs": String(durMs)]) }
        }
        let data = Data(text.utf8)
        let decoder = JSONDecoder()
        if let array = try? decoder.decode([T].self, from: data) {
            return array
        }
        return nil
    }

    static func staticDecodeSingleOrFirst<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        // P-INST-224: yabai 结果单值/首元素解码耗时（JSONDecoder.decode T 或 [T].first；查询解析路径；slow-op ≥5ms warn）。
        let sdsStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: sdsStart)
            if durMs >= 5 { log("[SpaceController+Yabai] staticDecodeSingleOrFirst slow", level: .warn, fields: ["textLen": String(text.count), "durationMs": String(durMs)]) }
        }
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
