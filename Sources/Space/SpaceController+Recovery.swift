import AppKit
import Foundation

@MainActor
extension SpaceController {

    func requestScriptingAdditionLoad() {
        let op = makeOperationID(prefix: "sa-load")
        // P-INST-207: 手动 SA 加载请求耗时（UserDefaults.standard.removeObject CFPreferences 写 + attemptScriptingAdditionRecovery fork + refreshAvailability；设置面板用户按钮触发）。
        let rsalStart = Date()
        defer {
            log("[SpaceController] requestScriptingAdditionLoad finished", fields: ["op": op, "durationMs": String(elapsedMilliseconds(since: rsalStart))])
        }
        log(
            "[SpaceController] manual scripting-addition load requested",
            fields: ["op": op]
        )
        // 重置恢复标记，允许重新尝试
        didAttemptScriptingAdditionRecovery = false
        scriptingAdditionRecoverySucceeded = false
        // 清除持久化失败缓存，否则 24 小时内手动按钮也会被阻断
        UserDefaults.standard.removeObject(forKey: "scriptingAdditionRecoveryFailedAt")
        _ = attemptScriptingAdditionRecovery(trigger: "manual", operationID: op)
        // 加载成功后刷新可用性
        if scriptingAdditionRecoverySucceeded {
            refreshAvailability(force: true)
        }
    }

    func checkScriptingAdditionLoaded(yabaiPath: String) -> Bool {
        // P-INST-35: SA 检查耗时（yabai query --windows --window fork；availability 路径，启动 + 节流刷新时调用）。
        let csaStart = Date()
        var csaResult = "failed_to_run"
        defer {
            log("[SpaceController] checkScriptingAdditionLoaded finished", fields: [
                "result": csaResult,
                "durationMs": String(elapsedMilliseconds(since: csaStart))
            ])
        }
        // 方法：获取当前焦点窗口并尝试 query --window（含 display 字段需要 SA）
        // 更简单的方法：直接尝试 yabai -m window --focus <id>，如果失败且错误包含
        // scripting-addition，则 SA 未加载
        // 最可靠的方法：检查 yabai query --windows 返回的窗口是否包含 display 字段
        // 但更简单：尝试一个轻量 SA 操作
        guard let result = runProcess(executable: yabaiPath, arguments: ["-m", "query", "--windows", "--window"]) else {
            log("checkScriptingAdditionLoaded: failed to run yabai query")
            return false
        }
        if result.exitCode == 0, !result.stdout.isEmpty {
            // query --window 成功且返回数据，检查是否包含 display 字段
            // 没有 SA 时，display 字段不存在或值为 0
            let hasDisplay = result.stdout.contains("\"display\"")
            csaResult = hasDisplay ? "loaded" : "not_loaded"
            log("checkScriptingAdditionLoaded: query succeeded, hasDisplay=\(hasDisplay)")
            return hasDisplay
        }
        // query --window 失败（可能没有焦点窗口），回退到检查错误信息
        let stderr = result.stderr.lowercased()
        let hasSAError = stderr.contains("scripting-addition")
        csaResult = hasSAError ? "sa_error" : "no_focus_window"
        log("checkScriptingAdditionLoaded: query failed, hasSAError=\(hasSAError), stderr=\(result.stderr.prefix(100))")
        return !hasSAError
    }

    func attemptSilentSARecovery(yabaiPath: String) {
        // P-INST-36: 静默 SA 恢复耗时（yabai --load-sa fork，无 admin 对话框）。
        let ssrStart = Date()
        var ssrResult = "failed"
        defer {
            log("[SpaceController] attemptSilentSARecovery finished", fields: [
                "result": ssrResult,
                "durationMs": String(elapsedMilliseconds(since: ssrStart))
            ])
        }
        log("attemptSilentSARecovery: trying yabai --load-sa without admin prompt")
        if let direct = runProcess(executable: yabaiPath, arguments: ["--load-sa"]), direct.exitCode == 0 {
            ssrResult = "loaded"
            scriptingAdditionRecoverySucceeded = true
            canControlSpaces = true
            lastErrorMessage = nil
            log("attemptSilentSARecovery: scripting-addition loaded successfully via direct --load-sa")
            updateEnabledState()
        } else {
            log("attemptSilentSARecovery: direct --load-sa failed, user needs to load manually")
            // 清除 24 小时失败缓存，允许用户手动点击"加载"按钮时不会被阻断
            UserDefaults.standard.removeObject(forKey: "scriptingAdditionRecoveryFailedAt")
            didAttemptScriptingAdditionRecovery = false
        }
    }

