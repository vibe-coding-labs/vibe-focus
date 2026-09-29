import Foundation

// Sources/Support/SubmitRestoreDeferral.swift — 提交归位「延迟执行」注册表（0.0.93，第六次收敛）。
//
// ## 语义（开关「提交后自动归位」的承诺 + 唯一保留的输入保护）
// 提交（气泡/UPS）后 **~3 秒**归位：不再要求用户切走焦点（0.0.92 的失焦保持实测
// 违背开关承诺——用户提交后数秒内就要窗回副屏，三次手动 ⌃Q 送回后裁决「提交之后
// 不会自动恢复了」）；也不在提交瞬间执行（0.0.91 及更早：回车即拽走）。
// 唯一的顺延条件 = **该窗的输入气泡正在打开/提交中**（用户已经在写下一条）——
// 此时归位顺延到气泡关闭后的下一个节拍。连续使用（开着气泡连发）窗就留在主屏；
// 停下来 3 秒窗就回家。重复提交刷新计时。
//
// ## 钟摆史（全量取证 docs/log-audit-2026-09-29.md，供后续会话理解，勿单方向推翻）
// B126(9-11 userPlacedSkip) → 65a1ad2(9-16 有记录即归位) → 0.0.90(9-28 手动粘滞，
// 实测回归拦掉 9 次归位) → 0.0.91(9-29 凌晨来源无关+时效+短路，提交瞬间归位，
// 用户主诉「正在输入被拽走」39 次/小时) → 0.0.92(失焦归位，实测违背开关承诺，
// 用户三次手动 ⌃Q 送回后裁决「提交之后不会自动恢复了」) → **0.0.93(本版：延迟
// 3 秒 + 气泡输入中顺延——归位必达，只是让回车的余波先落地；正在打字唯一体现
// 为气泡开着，顺延而非取消)**。
//
// 并发注记：整类 @MainActor（arm 来自 HookEventHandler/气泡提交链，节拍走主
// RunLoop/Task@MainActor）。
@MainActor
final class SubmitRestoreDeferral {
    static let shared = SubmitRestoreDeferral()

    /// 提交到归位的延迟（秒）：让回车注入/claude UPS/剪贴板恢复先落地，又不至于
    /// 让窗在主屏滞留到用户需要手动 ⌃Q。
    static let restoreDelaySeconds: TimeInterval = 3
    /// 节拍间隔（秒）。
    static let evaluationInterval: TimeInterval = 1.0

    struct Pending: Sendable, Equatable {
        let windowID: UInt32
        let triggerSource: String
        /// UPS 通道携带（归位成功后 reactivate）；气泡通道为 nil。
        let sessionID: String?
        /// 登记（或最近一次刷新）时刻 = 归位计时原点。
        let armedAt: Date
    }

    /// 单拍裁决（纯函数，Runner 直测穷尽锁定）。
    enum DelayDecision: Equatable {
        case keepWaiting(remainingSeconds: TimeInterval)
        /// 到点但该窗气泡正在输入 → 顺延（气泡关闭后的下一个节拍即 fire）。
        case postponedBusy
        case fire(elapsedSeconds: TimeInterval)
    }

    static func evaluateDelay(
        armedAt: Date,
        now: Date,
        delaySeconds: TimeInterval,
        isBusy: Bool
    ) -> DelayDecision {
        let elapsed = now.timeIntervalSince(armedAt)
        if elapsed < delaySeconds { return .keepWaiting(remainingSeconds: delaySeconds - elapsed) }
        if isBusy { return .postponedBusy }
        return .fire(elapsedSeconds: elapsed)
    }

    private var pending: [UInt32: Pending] = [:]
    private var timer: Timer?

    /// 可注入时钟，测试用；生产恒为系统当前时间。
    var now: () -> Date = { Date() }
    /// 输入占用探测缝（生产 = 该窗气泡 open/submitting；Runner 注入表驱动）。
    var activityHoldProbe: (UInt32) -> Bool = { windowID in
        InputBubbleController.shared.phase != .idle
            && InputBubbleController.shared.target?.windowID == windowID
    }
    /// 执行缝（生产 = 资格门复核 + WindowWorkExecutor restore；Runner 注入记录器）。
    var fireHandler: (Pending) -> Void = { SubmitRestoreDeferral.shared.executePending($0) }
    /// Runner 内不启 Timer（CLI 进程主 RunLoop 不跑，防泄漏）。
    var schedulingEnabled = true

    /// internal（非 private）：Runner 测试注入独立实例（RestoreInFlightRegistry 同款）。
    init() {}

    // MARK: - 登记

    /// 登记（幂等刷新）：同窗重复提交刷新 armedAt（重新计时），不叠加。
    /// UPS 常先于气泡收尾到达——先登记者携带的 sessionID 不被无会话通道
    /// （气泡 sessionID=nil）覆盖，执行点 reactivate 凭证不丢。
    func arm(windowID: UInt32, triggerSource: String, sessionID: String?) {
        let existingSessionID = pending[windowID]?.sessionID
        let armedAt = now()
        pending[windowID] = Pending(
            windowID: windowID,
            triggerSource: triggerSource,
            sessionID: sessionID ?? existingSessionID,
            armedAt: armedAt
        )
        log("[SubmitRestoreDeferral] armed", fields: [
            "windowID": String(windowID),
            "triggerSource": triggerSource,
            "sessionID": pending[windowID]?.sessionID ?? "nil",
            "delaySeconds": String(Self.restoreDelaySeconds),
            "pendingCount": String(pending.count)
        ])
        if schedulingEnabled { ensureTimer() }
    }

