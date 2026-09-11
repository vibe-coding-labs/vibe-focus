import Foundation
import Cocoa

// Sources/Toggle/ToggleEngine+Restore+Stages.swift — B157 自 ToggleEngine+Restore.swift 按域拆出
//（逐字搬移零行为变更）：restore 四阶段机械。B97 分阶段提取的产物，调用序列由
// RunnerRestoreOrchestrationTests 序列锁穷尽锁定；private→internal 仅为跨文件调用。

@MainActor
extension ToggleEngine {

    /// 6+7 成功尾段阶段：视角守卫 → 清 record → completed 汇总日志 → 审计。行为与内联版逐行等价。
    static func performSuccessTail(
        record: ToggleRecord,
        windowID: UInt32,
        triggerSource: String,
        trace: String,
        spaceExact: Bool?,
        frameOK: Bool,
        moveMs: Int,
        lookupMs: Int,
        queryMs: Int,
        preMove: RestorePreMoveContext,
        windows: any RestoreWindowOperating,
        channels: any RestoreSpaceChanneling,
        records: any RestoreRecordStoring,
        auditor: any RestoreAuditing
    ) -> RestoreOutcome {
        // 6. 视角守卫（与失败路径共用 runPerspectiveGuard，见其文档）。
        let focusSpaceMs = Self.runPerspectiveGuard(channels: channels, preMoveSpace: preMove.preMoveSpace, excludingWindowID: windowID, traceID: trace, prefetchedWindows: preMove.guardPrefetchedWindows)

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

    // MARK: - 分阶段提取（B97：行为等价重构，调用序列由 Tests/Runner 序列锁穷尽锁定）

    /// 4-pre 前置阶段结果：视角基准 + 源屏精确恢复结论 + 守卫预取窗口。
    /// （原文件私有嵌套类型随阶段拆分放宽 internal，performRestore 主编排同用）
    struct RestorePreMoveContext {
        /// 移动前的 focused space（视角基准，必须在预切回之前采集）
        let preMoveSpace: Int?
        /// 源屏精确恢复结论（nil=无 space 上下文）
        let spaceExact: Bool?
        /// 守卫候选预取（preMoveSpace 未知时为 nil）
        let guardPrefetchedWindows: [YabaiWindowInfo]?
    }

    /// 4-pre 前置阶段：采集视角基准 → 源屏 space 预切回（sourceSpacePreSwitch 纯函数裁决）
    /// → 守卫候选预取。行为与内联版逐行等价。
    static func performSourcePreSwitch(
        record: ToggleRecord,
        channels: any RestoreSpaceChanneling,
        windowID: UInt32,
        trace: String
    ) -> RestorePreMoveContext {
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
        if let pms = preMoveSpace {
            guardPrefetchedWindows = channels.queryWindowsOnSpace(pms, operationID: trace)
        } else {
            guardPrefetchedWindows = nil
        }

        return RestorePreMoveContext(
            preMoveSpace: preMoveSpace,
            spaceExact: spaceExact,
            guardPrefetchedWindows: guardPrefetchedWindows
        )
    }

    /// 4a+4b 阶段：float 脱管（仅在真脱管时等重摆落定）→ yabai --move/--resize abs 直写
    /// origFrame。行为与内联版逐行等价。
    /// - Returns: (frameOK 直写收敛与否, moveMs 阶段累计耗时)
    static func performFloatDetachAndFrameMove(
        windowID: UInt32,
        record: ToggleRecord,
        windowInfo: YabaiWindowInfo?,
        windows: any RestoreWindowOperating,
        channels: any RestoreSpaceChanneling,
        trace: String
    ) -> (frameOK: Bool, moveMs: Int) {
        // 4a. float 脱管——仅在真发生脱管时等重摆落定（窗口已 float 时无重摆，
        // 无条件等待是 restore 常见路径的纯浪费，2026-09-02 消除）。
        // 序列唯一出口 FloatSettle（Batch 6 收敛）：固定 300ms usleep → waitForRelayout
        // 等稳定轮询（下限 120ms 防重摆未启动的静默假稳定 + 连续两读相等早返回 +
        // 300ms 总预算兜底）——与 move_to_main/stuck 同源同一落定保证，本仓 float
        // 等待策略不再有两档；查询缓存失效随原语恒清（restore 原副本从不清，
        // float 后 isFloating/frame 旧值是竞态温床）。
        var moveMs = 0
        if let info = windowInfo {
            let floatStart = Date()
            _ = FloatSettle.floatAndSettle(
                windowID: windowID,
                operationID: trace,
                knownWindowInfo: info,
                tolerance: windows.frameTolerance,
                setFloat: { channels.setWindowFloat($0, operationID: $1, knownWindowInfo: $2) },
                read: { cgWindowBounds(for: $0) },
                clearCache: { channels.clearQueryCache() }
            )
            moveMs = elapsedMilliseconds(since: floatStart)
        }
        // 4b. yabai --move abs + --resize abs 直写 origFrame（窗口归属跟随物理位置）。
        // sourceSpace=0（无 space 信息）时 origFrame 坐标仍有效——frame 直写不依赖 space 编号。
        let moveStart = Date()
        // sourceVisibleFrame=nil：restore 的窗口在主屏，resize 目标（源窗尺寸）≤ 主屏
        // 可视区，无 clamp 风险；若未来目标超源屏可见区需传当前 display 可视区。
        let frameOK = windows.moveWindowToFrameViaYabai(
            windowID: windowID,
            frame: record.origFrame,
            op: trace,
            stage: "restore",
            sourceVisibleFrame: nil
        )
        moveMs += elapsedMilliseconds(since: moveStart)
        log("[ToggleEngine] restore: frame move result", fields: [
            "traceID": trace, "frameOK": String(frameOK),
            "origFrame": QuartzRect(record.origFrame).description
        ])
        return (frameOK, moveMs)
    }

    /// 5. 失败裁决阶段（frameOK == false 时进入）：视角守卫 → 可重试性判定 →
    /// 屏外夹进源屏幂等重试（P1 保守退让）→ 永久失败清 record。行为与内联版逐行等价。
    static func performMoveFailureStage(
        record: ToggleRecord,
        windowID: UInt32,
        triggerSource: String,
        trace: String,
        spaceExact: Bool?,
        preMove: RestorePreMoveContext,
        windows: any RestoreWindowOperating,
        channels: any RestoreSpaceChanneling,
        records: any RestoreRecordStoring,
        auditor: any RestoreAuditing
    ) -> RestoreOutcome {
        // frame 写失败但源屏预切回可能已把视角拖走——失败路径同样执行视角守卫，
        // 把用户带回原处（窗口仍在主屏）。
        _ = Self.runPerspectiveGuard(channels: channels, preMoveSpace: preMove.preMoveSpace, excludingWindowID: windowID, traceID: trace, prefetchedWindows: preMove.guardPrefetchedWindows)
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
        // P1 保守退让（2026-09-06）：origFrame 落在所有屏之外（显示器配置变化后
        // 常见——副屏拔除/分辨率切换把存档帧甩出屏）。旧行为直接清 record 放弃还原，
        // 窗口从此卡在主屏全屏态（用户主诉「尺寸/位置搞错」）。改为：原始帧夹进
        // 源屏可视区（保持尺寸、位置回到可见处）幂等重试一次；成功即还原（审计
        // 诚实标注 clamped_restore=true），仍失败才清 record 升级永久失败。
        if let sourceScreen = SpaceController.shared.exactNSScreen(forYabaiDisplayIndex: record.sourceYabaiDisp) {
            let clampedFrame = CoordinateKit.clampFrame(
                record.origFrame,
                into: CoordinateKit.quartzVisibleFrame(of: sourceScreen)
            )
            log("[ToggleEngine] restore: origFrame is off any display, clamping into source screen and retrying", level: .warn, fields: [
                "traceID": trace, "windowID": String(windowID),
                "origFrame": QuartzRect(record.origFrame).description,
                "clampedFrame": QuartzRect(clampedFrame).description
            ])
            let retryOK = windows.moveWindowToFrameViaYabai(
                windowID: windowID,
                frame: clampedFrame,
                op: trace,
                stage: "restore_clamped",
                sourceVisibleFrame: nil
            )
            _ = Self.runPerspectiveGuard(channels: channels, preMoveSpace: preMove.preMoveSpace, excludingWindowID: windowID, traceID: trace, prefetchedWindows: preMove.guardPrefetchedWindows)
            if retryOK {
                records.clear(windowID: record.windowID)
                auditor.record(
                    eventType: "restore_success",
                    windowID: windowID,
                    pid: record.pid,
                    sessionID: nil,
                    details: [
                        "triggerSource": triggerSource,
                        "targetSpace": String(record.sourceSpace),
                        "clampedRestore": "true"
                    ]
                )
                log("[ToggleEngine] restore: completed (clamped into source screen)", fields: [
                    "traceID": trace,
                    "windowID": String(windowID),
                    "clampedFrame": QuartzRect(clampedFrame).description
                ])
                return .restored(spaceExact: spaceExact)
            }
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
}
