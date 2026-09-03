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
        // 状态机闸门前置：blockedBySIP / 退避期内不再空跑 direct --load-sa
        // （availability 刷新高频调用，每次 30ms fork 且注定失败）。
        let (prior, hoursSince) = loadRecoveryState()
        if let verdict = prior, !Self.autoRecoveryAllowed(verdict: verdict, hoursSince: hoursSince) {
            log("[SpaceController] attemptSilentSARecovery skipped by state machine", level: .debug, fields: [
                "verdict": verdict.rawValue,
                "hoursSince": String(format: "%.1f", hoursSince)
            ])
            return
        }
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
        let directResult = runProcess(executable: yabaiPath, arguments: ["--load-sa"])
        if let direct = directResult, direct.exitCode == 0 {
            ssrResult = "loaded"
            scriptingAdditionRecoverySucceeded = true
            canControlSpaces = true
            lastErrorMessage = nil
            recordRecoveryState(.succeeded, op: "silent", output: "direct --load-sa")
            log("attemptSilentSARecovery: scripting-addition loaded successfully via direct --load-sa")
            updateEnabledState()
        } else {
            let failureDetail = directResult?.stderr ?? "failed to run"
            ssrResult = "failed: \(truncateForLog(failureDetail, limit: 120))"
            // SIP 阻止是确定性永久失败（用户授权也无法加载）：立即持久化 blockedBySIP，
            // 状态机此后永久拦截 direct 与 admin 两条自动路径，不再重复打扰。
            // 历史注（2026-09-04"重复授权"根因）：此处旧行为是清除失败缓存 + 重置进程内
            // didAttempt 标志——availability 高频刷新每次失败都把弹框链重新解锁，用户
            // 授权一次（被 SIP 拒）后又被反复要求授权。现改为：仅 blockedBySIP 持久化；
            // 其他失败（如未配 sudoers）不动持久化、也不重置 didAttempt（授权出口收敛
            // 到设置面板手动按钮），状态机闸门从此只被真实结局更新。
            let verdict = Self.recoveryVerdict(success: false, outputOrError: failureDetail)
            if verdict == .blockedBySIP {
                recordRecoveryState(.blockedBySIP, op: "silent", output: failureDetail)
            } else {
                // 非 SIP 失败（多见为未配置 sudoers 免密）：不写持久化 verdict——
                // 弱失败信号不覆盖既有判定（防降级见 recordRecoveryState），授权
                // 出口收敛到设置面板手动按钮；进程内 didAttempt 保持已尝试状态，
                // 避免高频 availability 刷新反复解锁弹框链。
            }
            log("attemptSilentSARecovery: direct --load-sa failed, user needs to load manually")
        }
    }

    // MARK: - SA 恢复状态机（2026-09-03 全场景自适应重构）

    /// SA 恢复结局分类（纯函数，Runner 分支穷尽锁定）。
    enum SARecoveryVerdict: String, Equatable {
        /// load-sa 成功（SA 已注入 WindowServer）
        case succeeded
        /// SIP 阻止（错误信息含 "System Integrity Protection"）——该机器上永久不可加载，
        /// 自动恢复永不重试，设置面板常驻原因与启用指引
        case blockedBySIP
        /// 用户在授权框点取消/关闭——7 天退避后允许再次询问
        case userDeclined
        /// 其他瞬时失败（yabai 缺失/系统更新后布局变化等）——24 小时退避自愈
        case failedOther
    }

    /// 恢复结局裁决（纯函数）。success=true 一律 succeeded；失败按错误文本分类：
    /// yabai 的 SIP 拒载错误与 osascript 的用户取消（-128）有稳定可辨文本。
    static func recoveryVerdict(success: Bool, outputOrError: String) -> SARecoveryVerdict {
        if success { return .succeeded }
        if outputOrError.contains("System Integrity Protection") { return .blockedBySIP }
        if outputOrError.lowercased().contains("user canceled") { return .userDeclined }
        return .failedOther
    }

    /// 自动恢复再尝试策略（纯函数，hoursSince = 距上次该结局的小时数）：
    /// - blockedBySIP：永不自动重试（SIP 限制不随时间变化，重试=重复打扰）；
    /// - userDeclined：7×24 小时（用户明确说不，给足冷静期）；
    /// - failedOther：24 小时（瞬时失败自愈，覆盖系统更新后失效场景）；
    /// - succeeded：无需恢复。
    static func autoRecoveryAllowed(verdict: SARecoveryVerdict, hoursSince: TimeInterval) -> Bool {
        switch verdict {
        case .blockedBySIP: return false
        case .succeeded: return false
        case .userDeclined: return hoursSince >= 7 * 24
        case .failedOther: return hoursSince >= 24
        }
    }

    private static let saVerdictKey = "saRecoveryVerdict"
    private static let saVerdictAtKey = "saRecoveryVerdictAt"
    private static let legacyFailedAtKey = "scriptingAdditionRecoveryFailedAt"

    /// 读持久化恢复状态（含旧版单一失败时间戳的迁移：视为 failedOther）。
    private func loadRecoveryState() -> (verdict: SARecoveryVerdict?, hoursSince: TimeInterval) {
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        if let raw = defaults.string(forKey: Self.saVerdictKey),
           let verdict = SARecoveryVerdict(rawValue: raw) {
            let at = defaults.double(forKey: Self.saVerdictAtKey)
            guard at > 0 else { return (verdict, TimeInterval.greatestFiniteMagnitude) }
            return (verdict, max(0, now - at))
        }
        // 旧版迁移：legacy 失败时间戳 → failedOther（24h 语义与旧行为一致）
        let legacy = defaults.double(forKey: Self.legacyFailedAtKey)
        if legacy > 0 {
            defaults.removeObject(forKey: Self.legacyFailedAtKey)
            return (.failedOther, max(0, now - legacy))
        }
        return (nil, 0)
    }

    /// 持久化恢复结局并按场景更新用户可见状态（主队列调用）。
    /// 防降级：blockedBySIP 是系统属性判定（SIP 不随时间变化），不被更弱的
    /// failedOther 覆盖——否则 silent 弱失败会把永久静默洗回 24h 弹框窗口
    /// （2026-09-04"永久授权"诉求的关键保障）。
    private func recordRecoveryState(_ verdict: SARecoveryVerdict, op: String, output: String) {
        let defaults = UserDefaults.standard
        if verdict == .failedOther,
           defaults.string(forKey: Self.saVerdictKey) == SARecoveryVerdict.blockedBySIP.rawValue {
            defaults.set(Date().timeIntervalSince1970, forKey: Self.saVerdictAtKey)
            return
        }
        defaults.set(verdict.rawValue, forKey: Self.saVerdictKey)
        defaults.set(Date().timeIntervalSince1970, forKey: Self.saVerdictAtKey)
        defaults.removeObject(forKey: Self.legacyFailedAtKey)
        switch verdict {
        case .succeeded:
            scriptingAdditionRecoverySucceeded = true
            canControlSpaces = true
            lastErrorMessage = nil
            log("[SpaceController] scripting-addition recovered", fields: [
                "op": op, "verdict": verdict.rawValue,
                "output": truncateForLog(output, limit: 120)
            ])
        case .blockedBySIP:
            scriptingAdditionRecoverySucceeded = false
            lastErrorMessage = "scripting-addition 被系统 SIP 阻止（需要关闭 Filesystem Protections 与 Debugging Restrictions 两项后才能加载）。自动恢复已停止打扰；跨工作区恢复走降级通道，不影响基本功能。若需要 15ms 直切：进恢复模式执行 csrutil enable --without debug --without fs 后，回到本页点「加载」。"
            log("[SpaceController] scripting-addition recovery blocked by SIP (auto retry disabled)", level: .error, fields: [
                "op": op, "detail": truncateForLog(output, limit: 220)
            ])
        case .userDeclined:
            scriptingAdditionRecoverySucceeded = false
            lastErrorMessage = "已取消 scripting-addition 授权（7 天内不会再次询问）。跨工作区恢复走降级通道；需要时点击「加载」按钮重新授权。"
            log("[SpaceController] scripting-addition recovery declined by user (7d backoff)", level: .warn, fields: ["op": op])
        case .failedOther:
            scriptingAdditionRecoverySucceeded = false
            lastErrorMessage = "跨工作区恢复需要管理员权限来加载 yabai scripting-addition。可以在设置中点击\"加载\"按钮手动触发。"
            log("[SpaceController] scripting-addition recovery failed (24h backoff)", level: .error, fields: [
                "op": op, "detail": truncateForLog(output, limit: 220)
            ])
        }
    }

    func attemptScriptingAdditionRecovery(trigger: String, operationID: String? = nil, adminWaitsForUser: Bool = false) -> Bool {
        let op = operationID ?? "none"
        #if PERF_INSTRUMENT
        let recoveryStart = Date()
        defer {
            log("[SpaceController] scripting-addition recovery finished", fields: [
                "op": op, "trigger": trigger,
                "durationMs": String(elapsedMilliseconds(since: recoveryStart))
            ])
        }
        #endif
        // 进程周期内只尝试一次（后台恢复完成会更新 scriptingAdditionRecoverySucceeded）
        if didAttemptScriptingAdditionRecovery {
            return scriptingAdditionRecoverySucceeded
        }

        // 持久化状态机：blockedBySIP 永不自动打扰 / userDeclined 7 天 / failedOther 24 小时。
        // 手动按钮（adminWaitsForUser=true）无视退避——用户主动触发总是尝试。
        if !adminWaitsForUser {
            let (prior, hoursSince) = loadRecoveryState()
            if let verdict = prior, !Self.autoRecoveryAllowed(verdict: verdict, hoursSince: hoursSince) {
                log("[SpaceController] scripting-addition recovery skipped by state machine", level: .warn, fields: [
                    "op": op, "trigger": trigger,
                    "verdict": verdict.rawValue,
                    "hoursSince": String(format: "%.1f", hoursSince)
                ])
                didAttemptScriptingAdditionRecovery = true
                scriptingAdditionRecoverySucceeded = (verdict == .succeeded)
                return scriptingAdditionRecoverySucceeded
            }
        }
        didAttemptScriptingAdditionRecovery = true

        guard let yabaiPath = locateYabai() else {
            recordRecoveryState(.failedOther, op: op, output: "yabai path missing")
            log("[SpaceController] scripting-addition recovery skipped: yabai path missing", level: .error, fields: [
                "op": op, "trigger": trigger
            ])
            return false
        }

        log("[SpaceController] attempting scripting-addition recovery", fields: [
            "op": op, "trigger": trigger
        ])

        // 第一段：静默直载（sudoers 免密配置好后此路常成，无对话框）
        if let direct = runProcess(executable: yabaiPath, arguments: ["--load-sa"]), direct.exitCode == 0 {
            recordRecoveryState(.succeeded, op: op, output: "direct --load-sa")
            return true
        }

        // 第二段：管理员提权加载。
        // - adminWaitsForUser=true（设置面板手动按钮）：同步弹框——用户主动触发，等待是预期交互；
        // - false（hook/热键自动恢复）：提权挪后台队列，本调用立即 return false 如实走降级——
        //   历史同步弹框曾无限期挂住热键（SecurityAgent 挂起实测）。完成经主队列按 verdict 收敛。
        let adminCommand = "\(yabaiPath) --load-sa"
        if !adminWaitsForUser {
            log("[SpaceController] scripting-addition recovery: admin prompt deferred to background", fields: ["op": op])
            scheduleBackgroundAdminRecovery(command: adminCommand, operationID: op)
            return false
        }

        let (privSuccess, privOutput) = executeWithAdminPrivileges(adminCommand, operationID: op)
        let verdict = Self.recoveryVerdict(success: privSuccess, outputOrError: privOutput)
        recordRecoveryState(verdict, op: op, output: privOutput)
        if case .succeeded = verdict {
            return true
        }
        return false
    }

    func executeWithAdminPrivileges(_ command: String, operationID: String? = nil) -> (Bool, String) {
        let op = operationID ?? "none"
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

    /// 后台提权恢复（自动路径的执行半区）：utility 队列跑 osascript
    /// （NSAppleScript 需主线程，进程方式天然线程安全；密码弹框阻塞的是后台线程），
    /// 完成后按 verdict 经主队列收敛状态。
    private func scheduleBackgroundAdminRecovery(command: String, operationID: String) {
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
                let verdict = SpaceController.recoveryVerdict(success: success, outputOrError: output)
                self.recordRecoveryState(verdict, op: operationID, output: output)
            }
        }
    }

    func locateYabai() -> String? {
        return YabaiClient.yabaiPath()
    }
}
