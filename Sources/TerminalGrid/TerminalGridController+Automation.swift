import AppKit
import CoreGraphics
import Foundation

// MARK: - 终端网格 · AppleScript 建窗与自动化通道（2026-09-07 从 TerminalGridController 拆分，行为不变）

extension TerminalGridController {

    func runScript(_ script: String) async -> YabaiClient.YabaiResult? {
        let result = await Task.detached(priority: .userInitiated) {
            // 30s：建窗脚本含等窗轮询 + 多窗环境下 AppleScript 枚举，远超 ShellRunner
            // 默认 2s（为 yabai 短命令设计）；超时会掐死半执行脚本泄漏孤儿窗（真机实证）。
            ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", script], timeout: 30)
        }.value
        // 每次调用都重写：lastScriptError 恒反映最近一次脚本调用的真实结果，
        // 不携带历史操作的陈旧错误（跨操作串味会把排查引向假线索）。
        lastScriptError = TerminalAutomationScript.describeScriptFailure(result)
        return result
    }

    /// 实例环境守卫的运行时采集：NSWorkspace 枚举该 bundleID 的全部运行实例。
    /// 返回 nil = 放行；非 nil = 用户可读的拒绝原因（同时写入 lastScriptError
    /// 供失败消息带走）。
    /// - Parameter allowNotRunning: 开机自动恢复靠 AppleEvent 冷拉起未运行的终端
    ///   （既有行为），传 true 保留该路径；手动操作传 false，未运行直接诚实拒绝。
    func automationInstanceRefusal(appBundleID: String, allowNotRunning: Bool = false) -> String? {
        let instances = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == appBundleID }
            .map { (pid: pid_t($0.processIdentifier), executablePath: $0.executableURL?.path) }
        let verdict = TerminalAutomationScript.automationInstanceVerdict(instances: instances)
        if case .notRunning = verdict, allowNotRunning {
            return nil
        }
        if verdict != .clean {
            log("[TerminalGrid] automation instance guard", level: .warn, fields: [
                "bundleID": appBundleID,
                "instances": String(instances.count),
                "verdict": String(describing: verdict)
            ])
        }
        let appName = TerminalSelectionResolver.knownNames[appBundleID] ?? appBundleID
        return TerminalAutomationScript.instanceGuardFailureMessage(for: verdict, appName: appName)
    }

    /// 建一个终端窗口并确保落到目标格子：
    /// 0) 实例环境守卫（每次尝试前都验：E2E 临时副本可能在网格中途生灭）+ 瞬时
    ///    故障退避重试（挂起类故障如 TCC 授权框不重试——30s 超时后快速失败）；
    /// 1) AppleScript 建窗 + set bounds（Terminal 的 bounds 是"窗口当前屏局部坐标"
    ///    语义，真机实证跨屏必漂移）；
    /// 2) 读回 bounds 校验，漂移 >10px 走 WindowManager.placeWindow（float 脱管 +
    ///    yabai frame 直写）纠偏——与主流程跨屏写同一引擎。
    func createTerminalCell(
        appBundleID: String,
        command: String?,
        frame: CGRect,
        op: String
    ) async -> (cgWindowID: UInt32?, corrected: Bool) {
        let isIterm = TerminalAutomationScript.usesITermDialect(appBundleID)
        let script = isIterm
            ? TerminalAutomationScript.itermCreateWindow(command: command, quartzFrame: frame)
            : TerminalAutomationScript.terminalCreateWindow(command: command, quartzFrame: frame)

        var created: YabaiClient.YabaiResult?
        var failedAttempts = 0
        while created == nil {
            if let refusal = automationInstanceRefusal(appBundleID: appBundleID) {
                lastScriptError = refusal
                return (nil, false)
            }
            let result = await runScript(script)
            if let result, result.exitCode == 0 {
                created = result
                break
            }
            // 挂起类故障（未启动 / 30s 超时）：重试只会翻倍等待，快速失败
            guard result != nil else {
                return (nil, false)
            }
            failedAttempts += 1
            guard failedAttempts < TerminalAutomationScript.maxCellCreateAttempts else {
                return (nil, false)
            }
            let delay = TerminalAutomationScript.cellCreateRetryDelayNanos(failedAttempts: failedAttempts)
            log("[TerminalGrid] cell create failed, retrying", level: .warn, fields: [
                "op": op,
                "attempt": String(failedAttempts),
                "retryInMs": String(delay / 1_000_000),
                "detail": lastScriptError ?? "-"
            ])
            try? await Task.sleep(nanoseconds: delay)
        }
        guard let result = created else { return (nil, false) }
        let appleScriptID = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try? await Task.sleep(nanoseconds: Self.interWindowDelayNanos)

        let boundsScript = isIterm
            ? TerminalAutomationScript.itermGetBounds(windowID: appleScriptID)
            : TerminalAutomationScript.terminalGetBounds(windowID: UInt32(appleScriptID) ?? 0)
        let readback = (await runScript(boundsScript))
            .flatMap { TerminalAutomationScript.parseBounds($0.stdout) }

        // CG window id：Terminal 的 AppleScript id == CGWindowNumber；iTerm2 按落点 bounds 就近匹配
        var cgID: UInt32?
        if !isIterm, let id = UInt32(appleScriptID) {
            cgID = id
        } else {
            cgID = cgWindowID(forBundleID: appBundleID, nearBounds: readback)
        }

        let converged = readback.map { CoordinateKit.isFrameConverged(actual: $0, target: frame, tolerance: 10) } ?? false
        if converged {
            return (cgID, false)
        }
        guard let cgID else {
            lastScriptError = "窗口已创建但无法在 CG 窗口列表定位（bounds 回读失败或就近匹配超差）——窗口可能落在了不可见空间或其它实例"
            return (nil, false)
        }
        log("[TerminalGrid] cell placement drifted, correcting via yabai", fields: [
            "op": op,
            "windowID": String(cgID),
            "readback": readback.map { "\($0.origin.x),\($0.origin.y),\($0.width)x\($0.height)" } ?? "nil"
        ])
        let corrected = WindowManager.shared.placeWindow(windowID: cgID, frame: frame, operationID: op)
        return (cgID, corrected)
    }

    /// 按 bundleID + 就近 bounds 找 CG window id（iTerm2 的 AppleScript id 不是 CGWindowNumber）
    private func cgWindowID(forBundleID bundleID: String, nearBounds bounds: CGRect?) -> UInt32? {
        let entries = cgWindowListAll().filter { entry in
            entry.layer == 0 && entry.isOnScreen && entry.bounds != nil
                && bundleIdentifier(ofPID: entry.ownerPID) == bundleID
        }
        guard let bounds else {
            return entries.first?.windowID
        }
        var best: (id: UInt32, distance: CGFloat)?
        for entry in entries {
            let b = entry.bounds!
            let d = hypot(b.midX - bounds.midX, b.midY - bounds.midY)
            if best == nil || d < best!.distance {
                best = (entry.windowID, d)
            }
        }
        guard let best, best.distance < 40 else { return nil }
        return best.id
    }

    /// Terminal.app 全量 windowID→tty 映射
    func terminalWindowTTYMap() async -> [UInt32: String] {
        guard let result = await runScript(TerminalAutomationScript.terminalEnumerateWindowTTYs()),
              result.exitCode == 0 else {
            return [:]
        }
        return TerminalAutomationScript.parseWindowTTYMap(result.stdout)
    }

}