    func attemptScriptingAdditionRecovery(trigger: String, operationID: String? = nil) -> Bool {
        let op = operationID ?? "none"
        // P-INST-34: recovery 总耗时（yabai --load-sa fork + 可能的 admin 权限对话框，发生时可能秒级；偶发，result 见各路径 log 用 op 关联，归因 runYabaiVariants durationMs 中 recovery vs fork）。
        let recoveryStart = Date()
        defer {
            log("[SpaceController] scripting-addition recovery finished", fields: [
                "op": op, "trigger": trigger,
                "durationMs": String(elapsedMilliseconds(since: recoveryStart))
            ])
        }
        if didAttemptScriptingAdditionRecovery {
            return scriptingAdditionRecoverySucceeded
        }

        // 检查上次进程是否已持久化记录 recovery 失败（避免每次重启都弹管理员权限窗口）
        let lastFailedAt = UserDefaults.standard.double(forKey: "scriptingAdditionRecoveryFailedAt")
        if lastFailedAt > 0 {
            let hoursSinceFailure = Date().timeIntervalSince1970 - lastFailedAt
            if hoursSinceFailure < 24 * 3600 {
                log(
                    "[SpaceController] scripting-addition recovery skipped: previously failed (cached)",
                    level: .warn,
                    fields: [
                        "op": op,
                        "hoursAgo": String(format: "%.1f", hoursSinceFailure / 3600),
                        "trigger": trigger
                    ]
                )
                didAttemptScriptingAdditionRecovery = true
                scriptingAdditionRecoverySucceeded = false
                return false
            }
            // 超过 24 小时，允许重试（用户可能已修复 yabai/SIP）
            UserDefaults.standard.removeObject(forKey: "scriptingAdditionRecoveryFailedAt")
        }

        didAttemptScriptingAdditionRecovery = true

        guard let yabaiPath = locateYabai() else {
            log(
                "[SpaceController] scripting-addition recovery skipped: yabai path missing",
                level: .error,
                fields: [
                    "op": op,
                    "trigger": trigger
                ]
            )
            return false
        }

        log(
            "[SpaceController] attempting scripting-addition recovery",
            fields: [
                "op": op,
                "trigger": trigger
            ]
        )

        if let direct = runProcess(executable: yabaiPath, arguments: ["--load-sa"]), direct.exitCode == 0 {
            scriptingAdditionRecoverySucceeded = true
            canControlSpaces = true
            lastErrorMessage = nil
            log(
                "[SpaceController] scripting-addition recovered via direct load-sa",
                fields: [
                    "op": op
                ]
            )
            return true
        }

        // 使用 macOS 原生密码对话框请求管理员权限加载 scripting-addition
        let (privSuccess, privOutput) = executeWithAdminPrivileges(
            "\(yabaiPath) --load-sa",
            operationID: op
        )

        if privSuccess {
            scriptingAdditionRecoverySucceeded = true
            canControlSpaces = true
            lastErrorMessage = nil
            log(
                "[SpaceController] scripting-addition recovered via admin privileges",
                fields: [
                    "op": op,
                    "output": truncateForLog(privOutput, limit: 120)
                ]
            )
            return true
        }

        log(
            "[SpaceController] scripting-addition recovery failed: admin privilege dialog cancelled or error",
            level: .error,
            fields: [
                "op": op,
                "detail": truncateForLog(privOutput, limit: 220)
            ]
        )
        // 持久化记录失败，避免每次重启都弹管理员权限窗口（24 小时后过期重试）
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "scriptingAdditionRecoveryFailedAt")
        lastErrorMessage = "跨工作区恢复需要管理员权限来加载 yabai scripting-addition。可以在设置中点击\"加载\"按钮手动触发。"
        return false
    }

    func executeWithAdminPrivileges(_ command: String, operationID: String? = nil) -> (Bool, String) {
        let op = operationID ?? "none"
        // P-INST-51: admin 权限执行耗时（NSAppleScript with administrator privileges，admin 对话框可秒级阻塞用户输入；attemptScriptingAdditionRecovery P-INST-34 总耗时含此，此埋点归因 admin 等待）。
        let adminStart = Date()
        defer {
            log("[SpaceController] executeWithAdminPrivileges finished", level: .debug, fields: [
                "op": op,
                "durationMs": String(elapsedMilliseconds(since: adminStart))
            ])
        }
        // 转义命令中的双引号和反斜杠，防止 AppleScript 注入
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let scriptSource = "do shell script \"\(escapedCommand)\" with administrator privileges"
        let appleScript = NSAppleScript(source: scriptSource)

        log(
            "[SpaceController] requesting admin privileges",
            fields: [
                "op": op,
                "command": truncateForLog(command, limit: 120)
            ]
        )

        var errorDict: NSDictionary?
        let result = appleScript?.executeAndReturnError(&errorDict)

        if let errorDict {
            let errorMessage = (errorDict[NSAppleScript.errorMessage] as? String) ?? "unknown error"
            let errorNumber = errorDict[NSAppleScript.errorNumber] as? Int ?? -1
            log(
                "[SpaceController] admin privilege execution failed",
                level: .error,
                fields: [
                    "op": op,
                    "command": truncateForLog(command, limit: 120),
                    "errorMessage": errorMessage,
                    "errorNumber": String(errorNumber)
                ]
            )
            return (false, errorMessage)
        }

        let output = result?.stringValue ?? ""
        log(
            "[SpaceController] admin privilege execution succeeded",
            fields: [
                "op": op,
                "command": truncateForLog(command, limit: 120),
                "output": truncateForLog(output, limit: 120)
            ]
        )
        return (true, output)
    }

    func locateYabai() -> String? {
        return YabaiClient.yabaiPath()
    }
}
