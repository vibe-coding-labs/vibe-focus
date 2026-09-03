import Foundation
import Cocoa

// MARK: - Restore Logic (Simplified)
//
// Design: 源屏预切回 → float 脱管 → yabai --move/--resize 直写 origFrame → 视角守卫。
// One shot, no retries. The old mechanism had 4 strategies, polling loops, a watchdog,
// and 642 lines to do what these steps accomplish.
//
// 历史注：2026-09-01 起不再用 yabai `window --space`（v7 float 布局下静默失效，
// exit 0 但窗口不动，Tests/AXMoveValidation.swift T3 断言实测）。
// 历史注：2026-09-02 诚实结局重构——此前 frame 写失败仍清 record + 记 restore_success +
// return true：失败被伪装成成功、record 被毁导致无法重试（断显/最小化场景用户按热键
// 毫无反馈）。结局由 RestoreOutcome 唯一定义，record 处置与审计事件随之派生。
// 历史注：2026-09-02 依赖注入化——restore 主体收敛为无实例状态的 performRestore
//（records/windows/channels/auditor 全注入，接缝见 RestoreSwitchOrchestration.swift），
// Tests/Runner 无需真实 yabai/AX/SQLite 即穷尽结局裁决全部分支；生产入口
// restore(windowID:triggerSource:traceID:) 委托并传入四个 .shared 单例。

@MainActor
extension ToggleEngine {

    /// restore 的真实结局（record 处置与审计事件的唯一依据）。
    enum RestoreOutcome: Equatable {
        /// frame 已收敛：窗口回到源屏 origFrame。spaceExact：
        ///   true  = 源屏可见 space 已精确等于 sourceSpace；
        ///   false = 源屏切回失败（源 space 无可聚焦窗口等），窗口落在源屏可见 space；
        ///   nil   = record 无 space 信息（sourceSpace=0），从未尝试切回。
        case restored(spaceExact: Bool?)
        /// 移动前的放弃：无 toggle record / AX 窗口已不存在。record 不动、无审计事件
        /// （与历史行为一致；不是移动失败，别把语义让给 moveFailed*）。
        case aborted(reason: String)
        /// frame 未收敛但 origFrame 仍在某块现有屏上——瞬时失败（yabai 抖动/窗口最小化等）。
        /// record 保留：用户再次触发 restore 即重试。
        case moveFailedRetryable
        /// frame 未收敛且 origFrame 已不在任何屏幕（断显/分辨率变更）——永久失败。
        /// record 清除：下次 toggle 走 stuck 解堵路径兜底，避免每次热键空转整段恢复耗时。
        case moveFailedPermanent

        /// 机器可读结局标签（WindowManager 失败日志与 CrashContextRecorder 用；
        /// RestoreRefocusCandidateTests 分支穷尽锁定）。
        var outcomeLabel: String {
            switch self {
            case .restored(let spaceExact):
                return "restored(spaceExact=\(String(describing: spaceExact)))"
            case .aborted(let reason):
                return "aborted_\(reason)"
            case .moveFailedRetryable:
                return "move_failed_retryable_record_kept"
            case .moveFailedPermanent:
                return "move_failed_permanent_record_cleared"
            }
        }
    }

    /// 失败时 record 处置的纯决策（RestoreRefocusCandidateTests 锁定）。
    /// origFrame 中心仍落在某块现有屏上 → 瞬时失败保留 record；已不在任何屏 → 清除。
    static func isMoveFailureRetryable(origFrameOnAnyDisplay: Bool) -> Bool {
        origFrameOnAnyDisplay
    }

    /// 4-pre 源屏预切回决策（纯函数，RestoreRefocusCandidateTests 分支穷尽锁定）。
    enum SourceSpacePreSwitch: Equatable {
        /// record 无 space/display 上下文（0 值）——无从预切，spaceExact=nil。
        case noContext
        /// 源屏可见 space 已是 sourceSpace；或可见性查询失败（不盲切，历史行为视作
        /// 已精确）——无需切换，spaceExact=true。
        case notNeeded
        /// 源屏停在别的 space——需要预切回 sourceSpace；spaceExact=切回是否成功。
        case switchNeeded(visibleSpace: Int)
    }

