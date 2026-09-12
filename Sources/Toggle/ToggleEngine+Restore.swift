import Foundation
import Cocoa

// MARK: - Restore Logic (Simplified)
//
// Design: 源屏预切回 → float 脱管 → yabai --move/--resize 直写 origFrame → 视角守卫。
// One shot, no retries. The old mechanism had 4 strategies, polling loops, a watchdog,
// and 642 lines to do what these steps accomplish.
//
// 文件分层（2026-09-07 拆分，行为不变）：
//   +Restore+Decision.swift — 结局类型 + record 处置/源屏预切回纯决策（测试锁所在）
//   +Restore+Stages.swift — 四阶段机械（成功尾段/源屏预切/float 脱管+frame 写/失败处置）
//   +Restore.swift（本文件） — 视角守卫 + 生产入口 + performRestore 编排
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

extension ToggleEngine {

    /// 视角守卫（成功与失败路径共用）：frame 直写/源屏预切回会把 macOS 键盘焦点/视角
    /// 拖到源 display，此处切回 preMoveSpace。通道双层编排收敛在
    /// RestoreSwitchOrchestration.refocusPerspective（通道 protocol 化可注入，测试分支穷尽
    /// 锁定），本方法只做日志与计时。
    /// - Returns: 守卫耗时（ms），供 completed 汇总日志（focusSpaceMs）。
    /// （原 private，四阶段拆出 +Stages.swift 后跨文件调用，B157）
    static func runPerspectiveGuard(
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
        // B178 常开埋点：UPS 自动归位走这里，实测 34/35 次 >200ms（最高 2.3s）——
        // 用户每次提交提示词都触发一次主线程阻塞，与打字节奏重合。
        PerfMonitor.shared.beginSection("restore", fields: ["trigger": triggerSource])
        defer { PerfMonitor.shared.endSection() }
        return Self.performRestore(
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

        let preMove = Self.performSourcePreSwitch(record: record, channels: channels, windowID: windowID, trace: trace)
        let spaceExact = preMove.spaceExact

        // 4. Move back to original frame（2026-09-01 重构：float 脱管 → yabai --move/--resize 直写 origFrame）
        // 原 `yabai --space` 在 yabai v7 float 布局下静默失效（exit 0 但窗口不动，
        // Tests/AXMoveValidation.swift T3 实测）；frame 直写经断言验证跨 display 可靠，
        // macOS 窗口归属跟随物理位置自动回到源 display 的 visible space。
        let (frameOK, moveMs) = Self.performFloatDetachAndFrameMove(
            windowID: windowID, record: record, windowInfo: windowInfo,
            windows: windows, channels: channels, trace: trace)

        // 5. 结局裁决（诚实化：frame 未收敛不再伪装成功、不再销毁 record）。
        guard frameOK else {
            return Self.performMoveFailureStage(
                record: record, windowID: windowID, triggerSource: triggerSource, trace: trace,
                spaceExact: spaceExact, preMove: preMove,
                windows: windows, channels: channels, records: records, auditor: auditor)
        }

        return Self.performSuccessTail(
            record: record, windowID: windowID, triggerSource: triggerSource, trace: trace,
            spaceExact: spaceExact, frameOK: frameOK, moveMs: moveMs, lookupMs: lookupMs, queryMs: queryMs,
            preMove: preMove,
            windows: windows, channels: channels, records: records, auditor: auditor)
    }
}
