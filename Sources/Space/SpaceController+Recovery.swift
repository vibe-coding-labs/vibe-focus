import AppKit
import Foundation

@MainActor
extension SpaceController {

    func requestScriptingAdditionLoad() {
        let op = makeOperationID(prefix: "sa-load")
        // P-INST-207: 手动 SA 加载请求耗时（UserDefaults.standard.removeObject CFPreferences 写 + attemptScriptingAdditionRecovery fork + refreshAvailability；设置面板用户按钮触发）。
        #if PERF_INSTRUMENT
        let rsalStart = Date()
        defer {
            log("[SpaceController] requestScriptingAdditionLoad finished", fields: ["op": op, "durationMs": String(elapsedMilliseconds(since: rsalStart))])
        }
        #endif
        log(
            "[SpaceController] manual scripting-addition load requested",
            fields: ["op": op]
        )
        // 重置恢复标记，允许重新尝试
        didAttemptScriptingAdditionRecovery = false
        scriptingAdditionRecoverySucceeded = false
        // 清除持久化失败缓存，否则 24 小时内手动按钮也会被阻断
        UserDefaults.standard.removeObject(forKey: "scriptingAdditionRecoveryFailedAt")
        // 手动触发：同步等待提权弹框（用户主动行为，等弹框是预期交互）
        _ = attemptScriptingAdditionRecovery(trigger: "manual", operationID: op, adminWaitsForUser: true)
        // 加载成功后刷新可用性
        if scriptingAdditionRecoverySucceeded {
            refreshAvailability(force: true)
        }
    }

    /// SA 是否可用——以「无副作用探针」实测，不靠 query 字段推测。
    ///
    /// ## 为什么重写（2026-09-02，restore 专项 E2E 实测发现）
    /// 旧判据「query --windows --window 含 display 字段」在 yabai v7 上**恒真**：
    /// v7 的 query 走 CGS 内部通道，display/space 字段不依赖 SA。后果链：
    /// SA 未加载时 canControlSpaces 误报可用 → focusSpace/4-pre 直切层每次真实执行、
    /// 每次撞 "error with the scripting-addition" → 视角守卫永远走降级层 + 空转 fork。
    /// 新探针：对**当前已聚焦的 space** 发 `space --focus`——SA 已加载时是逻辑空操作
    /// （"cannot focus an already focused space"，无状态变化），未加载时 stderr 报
    /// scripting-addition，Mission Control 活跃时报 mission-control（此时 space 切换
    /// 本就不可用，按不可用如实上报）。裁决纯函数 saProbeVerdict 分支穷尽锁定。
    func checkScriptingAdditionLoaded(yabaiPath: String) -> Bool {
        // P-INST-35: SA 检查耗时（两次 fork：query --spaces --space + 探针；availability 路径，启动 + 节流刷新时调用）。
        let csaStart = Date()
        var csaResult = "failed_to_run"
        defer {
            log("[SpaceController] checkScriptingAdditionLoaded finished", fields: [
                "result": csaResult,
                "durationMs": String(elapsedMilliseconds(since: csaStart))
            ])
        }
        guard let current = queryFocusedSpace(), let probeIndex = current.index else {
            csaResult = "no_focused_space"
            log("checkScriptingAdditionLoaded: cannot resolve focused space for probe", level: .debug)
            return false
        }
        guard let result = runProcess(executable: yabaiPath, arguments: ["-m", "space", "--focus", "\(probeIndex)"]) else {
            csaResult = "failed_to_run"
            log("checkScriptingAdditionLoaded: probe failed to launch", level: .warn)
            return false
        }
        let loaded = Self.saProbeVerdict(exitCode: result.exitCode, stderr: result.stderr)
        csaResult = loaded ? "loaded" : "unavailable"
        log("checkScriptingAdditionLoaded: probe exit=\(result.exitCode) loaded=\(loaded) stderr=\(result.stderr.prefix(100))", level: .debug)
        return loaded
    }