    static func sourceSpacePreSwitch(
        sourceSpace: Int,
        sourceYabaiDisp: Int,
        visibleSpaceOnSourceDisplay: Int?
    ) -> SourceSpacePreSwitch {
        guard sourceSpace > 0, sourceYabaiDisp > 0 else { return .noContext }
        guard let visible = visibleSpaceOnSourceDisplay else { return .notNeeded }
        return visible == sourceSpace ? .notNeeded : .switchNeeded(visibleSpace: visible)
    }

    /// 视角守卫（成功与失败路径共用）：frame 直写/源屏预切回会把 macOS 键盘焦点/视角
    /// 拖到源 display，此处切回 preMoveSpace。通道双层编排收敛在
    /// RestoreSwitchOrchestration.refocusPerspective（通道 protocol 化可注入，测试分支穷尽
    /// 锁定），本方法只做日志与计时。
    /// - Returns: 守卫耗时（ms），供 completed 汇总日志（focusSpaceMs）。
    private static func runPerspectiveGuard(
        channels: any RestoreSpaceChanneling,
        preMoveSpace: Int?,
        excludingWindowID excluded: UInt32,
        traceID trace: String,
        prefetchedWindows: [YabaiWindowInfo]? = nil
    ) -> Int {
        guard let preMoveSpace else { return 0 }
        let guardStart = Date()
        switch RestoreSwitchOrchestration.refocusPerspective(
            channels: channels,
            preMoveSpace: preMoveSpace,
            excludingWindowID: excluded,
            operationID: trace,
            prefetchedWindows: prefetchedWindows
        ) {
        case .noDrift:
            return 0
        case .refocused(let postSpace):
            log("[ToggleEngine] restore: macOS auto-switched space, refocusing original screen", level: .info, fields: [
                "traceID": trace, "preSpace": String(preMoveSpace),
                "postSpace": String(postSpace)
            ])
            return elapsedMilliseconds(since: guardStart)
        case .failed(let postSpace):
            log("[ToggleEngine] restore: macOS auto-switched space and refocus failed, user left on another space", level: .warn, fields: [
                "traceID": trace, "preSpace": String(preMoveSpace),
                "postSpace": String(postSpace)
            ])
            return elapsedMilliseconds(since: guardStart)
        }
    }

    @discardableResult
    func restore(windowID: UInt32, triggerSource: String, traceID: String? = nil) -> RestoreOutcome {
        Self.performRestore(
            windowID: windowID,
            triggerSource: triggerSource,
            traceID: traceID,
            records: self,
            windows: WindowManager.shared,
            channels: SpaceController.shared,
            auditor: AuditLogger.shared
        )
    }