    /// 撤销登记（⌃Q 手动路径经记录消费自然失效，无需显式调；测试/诊断用）。
    func cancel(windowID: UInt32) {
        pending.removeValue(forKey: windowID)
    }

    // MARK: - 节拍评估

    /// 生产节拍入口（Timer 主线程触发）。
    func startBeat() {
        let beatNow = now()
        let ids = Array(pending.keys)
        guard !ids.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.evaluateBeat(now: beatNow)
        }
    }

    /// 同步评估核心（生产由 startBeat 驱动；Runner 直接调）。
    func evaluateBeat(now beatNow: Date) {
        for (windowID, entry) in pending {
            switch Self.evaluateDelay(
                armedAt: entry.armedAt, now: beatNow,
                delaySeconds: Self.restoreDelaySeconds,
                isBusy: activityHoldProbe(windowID)
            ) {
            case .keepWaiting, .postponedBusy:
                break
            case .fire(let elapsed):
                pending.removeValue(forKey: windowID)
                log("[SubmitRestoreDeferral] firing deferred restore", fields: [
                    "windowID": String(windowID),
                    "triggerSource": entry.triggerSource,
                    "elapsedSeconds": String(format: "%.1f", elapsed)
                ])
                fireHandler(entry)
            }
        }
        if pending.isEmpty { stopTimer() }
    }

    // MARK: - 执行（生产 fireHandler）

    /// 到期执行：先复核资格门（登记到执行之间记录可能被 ⌃Q 手动消费/超时/
    /// 窗口已回原位），再经 WindowWorkExecutor 走与提交链同一执行入口。
    func executePending(_ p: Pending) {
        let gateNow = now()
        let record = ToggleEngine.shared.load(windowID: p.windowID)
        let gate = AutoRestoreRecordGate.evaluate(
            record: record,
            now: gateNow,
            currentFrame: record != nil ? cgWindowBounds(for: p.windowID) : nil,
            tolerance: WindowManager.shared.frameTolerance
        )
        switch gate {
        case .eligible:
            RestoreInFlightRegistry.shared.mark(windowID: p.windowID)
            let traceID = "defer-\(Int(gateNow.timeIntervalSince1970 * 1000))"
            let windowID = p.windowID
            let sessionID = p.sessionID
            let triggerSource = p.triggerSource
            Task { @MainActor in
                let outcome = await WindowWorkExecutor.run {
                    ToggleEngine.shared.restore(
                        windowID: windowID,
                        triggerSource: triggerSource,
                        traceID: traceID
                    )
                }
                if case .restored = outcome {
                    if let sessionID {
                        SessionWindowRegistry.shared.reactivate(sessionID: sessionID)
                    }
                    log("[SubmitRestoreDeferral] deferred restore completed", fields: [
                        "windowID": String(windowID),
                        "triggerSource": triggerSource,
                        "traceID": traceID
                    ])
                } else {
                    log("[SubmitRestoreDeferral] deferred restore failed", level: .warn, fields: [
                        "windowID": String(windowID),
                        "triggerSource": triggerSource,
                        "outcome": outcome.outcomeLabel,
                        "traceID": traceID
                    ])
                }
            }
        case .alreadyAtOriginalFrame:
            // 窗已回原帧 = 记录陈旧（⌃Q 手动还原/另一通道已消费未清理），仅清理不移动。
            if record != nil { ToggleEngine.shared.clear(windowID: p.windowID) }
            log("[SubmitRestoreDeferral] deferred restore dropped: window already at original, cleared stale record", fields: [
                "windowID": String(p.windowID),
                "triggerSource": p.triggerSource
            ])
        case .expired:
            // 超 30min 时效：不再自动归位，记录保留（⌃Q 手动还原不受影响）。
            log("[SubmitRestoreDeferral] deferred restore dropped: toggle record expired", fields: [
                "windowID": String(p.windowID),
                "triggerSource": p.triggerSource
            ])
        case .none:
            // 记录已被消费（⌃Q 手动还原成功/另一通道归位）——无事可做。
            log("[SubmitRestoreDeferral] deferred restore dropped: toggle record gone", fields: [
                "windowID": String(p.windowID),
                "triggerSource": p.triggerSource
            ])
        }
    }

    // MARK: - 测试/诊断

    var isEmpty: Bool { pending.isEmpty }
    var pendingWindowIDs: [UInt32] { Array(pending.keys) }
    func pendingEntry(for windowID: UInt32) -> Pending? { pending[windowID] }
    func reset() {
        pending.removeAll()
        stopTimer()
    }

    // MARK: - 私有机械

    private func ensureTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.evaluationInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.startBeat()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