    /// SA 探针裁决（纯函数，SAProbeVerdictTests 分支穷尽锁定）。
    ///
    /// - exit 0：命令成功执行，SA 必在；
    /// - stderr 分类为 scriptingAdditionMissing：SA 未加载（探针的本职信号）；
    /// - stderr 分类为 missionControlBlocking：MC 期间 space 切换本就不可用，按不可用如实上报；
    /// - 其余（"cannot focus an already focused space" 等逻辑错误/空输出）：SA 可用。
    static func saProbeVerdict(exitCode: Int32, stderr: String) -> Bool {
        if exitCode == 0 { return true }
        let kind = YabaiErrorClassifier.classify(stderr: stderr)
        return kind != .scriptingAdditionMissing && kind != .missionControlBlocking
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

    func attemptScriptingAdditionRecovery(trigger: String, operationID: String? = nil, adminWaitsForUser: Bool = false) -> Bool {
        let op = operationID ?? "none"
        // P-INST-34: recovery 总耗时（yabai --load-sa fork + 可能的 admin 权限对话框，发生时可能秒级；偶发，result 见各路径 log 用 op 关联，归因 runYabaiVariants durationMs 中 recovery vs fork）。
        #if PERF_INSTRUMENT
        let recoveryStart = Date()
        defer {
            log("[SpaceController] scripting-addition recovery finished", fields: [
                "op": op, "trigger": trigger,
                "durationMs": String(elapsedMilliseconds(since: recoveryStart))
            ])
        }
        #endif
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

        // 使用 macOS 原生密码对话框请求管理员权限加载 scripting-addition。
        // 两种模式（2026-09-03 防卡死整改）：
        // - adminWaitsForUser=true（设置面板手动按钮）：同步弹框等待——用户主动触发，
        //   等弹框是预期交互，完成后立即刷新可用性；
        // - false（hook/热键路径自动恢复）：提权挪后台队列执行，本调用立即 return
        //   false 如实走降级通道——历史上同步弹框会无限期挂住 toggle 热键（用户不响应
        //   授权框则窗口操作整段卡死，SecurityAgent 实测挂起）。后台完成后经主队列
        //   收敛状态，下次操作即享 SA 直切。
        let adminCommand = "\(yabaiPath) --load-sa"
        if !adminWaitsForUser {
            log(
                "[SpaceController] scripting-addition recovery: admin prompt deferred to background",
                fields: ["op": op]
            )
            scheduleBackgroundAdminRecovery(command: adminCommand, operationID: op)
            return false
        }

        let (privSuccess, privOutput) = executeWithAdminPrivileges(
            adminCommand,
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
        #if PERF_INSTRUMENT
        let adminStart = Date()
        defer {
            log("[SpaceController] executeWithAdminPrivileges finished", level: .debug, fields: [
                "op": op,
                "durationMs": String(elapsedMilliseconds(since: adminStart))
            ])
        }
        #endif
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

    /// 后台提权恢复（adminWaitsForUser=false 的执行半区）：utility 队列跑 osascript
    /// （NSAppleScript 需主线程，进程方式天然线程安全；密码弹框阻塞的是后台线程），
    /// 完成后经主队列收敛状态。判定与状态迁移与同步路径逐字对齐。
    private func scheduleBackgroundAdminRecovery(command: String, operationID: String) {
        // 转义同 executeWithAdminPrivileges（防 AppleScript 注入）
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escapedCommand)\" with administrator privileges"
        DispatchQueue.global(qos: .utility).async {
            let output: String
            let success: Bool
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                success = process.terminationStatus == 0
                output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            } catch {
                success = false
                output = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.finishBackgroundAdminRecovery(success: success, output: output, operationID: operationID)
            }
        }
    }

    /// 后台提权完成的状态收敛（主队列）。成功/失败的状态迁移与同步路径
    /// （attemptScriptingAdditionRecovery 的 admin 分支）逐字对齐。
    private func finishBackgroundAdminRecovery(success: Bool, output: String, operationID: String) {
        if success {
            scriptingAdditionRecoverySucceeded = true
            canControlSpaces = true
            lastErrorMessage = nil
            log(
                "[SpaceController] scripting-addition recovered via admin privileges (background)",
                fields: [
                    "op": operationID,
                    "output": truncateForLog(output, limit: 120)
                ]
            )
            refreshAvailability(force: true)
            return
        }
        log(
            "[SpaceController] scripting-addition recovery failed: admin privilege dialog cancelled or error (background)",
            level: .error,
            fields: [
                "op": operationID,
                "detail": truncateForLog(output, limit: 220)
            ]
        )
        // 持久化记录失败，避免每次重启都弹管理员权限窗口（24 小时后过期重试）
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "scriptingAdditionRecoveryFailedAt")
        lastErrorMessage = "跨工作区恢复需要管理员权限来加载 yabai scripting-addition。可以在设置中点击\"加载\"按钮手动触发。"
    }

    func locateYabai() -> String? {
        return YabaiClient.yabaiPath()
    }
}