    /// restore 主体（依赖全注入、无实例状态；Tests/Runner 分支穷尽锁定，生产入口见上）。
    static func performRestore(
        windowID: UInt32,
        triggerSource: String,
        traceID: String?,
        records: any RestoreRecordStoring,
        windows: any RestoreWindowOperating,
        channels: any RestoreSpaceChanneling,
        auditor: any RestoreAuditing
    ) -> RestoreOutcome {
        // P-INST-79: restore 端到端总耗时（defer 覆盖所有 return 含早期 lookup/query 失败路径；139 finished 仅成功路径汇总子阶段；lookup+query+move+float+apply+focusSpace 之和 + gaps；toggle/restore 核心）。
        #if PERF_INSTRUMENT
        let restoreStart = Date()
        defer {
            log("[ToggleEngine] restore finished", level: .debug, fields: [
                "windowID": String(windowID),
                "durationMs": String(elapsedMilliseconds(since: restoreStart))
            ])
        }
        #endif
        let trace = traceID ?? makeOperationID(prefix: "te")

        // 1. Load record — windowID only, no PID fallback
        guard let record = records.load(windowID: windowID) else {
            log("[ToggleEngine] restore: no toggle record", level: .warn, fields: [
                "traceID": trace, "windowID": String(windowID)
            ])
            return .aborted(reason: "no_toggle_record")
        }

        // 3. Resolve AX window（record 按 windowID 加载，两者恒等；存在性探测兼防窗口已关）
        let lookupStart = Date()
        guard windows.findWindowByPID(record.pid, windowID: windowID) != nil else {
            log("[ToggleEngine] restore: AX window not found", level: .warn, fields: [
                "traceID": trace, "windowID": String(windowID), "pid": String(record.pid)
            ])
            return .aborted(reason: "ax_window_not_found")
        }
        let lookupMs = elapsedMilliseconds(since: lookupStart)

        // 3.5 yabai 窗口信息（最小化快检 + float 决策共用一次 fork，命中缓存 ~0ms）。
        let queryStart = Date()
        let windowInfo = channels.queryWindow(windowID: windowID, ignoreCache: false)
        let queryMs = elapsedMilliseconds(since: queryStart)

        // 3.6 最小化快检：最小化窗口上 float/--move 均静默无效，frame 直写必不收敛；
        // 此时执行源屏预切回只会白白拖动用户视角。快速失败并保留 record，
        // 用户取消最小化后再触发即恢复。
        if let info = windowInfo, info.isMinimized {
            log("[ToggleEngine] restore: window is minimized, cannot restore", level: .warn, fields: [
                "traceID": trace, "windowID": String(windowID)
            ])
            auditor.record(
                eventType: "restore_move_failed",
                windowID: windowID,
                pid: record.pid,
                sessionID: nil,
                details: [
                    "triggerSource": triggerSource,
                    "reason": "window_minimized",
                    "recordKept": "true"
                ]
            )
            return .moveFailedRetryable
        }

        log("[ToggleEngine] restore: starting", fields: [
            "traceID": trace,
            "windowID": String(windowID),
            "recordWindowID": String(record.windowID),
            "pid": String(record.pid),
            "sourceSpace": String(record.sourceSpace),
            "triggerSource": triggerSource,
            "origFrame": QuartzRect(record.origFrame).description,
            "targetFrame": QuartzRect(record.targetFrame).description
        ])

        // 视角基准：必须在 4-pre 切换源屏之前采集（否则守卫看到的是切换后的 space，漏切回）。
        // 记录移动前的 focused space — 用于检测 macOS 是否自动切换了 space
        let preMoveSpace = channels.currentSpaceIndex()

        // 4-pre. space 精确恢复前置（ToggleRecord 的 source_space/source_display 列启用）：
        // record 记录了窗口原始所属的 space（record.sourceSpace）与 display（record.sourceYabaiDisp）。
        // frame 直写只能落到"目标屏当前可见 space"——若源屏已被用户切到别的 space，窗口会落错。
        // 处理：源屏可见 space ≠ sourceSpace 时，先把源屏切回 sourceSpace。双层切回，
        // 与视角守卫对称，按可靠性排序：
        //   1) SA 直切 space --focus：不依赖目标 space 上有窗口，源 space 已空时唯一能
        //      精确切回的通道（canControlSpaces 运行时判据分流，禁止硬编码 SA 假设——
        //      SA 状态随环境/重启漂移，2026-09-02 实测校准）；
        //   2) 聚焦带动 refocusWindowOnSpace：直切失败/不可用时降级，要求源 space 上有
        //      可管理窗口（空 space 必失败，此时 spaceExact=false 随结局上报，不静默）。
        // 是否切/初始 spaceExact 由 sourceSpacePreSwitch 纯函数裁决（测试锁定）。
        var spaceExact: Bool?
        switch Self.sourceSpacePreSwitch(
            sourceSpace: record.sourceSpace,
            sourceYabaiDisp: record.sourceYabaiDisp,
            visibleSpaceOnSourceDisplay: channels.visibleSpaceIndex(forDisplayIndex: record.sourceYabaiDisp, spaces: nil, ignoreCache: false)?.yabaiIndex
        ) {
        case .noContext:
            spaceExact = nil
        case .notNeeded:
            spaceExact = true
        case .switchNeeded(let visibleSpace):
            log("[ToggleEngine] restore: source display is on a different space, switching it back", level: .info, fields: [
                "traceID": trace, "windowID": String(windowID),
                "sourceDisplay": String(record.sourceYabaiDisp),
                "visibleSpace": String(visibleSpace),
                "sourceSpace": String(record.sourceSpace),
                "saAvailable": String(channels.canControlSpaces)
            ])
            let switchStart = Date()
            // 双层通道编排收敛在 RestoreSwitchOrchestration.switchSourceSpace（通道
            // protocol 化可注入，测试分支穷尽锁定）。switched=通道级成败；spaceExact=
            // 下面「等到位」轮询的真实落定。
            let switched = RestoreSwitchOrchestration.switchSourceSpace(
                channels: channels,
                sourceSpace: record.sourceSpace,
                operationID: trace
            )
            // 等到位（P1-2）：切回命令成功 ≠ 状态已落定，轮询确认源屏可见 space 真切回
            // （ignoreCache——切回命令刚发出时缓存还是切前状态，读缓存恒假会白转到超时）。
            // 多数 <300ms 早满足早返回；超时如实记 spaceExact=false（窗口大概率落在
            // 源屏可见 space，与切回失败同等诚实上报，不再沿用旧固定 sleep 的乐观假设）。
            if switched {
                let poll = ConditionPolling.waitUntil(
                    intervalMs: WindowSettle.conditionPollIntervalMs,
                    budgetMs: WindowSettle.spaceSwitchWaitBudgetMs,
                    condition: {
                        channels.visibleSpaceIndex(forDisplayIndex: record.sourceYabaiDisp, spaces: nil, ignoreCache: true)?.yabaiIndex == record.sourceSpace
                    }
                )
                spaceExact = poll.satisfied
            } else {
                spaceExact = false
            }
            log("[ToggleEngine] restore: source display space switch result", level: (spaceExact == true) ? .info : .warn, fields: [
                "traceID": trace, "switched": String(switched),
                "spaceExact": String(describing: spaceExact),
                "durationMs": String(elapsedMilliseconds(since: switchStart))
            ])
        }

        // 3.8 守卫候选预取（2026-09-04）：preMoveSpace 的窗口列表在 move 前后不变
        // （被恢复窗口在守卫中被 exclude），提前到 move 前发起查询，move 完成时候选
        // 已就绪——守卫聚焦免一次串行 fork（~30-60ms）。restore 场景守卫必触发
        // （frame 直写必拖焦点），预取浪费路径罕见；preMoveSpace 未知（无 space 上下文）
        // 时跳过。查询失败由守卫内部如实降级（nil = refocusWindowOnSpace 现查）。
        let guardPrefetchedWindows: [YabaiWindowInfo]?
        if preMoveSpace != nil, let pms = preMoveSpace {
            guardPrefetchedWindows = channels.queryWindowsOnSpace(pms, operationID: trace)
        } else {
            guardPrefetchedWindows = nil
        }

        // 4. Move back to original frame（2026-09-01 重构：float 脱管 → yabai --move/--resize 直写 origFrame）
        // 原 `yabai --space` 在 yabai v7 float 布局下静默失效（exit 0 但窗口不动，
        // Tests/AXMoveValidation.swift T3 实测）；frame 直写经断言验证跨 display 可靠，
        // macOS 窗口归属跟随物理位置自动回到源 display 的 visible space。
        // 4a. float 脱管——仅在真发生脱管时等重摆落定（窗口已 float 时无重摆，
        // 无条件等待是 restore 常见路径的纯浪费，2026-09-02 消除）。
        // 注意 float 等待不轮询：is-floating 翻转远早于 yabai 重摆完成，而重摆完成
        // 无可观测信号——此处保留固定 300ms settle（等短了写会被重摆覆盖，
        // 2026-09-01 尺寸错乱根因）；「等到位」轮询只用于有可观测目标态的 4-pre space 切回。
        var moveMs = 0
        if let info = windowInfo {
            let floatStart = Date()
            let floatOutcome = channels.setWindowFloat(windowID, operationID: trace, knownWindowInfo: info)
            if floatOutcome.didToggle {
                usleep(WindowSettle.floatRelayoutSettleMicros)
            }
            moveMs = elapsedMilliseconds(since: floatStart)
        }
        // 4b. yabai --move abs + --resize abs 直写 origFrame（窗口归属跟随物理位置）。
        // sourceSpace=0（无 space 信息）时 origFrame 坐标仍有效——frame 直写不依赖 space 编号。
        let moveStart = Date()
        // sourceVisibleSize=nil：restore 的窗口在主屏，resize 目标（源窗尺寸）≤ 主屏
        // 可视区，无 clamp 风险；若未来目标超源屏可见区需传当前 display 可视区。
        let frameOK = windows.moveWindowToFrameViaYabai(
            windowID: windowID,
            frame: record.origFrame,
            op: trace,
            stage: "restore",
            sourceVisibleSize: nil
        )
        moveMs += elapsedMilliseconds(since: moveStart)
        log("[ToggleEngine] restore: frame move result", fields: [
            "traceID": trace, "frameOK": String(frameOK),
            "origFrame": QuartzRect(record.origFrame).description
        ])

        // 5. 结局裁决（诚实化：frame 未收敛不再伪装成功、不再销毁 record）。
        guard frameOK else {
            // frame 写失败但源屏预切回可能已把视角拖走——失败路径同样执行视角守卫，
            // 把用户带回原处（窗口仍在主屏）。
            _ = Self.runPerspectiveGuard(channels: channels, preMoveSpace: preMoveSpace, excludingWindowID: windowID, traceID: trace, prefetchedWindows: guardPrefetchedWindows)
            let origFrameOnAnyDisplay = windows.displayContext(for: record.origFrame).yabaiIndex != nil
            if Self.isMoveFailureRetryable(origFrameOnAnyDisplay: origFrameOnAnyDisplay) {
                log("[ToggleEngine] restore: frame move failed, keeping record for retry", level: .error, fields: [
                    "traceID": trace, "windowID": String(windowID),
                    "origFrame": QuartzRect(record.origFrame).description
                ])
                auditor.record(
                    eventType: "restore_move_failed",
                    windowID: windowID,
                    pid: record.pid,
                    sessionID: nil,
                    details: [
                        "triggerSource": triggerSource,
                        "reason": "frame_not_converged",
                        "recordKept": "true"
                    ]
                )
                return .moveFailedRetryable
            }
            log("[ToggleEngine] restore: frame move failed and origFrame is off any display, clearing record", level: .error, fields: [
                "traceID": trace, "windowID": String(windowID),
                "origFrame": QuartzRect(record.origFrame).description
            ])
            records.clear(windowID: record.windowID)
            auditor.record(
                eventType: "restore_move_failed",
                windowID: windowID,
                pid: record.pid,
                sessionID: nil,
                details: [
                    "triggerSource": triggerSource,
                    "reason": "orig_frame_offscreen",
                    "recordKept": "false"
                ]
            )
            return .moveFailedPermanent
        }

        // 6. 视角守卫（与失败路径共用 runPerspectiveGuard，见其文档）。
        let focusSpaceMs = Self.runPerspectiveGuard(channels: channels, preMoveSpace: preMoveSpace, excludingWindowID: windowID, traceID: trace, prefetchedWindows: guardPrefetchedWindows)

        // 7. Clear record
        records.clear(windowID: record.windowID)

        log("[ToggleEngine] restore: completed", fields: [
            "traceID": trace,
            "windowID": String(windowID),
            "targetSpace": String(record.sourceSpace),
            "frameOK": String(frameOK),
            "spaceExact": String(describing: spaceExact),
            "origFrame": QuartzRect(record.origFrame).originDescription,
            "lookupMs": String(lookupMs),
            "queryMs": String(queryMs),
            "moveMs": String(moveMs),
            "focusSpaceMs": String(focusSpaceMs)
        ])

        auditor.record(
            eventType: "restore_success",
            windowID: windowID,
            pid: record.pid,
            sessionID: nil,
            details: [
                "triggerSource": triggerSource,
                "targetSpace": String(record.sourceSpace),
                "spaceExact": String(describing: spaceExact)
            ]
        )

        return .restored(spaceExact: spaceExact)
    }
}
