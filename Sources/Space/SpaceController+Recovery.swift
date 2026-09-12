import AppKit
import Foundation

// SA（yabai scripting-addition）恢复编排（2026-09-08 B52 按域拆分，行为不变）：
//   +Recovery.swift（本文件）—— 手动入口 / 无副作用探针 / 静默直载 / 提权恢复编排
//   +SARecoveryState.swift    —— 结局分类 + 退避策略（纯函数）+ 持久化 + 用户可见状态收敛
//   +SARecoveryAdmin.swift    —— AppleScript 模板 + 前台/后台提权执行半区
// 纯决策（saProbeVerdict/recoveryVerdict/autoRecoveryAllowed/makeAdminShellScript）
// 均由 Runner 直测分支穷尽锁定。

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
    nonisolated func checkScriptingAdditionLoaded(yabaiPath: String) -> Bool {
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
    nonisolated static func saProbeVerdict(exitCode: Int32, stderr: String) -> Bool {
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

    nonisolated func locateYabai() -> String? {
        return YabaiClient.yabaiPath()
    }
}
