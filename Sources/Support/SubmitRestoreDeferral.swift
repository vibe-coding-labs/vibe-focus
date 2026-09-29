import Foundation

// Sources/Support/SubmitRestoreDeferral.swift — 提交归位「失焦延迟」注册表（0.0.92，第五次收敛）。
//
// ## 为什么存在（2026-09-29 晚用户主诉）
// 0.0.91 语义 = 提交瞬间立即归位（来源无关）。当晚日志实锤 39 次/小时
// 「回车即被拽回副屏」——提交那一刻窗口必然持有键盘焦点（用户刚回车），立即
// 执行 = 正在读回复/准备续输时窗从主屏被拽走，用户裁决「完全没有办法正常使用」。
//
// ## 语义
// 提交（气泡/UPS）不再立即执行 restore，只登记 pending；1s 节拍探测目标窗
// has-focus：**连续失焦 ≥ blurGraceSeconds** → 复核资格门（记录还在/时效/已在
// 原位，AutoRestoreRecordGate）后经 ToggleEngine.restore 真正归位；重新聚焦只是
// 重置计时（用户回来继续用，窗留在主屏；下次提交刷新登记）。「回车后窗回副屏」
// 的承诺推迟到用户放手后兑现——9-28「别在干活时拽走」与 9-29 凌晨「提交后要
// 归位」两代裁决同时成立；⌃Q 手动 toggle 随时可提前送回（届时记录被消费/清理，
// 本注册表执行点复核后自然空转丢弃）。
//
// ## 钟摆史追加（全量取证 docs/log-audit-2026-09-29.md，供后续会话理解）
// B126(9-11 userPlacedSkip) → 65a1ad2(9-16 有记录即归位) → 0.0.90(9-28 手动粘滞，
// 实测回归拦掉 9 次归位) → 0.0.91(9-29 凌晨来源无关+时效+短路，提交瞬间归位)
// → **0.0.92(本版：失焦归位——保留 0.0.91 的来源无关与三门，把执行时机从
// 「提交瞬间」移到「连续失焦 ≥10s」)**。
//
// 并发注记：整类 @MainActor（arm 来自 HookEventHandler/气泡提交链，节拍走主
// RunLoop/Task@MainActor；焦点探测经 Task.detached 离轴，回主线程后才碰状态）。
@MainActor
final class SubmitRestoreDeferral {
    static let shared = SubmitRestoreDeferral()

    /// 连续失焦宽限（秒）：盖过 alt-tab 一瞥（用户查资料即回），仍算及时归位。
    static let blurGraceSeconds: TimeInterval = 10
    /// 节拍间隔（秒）。
    static let evaluationInterval: TimeInterval = 1.0

    struct Pending: Sendable, Equatable {
        let windowID: UInt32
        let triggerSource: String
        /// UPS 通道携带（归位成功后 reactivate）；气泡通道为 nil。
        let sessionID: String?
        /// 登记（或最近一次刷新）时刻 = 失焦计时原点（直到首次观察到失焦）。
        let armedAt: Date
        /// 最近一次观察到持有焦点的时刻；nil = 自登记起未见焦点回环。
        var lastFocusedAt: Date?
    }

    /// 单拍裁决（纯函数，Runner 直测穷尽锁定）。
    enum BlurDecision: Equatable {
        case resetClock
        case keepWaiting(blurSeconds: TimeInterval)
        case fire(blurSeconds: TimeInterval)
    }

    static func evaluateBlur(
        lastFocusedAt: Date?,
        armedAt: Date,
        isFocused: Bool,
        now: Date,
        graceSeconds: TimeInterval
    ) -> BlurDecision {
        if isFocused { return .resetClock }
        let blurOrigin = lastFocusedAt ?? armedAt
        let blurSeconds = now.timeIntervalSince(blurOrigin)
        return blurSeconds >= graceSeconds ? .fire(blurSeconds: blurSeconds) : .keepWaiting(blurSeconds: blurSeconds)
    }

    private var pending: [UInt32: Pending] = [:]
    private var timer: Timer?

    /// 可注入时钟，测试用；生产恒为系统当前时间。
    var now: () -> Date = { Date() }
    /// 焦点探测缝（生产 = 后台 yabai queryWindow has-focus；Runner 注入表驱动）。
    /// nil = 探测不到（yabai 不可用/窗已消失）——**保守视为仍持焦不计时**：
    /// 探测通道失灵时宁可窗多留主屏（⌃Q 可手动送回），不可在用户打字时误判失焦拽窗。
    var focusProbe: (UInt32) async -> Bool? = { windowID in
        await Task.detached(priority: .utility) {
            SpaceController.shared.queryWindow(windowID: windowID)?.hasFocus
        }.value
    }
    /// 执行缝（生产 = 资格门复核 + WindowWorkExecutor restore；Runner 注入记录器）。
    var fireHandler: (Pending) -> Void = { SubmitRestoreDeferral.shared.executePending($0) }
    /// Runner 内不启 Timer（CLI 进程主 RunLoop 不跑，防泄漏）。
    var schedulingEnabled = true

