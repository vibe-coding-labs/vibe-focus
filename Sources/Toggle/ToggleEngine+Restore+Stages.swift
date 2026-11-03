import Foundation
import Cocoa

// Sources/Toggle/ToggleEngine+Restore+Stages.swift — B157 自 ToggleEngine+Restore.swift 按域拆出
//（逐字搬移零行为变更）：restore 四阶段机械。B97 分阶段提取的产物，调用序列由
// RunnerRestoreOrchestrationTests 序列锁穷尽锁定；private→internal 仅为跨文件调用。

extension ToggleEngine {

    /// 6+7 成功尾段阶段：视角守卫 → 落位 space 裁决 → 清 record → completed 汇总日志 → 审计。
    ///
    /// `landed`（2026-11-03）：move 后窗口真实所属 space 的复核观测。frame 收敛只证明
    /// 坐标对，不证明工作区对——「工作区 2 的窗口还原到工作区 3 的对应位置」正是
    /// 同坐标不同 space。有真实落位时以它为准裁决 spaceExact（地面真值优先于预切回
    /// 轮询结论）；查询失败（nil）时保留预切回结论并标注 unknown。
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
        auditor: any RestoreAuditing,
        landed: LandingSpaceObservation? = nil
    ) -> RestoreOutcome {
        // 6. 视角守卫（与失败路径共用 runPerspectiveGuard，见其文档）。
        let focusSpaceMs = Self.runPerspectiveGuard(channels: channels, preMoveSpace: preMove.preMoveSpace, excludingWindowID: windowID, traceID: trace, prefetchedWindows: preMove.guardPrefetchedWindows, preMoveFocusedDisplay: preMove.preMoveFocusedDisplay)

        // 6.5 结局裁决：真实落位优先。只有 targetSpace 与 landedSpace 同时可知才改判，
        // 否则（无 space 上下文/查询失败）沿用预切回结论，绝不把「未知」伪装成「精确」。
        let verifiedSpaceExact = Self.landingSpaceExact(
            preSwitch: spaceExact,
            landedSpace: landed?.landedSpace,
            targetSpace: preMove.targetSpace
        )
        let resolvedTargetSpace = preMove.targetSpace ?? record.sourceSpace

        // 7. Clear record
        records.clear(windowID: record.windowID)

        log("[ToggleEngine] restore: completed", fields: [
            "traceID": trace,
            "windowID": String(windowID),
            "targetSpace": String(resolvedTargetSpace),
            "recordedSpace": String(record.sourceSpace),
            "targetDisplay": String(describing: preMove.targetDisplay),
            "visibleOnSourceDisplay": preMove.visibleOnSourceDisplay.map(String.init) ?? "unknown",
            "landedSpace": landed?.landedSpace.map(String.init) ?? "unknown",
            "landingChecks": String(describing: landed?.checks),
            "spaceIndexShifted": String(preMove.spaceIndexShifted),
            "sourceTopology": preMove.spaceTopology,
            "frameOK": String(frameOK),
            "spaceExact": String(describing: verifiedSpaceExact),
            "spaceExactPreSwitch": String(describing: spaceExact),
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
                "targetSpace": String(resolvedTargetSpace),
                "targetDisplay": String(describing: preMove.targetDisplay),
                "landedSpace": landed?.landedSpace.map(String.init) ?? "unknown",
                "spaceIndexShifted": String(preMove.spaceIndexShifted),
                "spaceExact": String(describing: verifiedSpaceExact),
                "spaceExactPreSwitch": String(describing: spaceExact)
            ]
        )

        return .restored(spaceExact: verifiedSpaceExact)
    }

    // MARK: - 分阶段提取（B97：行为等价重构，调用序列由 Tests/Runner 序列锁穷尽锁定）

    /// 4-pre 前置阶段结果：视角基准 + 源屏精确恢复结论 + 解析出的还原目标 + 守卫预取窗口。
    /// （原文件私有嵌套类型随阶段拆分放宽 internal，performRestore 主编排同用）
    ///
    /// 2026-11-03：新增 targetSpace/targetDisplay/visibleOnSourceDisplay/spaceIndexShifted/
    /// spaceTopology——还原目标不再直接沿用 record.sourceSpace 的旧全局索引，而是按
    /// fresh 拓扑回译后的结果；这些字段原样进 completed 日志与审计，落错工作区可回溯。
    struct RestorePreMoveContext {
        /// 移动前的 focused space（视角基准，必须在预切回之前采集）
        let preMoveSpace: Int?
        /// 移动前的焦点 display（守卫「焦点换屏=跨屏跟随不纠正」判据；nil=查询失败走旧行为）
        let preMoveFocusedDisplay: Int?
        /// 源屏精确恢复结论（nil=无 space 上下文）
        let spaceExact: Bool?
        /// 守卫候选预取（preMoveSpace 未知时为 nil）
        let guardPrefetchedWindows: [YabaiWindowInfo]?
        /// 实际要还原到的 yabai 全局 space（fresh 拓扑回译；nil=无 space 上下文）
        let targetSpace: Int?
        /// 实际要还原到的 yabai display（几何屏优先；nil=无法确定）
        let targetDisplay: Int?
        /// fresh 拓扑里源屏当时可见的 space（取证；nil=未知/拓扑不可用）
        let visibleOnSourceDisplay: Int?
        /// record.sourceSpace 与按 display-local 序号回译出的目标不一致（索引已漂移）
        let spaceIndexShifted: Bool
        /// fresh 拓扑取证串（RestoreSpaceTargetResolver.describeTopology）
        let spaceTopology: String

        /// 显式 init：新增取证字段全部带默认值，既有构造点（Tests/Runner 四参调用）不变。
        init(
            preMoveSpace: Int?,
            preMoveFocusedDisplay: Int?,
            spaceExact: Bool?,
            guardPrefetchedWindows: [YabaiWindowInfo]?,
            targetSpace: Int? = nil,
            targetDisplay: Int? = nil,
            visibleOnSourceDisplay: Int? = nil,
            spaceIndexShifted: Bool = false,
            spaceTopology: String = "nil"
        ) {
            self.preMoveSpace = preMoveSpace
            self.preMoveFocusedDisplay = preMoveFocusedDisplay
            self.spaceExact = spaceExact
            self.guardPrefetchedWindows = guardPrefetchedWindows
            self.targetSpace = targetSpace
            self.targetDisplay = targetDisplay
            self.visibleOnSourceDisplay = visibleOnSourceDisplay
            self.spaceIndexShifted = spaceIndexShifted
            self.spaceTopology = spaceTopology
        }
    }

    /// 4-pre 前置阶段：采集视角基准 → fresh 拓扑解析还原目标 → 源屏 space 预切回
    /// （sourceSpacePreSwitch/freshSourceSpacePreSwitch 纯函数裁决）→ 守卫候选预取。
    ///
    /// ## 2026-11-03 取证加固（用户主诉「工作区 2 的窗口还原到工作区 3 对应位置」）
    /// 1. 还原目标按 fresh 拓扑回译：record.sourceSpace 是 toggle 时刻的全局索引，任一屏
    ///    增删 space 会整体位移；record.sourceDispSpace（display-local 序号）才是用户语义
    ///    里的「原工作区」。回译结果进日志（spaceIndexShifted），漂移一眼可见。
    /// 2. 可见 space 改读 fresh 拓扑：旧路径读 2s 缓存，toggle→restore 间隔短时缓存还是
    ///    切走前的旧值，会误判 notNeeded 跳过切回（落错工作区根因之一）。
    /// 3. 目标屏/space 在拓扑里无法定位时不盲切，spaceExact=false 如实上报。
    /// 4. 拓扑查询失败时逐字回退旧路径（visibleSpaceIndex ignoreCache:false），既有行为不变。
    static func performSourcePreSwitch(
        record: ToggleRecord,
        channels: any RestoreSpaceChanneling,
        windowID: UInt32,
        trace: String
    ) -> RestorePreMoveContext {
        // 视角基准：必须在 4-pre 切换源屏之前采集（否则守卫看到的是切换后的 space，漏切回）。
        // 记录移动前的 focused space — 用于检测 macOS 是否自动切换了 space
        let preMoveSpace = channels.currentSpaceIndex()
        let preMoveFocusedDisplay = channels.focusedDisplayIndex()

        var spaceExact: Bool?
        var targetSpace: Int?
        var targetDisplay: Int?
        var visibleOnSourceDisplay: Int?
        var spaceIndexShifted = false
        var spaceTopology = "skipped(noSpaceContext)"

        if record.sourceSpace > 0 {
            // fresh 拓扑：可见性与索引位移都必须基于当前状态（不许读 2s 缓存）。
            let topology = channels.querySpaceTopology()
            let spaces = topology.spaces
            spaceTopology = RestoreSpaceTargetResolver.describeTopology(spaces)
            let geometricDisplay = channels.sourceDisplayForFrame(record.origFrame)
            let resolution = RestoreSpaceTargetResolver.resolve(
                recordedSpace: record.sourceSpace,
                recordedDisplay: record.sourceYabaiDisp,
                recordedLocalSpace: record.sourceDispSpace,
                geometricDisplay: geometricDisplay,
                spaces: spaces
            )

            if let resolution {
                targetSpace = resolution.spaceIndex
                targetDisplay = resolution.displayIndex
                visibleOnSourceDisplay = resolution.visibleSpaceIndex
                spaceIndexShifted = resolution.spaceIndexShifted
                log("[ToggleEngine] restore: source target resolved (fresh topology)", level: resolution.spaceOnDisplay ? .info : .warn, fields: [
                    "traceID": trace, "windowID": String(windowID),
                    "resolution": RestoreSpaceTargetResolver.describe(resolution),
                    "recordedDisplay": String(record.sourceYabaiDisp),
                    "recordedLocalSpace": String(record.sourceDispSpace),
                    "geometricDisplay": String(describing: geometricDisplay),
                    "topology": spaceTopology
                ])
                // 预期切回（与视角守卫对称的双层通道）：见下方旧路径注释。
                switch Self.freshSourceSpacePreSwitch(
                    sourceSpace: resolution.spaceIndex,
                    targetDisplay: resolution.displayIndex,
                    displayInTopology: resolution.displayInTopology,
                    spaceOnDisplay: resolution.spaceOnDisplay,
                    visibleSpaceOnSourceDisplay: resolution.visibleSpaceIndex
                ) {
                case .noContext:
                    spaceExact = nil
                case .targetUnresolvable:
                    // 拔屏/索引漂移：目标工作区在当前拓扑里定位不到。不盲切，如实降级。
                    spaceExact = false
                    log("[ToggleEngine] restore: source target not resolvable in fresh topology, keeping visible space", level: .warn, fields: [
                        "traceID": trace, "windowID": String(windowID),
                        "targetSpace": String(resolution.spaceIndex),
                        "targetDisplay": String(resolution.displayIndex),
                        "displayInTopology": String(resolution.displayInTopology),
                        "spaceOnDisplay": String(resolution.spaceOnDisplay),
                        "topology": spaceTopology
                    ])
                case .notNeeded:
                    spaceExact = true
                case .switchNeeded(let visibleSpace):
                    log("[ToggleEngine] restore: source display is on a different space, switching it back", level: .info, fields: [
                        "traceID": trace, "windowID": String(windowID),
                        "sourceDisplay": String(resolution.displayIndex),
                        "visibleSpace": visibleSpace.map(String.init) ?? "unknown",
                        "sourceSpace": String(resolution.spaceIndex),
                        "recordedSpace": String(resolution.recordedSpaceIndex),
                        "spaceIndexShifted": String(resolution.spaceIndexShifted),
                        "saAvailable": String(channels.canControlSpaces)
                    ])
                    let switchStart = Date()
                    // 双层通道编排收敛在 RestoreSwitchOrchestration.switchSourceSpace。
                    // 目标用回译后的 spaceIndex——旧全局索引在漂移后会把源屏切到隔壁工作区。
                    let switched = RestoreSwitchOrchestration.switchSourceSpace(
                        channels: channels,
                        sourceSpace: resolution.spaceIndex,
                        operationID: trace
                    )
                    // 等到位：切回命令成功 ≠ 状态已落定（ignoreCache 恒读 fresh；目标态与
                    // 下发目标同源，避免「切到 3、轮询等 2」的自相矛盾）。
                    if switched {
                        let poll = ConditionPolling.waitUntil(
                            intervalMs: WindowSettle.conditionPollIntervalMs,
                            budgetMs: WindowSettle.spaceSwitchWaitBudgetMs,
                            condition: {
                                channels.visibleSpaceIndex(forDisplayIndex: resolution.displayIndex, spaces: nil, ignoreCache: true)?.yabaiIndex == resolution.spaceIndex
                            }
                        )
                        spaceExact = poll.satisfied
                    } else {
                        spaceExact = false
                    }
                    log("[ToggleEngine] restore: source display space switch result", level: (spaceExact == true) ? .info : .warn, fields: [
                        "traceID": trace,
                        "targetSpace": String(resolution.spaceIndex),
                        "targetDisplay": String(resolution.displayIndex),
                        "switched": String(switched),
                        "spaceExact": String(describing: spaceExact),
                        "durationMs": String(elapsedMilliseconds(since: switchStart))
                    ])
                }
            } else {
                // 拓扑不可用（yabai 查询失败）或记录不自洽：逐字回退旧路径（2s 缓存判定），
                // 保持历史行为与序列锁；spaceExact 语义沿用 sourceSpacePreSwitch。
                targetSpace = record.sourceSpace
                targetDisplay = record.sourceYabaiDisp > 0 ? record.sourceYabaiDisp : nil
                spaceTopology = "unavailable"
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
                let legacyVisible = channels.visibleSpaceIndex(
                    forDisplayIndex: record.sourceYabaiDisp, spaces: nil, ignoreCache: false
                )?.yabaiIndex
                visibleOnSourceDisplay = legacyVisible
                switch Self.sourceSpacePreSwitch(
                    sourceSpace: record.sourceSpace,
                    sourceYabaiDisp: record.sourceYabaiDisp,
                    visibleSpaceOnSourceDisplay: legacyVisible
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
            }
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
            preMoveFocusedDisplay: preMoveFocusedDisplay,
            spaceExact: spaceExact,
            guardPrefetchedWindows: guardPrefetchedWindows,
            targetSpace: targetSpace,
            targetDisplay: targetDisplay,
            visibleOnSourceDisplay: visibleOnSourceDisplay,
            spaceIndexShifted: spaceIndexShifted,
            spaceTopology: spaceTopology
        )
    }

    /// move 后落位观测（2026-11-03）：窗口真实所属 space 的复核结果。
    struct LandingSpaceObservation: Equatable {
        /// 复核到的窗口 space；nil=查询失败（未知，不等于落错）
        let landedSpace: Int?
        /// 共查询次数（1=首查即得结论，未进入补看轮询）
        let checks: Int
        let durationMs: Int
    }

    /// move 后落位 space 复核。
    ///
    /// 为什么需要：frame 收敛只证明坐标对——「工作区 2 的窗口还原到工作区 3 的对应
    /// 位置」正是同坐标不同 space，frameOK=true 与 spaceExact=true 会同时成立而用户
    /// 看到的是错工作区。这里用窗口真实 space 做地面真值裁决（landingSpaceExact）。
    ///
    /// 策略：首查恒发（生产 ignoreCache，缓存里是 move 前的旧 space）；相等即返回；
    /// 不等才按 50ms/300ms 补看（yabai/macOS 异步落定，避免把瞬态当结论）；查询失败
    /// 不轮询（未知≠落错，如实留 WARN 取证）。
    static func verifyLandingSpace(
        windowID: UInt32,
        targetSpace: Int,
        channels: any RestoreSpaceChanneling,
        trace: String
    ) -> LandingSpaceObservation {
        let start = Date()
        var checks = 0
        func read() -> Int? {
            checks += 1
            return channels.windowSpaceIndex(windowID: windowID)
        }
        guard var landed = read() else {
            let observation = LandingSpaceObservation(
                landedSpace: nil,
                checks: checks,
                durationMs: elapsedMilliseconds(since: start)
            )
            log("[ToggleEngine] restore: landing space unknown", level: .warn, fields: [
                "traceID": trace, "windowID": String(windowID),
                "targetSpace": String(targetSpace),
                "checks": String(checks),
                "durationMs": String(observation.durationMs)
            ])
            return observation
        }
        if landed != targetSpace {
            _ = ConditionPolling.waitUntil(
                intervalMs: WindowSettle.landingSpaceVerifyPollIntervalMs,
                budgetMs: WindowSettle.landingSpaceVerifyBudgetMs,
                condition: {
                    if let current = read() { landed = current }
                    return landed == targetSpace
                }
            )
        }
        let observation = LandingSpaceObservation(
            landedSpace: landed,
            checks: checks,
            durationMs: elapsedMilliseconds(since: start)
        )
        log("[ToggleEngine] restore: landing space verified", level: (landed == targetSpace) ? .info : .warn, fields: [
            "traceID": trace, "windowID": String(windowID),
            "targetSpace": String(targetSpace),
            "landedSpace": String(landed),
            "spaceExact": String(landed == targetSpace),
            "checks": String(checks),
            "durationMs": String(observation.durationMs)
        ])
        return observation
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
        _ = Self.runPerspectiveGuard(channels: channels, preMoveSpace: preMove.preMoveSpace, excludingWindowID: windowID, traceID: trace, prefetchedWindows: preMove.guardPrefetchedWindows, preMoveFocusedDisplay: preMove.preMoveFocusedDisplay)
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
        if let sourceVisibleFrame = windows.visibleFrameForDisplay(record.sourceYabaiDisp) {
            let clampedFrame = CoordinateKit.clampFrame(
                record.origFrame,
                into: sourceVisibleFrame
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
            _ = Self.runPerspectiveGuard(channels: channels, preMoveSpace: preMove.preMoveSpace, excludingWindowID: windowID, traceID: trace, prefetchedWindows: preMove.guardPrefetchedWindows, preMoveFocusedDisplay: preMove.preMoveFocusedDisplay)
            if retryOK {
                // 夹取重试同样复核真实落位——显示器配置变更场景最容易落错工作区，
                // 这条路径若沿用预切回结论会把「未知」报成精确。
                let landed = preMove.targetSpace.map {
                    Self.verifyLandingSpace(windowID: windowID, targetSpace: $0, channels: channels, trace: trace)
                }
                let verifiedSpaceExact = Self.landingSpaceExact(
                    preSwitch: spaceExact,
                    landedSpace: landed?.landedSpace,
                    targetSpace: preMove.targetSpace
                )
                let resolvedTargetSpace = preMove.targetSpace ?? record.sourceSpace
                records.clear(windowID: record.windowID)
                auditor.record(
                    eventType: "restore_success",
                    windowID: windowID,
                    pid: record.pid,
                    sessionID: nil,
                    details: [
                        "triggerSource": triggerSource,
                        "targetSpace": String(resolvedTargetSpace),
                        "landedSpace": landed?.landedSpace.map(String.init) ?? "unknown",
                        "spaceExact": String(describing: verifiedSpaceExact),
                        "clampedRestore": "true"
                    ]
                )
                log("[ToggleEngine] restore: completed (clamped into source screen)", fields: [
                    "traceID": trace,
                    "windowID": String(windowID),
                    "targetSpace": String(resolvedTargetSpace),
                    "landedSpace": landed?.landedSpace.map(String.init) ?? "unknown",
                    "spaceExact": String(describing: verifiedSpaceExact),
                    "clampedFrame": QuartzRect(clampedFrame).description
                ])
                return .restored(spaceExact: verifiedSpaceExact)
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