    /// internal（非 private）：Runner 测试注入独立实例（RestoreInFlightRegistry 同款）。
    init() {}

    // MARK: - 登记

    /// 登记（幂等刷新）：同窗重复提交刷新 armedAt（重置失焦计时），不叠加。
    /// UPS 常先于气泡收尾到达——先登记者携带的 sessionID 不被无会话通道
    /// （气泡 sessionID=nil）覆盖，执行点 reactivate 凭证不丢。
    func arm(windowID: UInt32, triggerSource: String, sessionID: String?) {
        let existingSessionID = pending[windowID]?.sessionID
        let armedAt = now()
        pending[windowID] = Pending(
            windowID: windowID,
            triggerSource: triggerSource,
            sessionID: sessionID ?? existingSessionID,
            armedAt: armedAt,
            lastFocusedAt: nil
        )
        log("[SubmitRestoreDeferral] armed", fields: [
            "windowID": String(windowID),
            "triggerSource": triggerSource,
            "sessionID": pending[windowID]?.sessionID ?? "nil",
            "graceSeconds": String(Self.blurGraceSeconds),
            "pendingCount": String(pending.count)
        ])
        if schedulingEnabled { ensureTimer() }
    }

    /// 撤销登记（⌃Q 手动路径经记录消费自然失效，无需显式调；测试/诊断用）。
    func cancel(windowID: UInt32) {
        pending.removeValue(forKey: windowID)
    }

    // MARK: - 节拍评估

    /// 生产节拍入口（Timer 主线程触发）：探测各 pending 窗焦点后进同步核心。
    func startBeat() {
        let beatNow = now()
        let ids = Array(pending.keys)
        guard !ids.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            var focusByWindow: [UInt32: Bool] = [:]
            for windowID in ids {
                focusByWindow[windowID] = await self.focusProbe(windowID) ?? true
            }
            self.evaluateBeat(now: beatNow, focusByWindow: focusByWindow)
        }
    }

    /// 同步评估核心（生产由 startBeat 喂探测结果；Runner 直接喂表驱动值）。
    func evaluateBeat(now beatNow: Date, focusByWindow: [UInt32: Bool]) {
        for (windowID, focused) in focusByWindow {
            guard var entry = pending[windowID] else { continue }
            switch Self.evaluateBlur(
                lastFocusedAt: entry.lastFocusedAt, armedAt: entry.armedAt,
                isFocused: focused, now: beatNow, graceSeconds: Self.blurGraceSeconds
            ) {
            case .resetClock:
                entry.lastFocusedAt = beatNow
                pending[windowID] = entry
            case .keepWaiting:
                break
            case .fire(let blurSeconds):
                pending.removeValue(forKey: windowID)
                log("[SubmitRestoreDeferral] firing deferred restore after continuous blur", fields: [
                    "windowID": String(windowID),
                    "triggerSource": entry.triggerSource,
                    "blurSeconds": String(format: "%.1f", blurSeconds),
                    "heldMs": String(Int(beatNow.timeIntervalSince(entry.armedAt) * 1000))
                ])
                fireHandler(entry)
            }
        }
        if pending.isEmpty { stopTimer() }
    }

    // MARK: - 执行（生产 fireHandler）

    /// 失焦到期执行：先复核资格门（登记到失焦之间记录可能被 ⌃Q 手动消费/超时/
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
            let traceID = "blur-\(Int(gateNow.timeIntervalSince1970 * 1000))"
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
            // 登记期间窗已回原帧 = 陈旧记录，仅清理不移动（UPS 侧同语义）。
            if record != nil { ToggleEngine.shared.clear(windowID: p.windowID) }
            log("[SubmitRestoreDeferral] deferred restore dropped: window already at original, cleared stale record", fields: [
                "windowID": String(p.windowID),
                "triggerSource": p.triggerSource
            ])
        case .expired:
            // 持焦超过 30min 时效：不再自动归位，记录保留（⌃Q 手动还原不受影响）。
            log("[SubmitRestoreDeferral] deferred restore dropped: toggle record expired during focus hold", fields: [
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
