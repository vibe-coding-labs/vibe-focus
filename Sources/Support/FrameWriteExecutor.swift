// FrameWriteExecutor.swift
// VibeFocus — 两段写入 + 补发的执行编排层（Batch 3 提取）
//
// ## 场景（2026-09-06 高内聚低耦合重构）
// moveWindowToFrameViaYabai 此前把「阶段顺序、阶段等待、补发决策、补发执行」全部
// 内联在 550 行的编排函数里，决策与 IO 纠缠导致只能整体真机验证。本类型把执行编排
// 收敛为可注入 deps 的一个值：决策全部委托 FrameConvergence（writeOrder/shortfalls/
// resendSegments 唯一事实源），本类型只负责按计划调用注入的执行器并如实计时上报。
//
// ## 语义契约（Tests/Runner FrameWriteExecutor 段锁定——编排逻辑不做 standalone 镜像，
// 因为等待/轮询骨架属执行域，其纯决策部分已由 FrameConvergence 镜像锁定）
// - phase1 按 FramePhase1Plan 三臂执行（2026-11-23 通道化，见下）；
// - 阶段等待超时只告警不失败——最终由段二收敛轮询如实裁决（历史行为）；
// - 段二补发计划 = resendSegments(shortfalls, order)；执行器差异：**尺寸**补发优先
//   AX 精确通道（可用时），否则单 .resize 走 adaptive（AX/yabai 择优）、全缺两段时
//   resize 走 robust 纯 yabai——「大漂移用最稳通道」的历史行为；
// - attempts=2、stallResendReads=4、轮询/预算常量取自 WindowSettle（与历史一致）。
//
// ## 2026-11-23 通道化段一：尺寸精度 vs 零段间等待（用户主诉双问题）
//
// ### 问题一：还原尺寸差 24px（iTerm2 目标 640 实到 664）
// 2026-11-21 的原子合发把**所有** yabai 通道的段一都改成「一条消息 --move + --resize」，
// 绕过了原先的 AX 精确尺寸通道。读 yabai 源码（window_manager.c，master）：
// - `--resize abs:w:h`（animate 恒 true）→ `window_manager_animate_window()`；动画总闸为
//   0 时落到 `window_manager_set_window_frame()`（window_manager.c:729+），它一次写
//   **三遍** AX：size → position(窗口缓存原点) → size 再写一遍；
// - `--move abs:x:y` 同理落到同一个 `set_window_frame`，且它的 size 用的是 yabai
//   进程内缓存的 `window->frame.size`（window_manager.c:342）——该缓存靠 AX 通知
//   异步维护，可能晚于 App 的写。
// 对**按字符网格吸附**的终端窗口（iTerm2，每列 ~8px），「size→position→size」这组写入
// 会稳定停在吸附值 664；而 App 自己只写一次 `kAXSizeAttribute`（resizeViaAX）就是精确
// 640。同窗口、同目标、只换通道即复现/消失（e16de7b 正确 640 / 5e0b288 起 664）。
// → 有 AX 通道时**尺寸必须走 AX**，yabai 只负责跨屏移动；AX 写后给 yabai 一个节拍
//   让它的 frame 缓存跟上，否则随后的 `--move` 会用它缓存里的旧宽高再盖一次。
//
// ### 问题二：两段动画（先移动 → 停 → 再长大）
// AX 通道的旧路径在 resize 与 move 之间跑 `waitForPhase` 轮询（300ms 预算、25ms 节拍），
// 还原场景实测 300~378ms——动画早被 YabaiAnimationGuard 关成 0 之后，这段等待只是纯延迟。
// 而 AX 写原语**自带读回验证**（resizeViaAX → writeSizeWithReadback，返回即已生效），
// 段间不需要再轮询一遍。
//
// ### 三臂策略（FramePhase1Plan，纯函数决策）
// | 通道 | 段一 | 段间 |
// |---|---|---|
// | AX 尺寸可精确写 | AX resize + yabai move（按写序） | 收窄：固定 25ms 节拍；放大：等 origin 可观测（25ms 节拍 / 150ms 预算，早返回） |
// | AX 不可用 / 已证明吞写 | yabai 单条消息合发 --move+--resize | 无（单条消息无中间态） |
// | 显式关闭合发（历史兼容/夹具） | yabai 两段 | waitForPhase 300ms 轮询 |
// 段二补发同样按通道：尺寸偏差且 AX 可用 → AX 精确写（不再重复 yabai --resize）。
// 另：AX 臂每次 yabai move 之后读回一次（`applyMoveKeepingPreciseSize`），尺寸被
// yabai 缓存宽高盖回则立即 AX 补写——补发 move 时同样适用。

import Foundation

/// 段一的执行计划（纯决策，Runner FrameWriteExecutor 域锁定）。
///
/// 三臂语义见文件头「三臂策略」表。等待语义刻意区分三档：
/// - `.combined`：单条消息写全帧，不存在「第一段已生效、第二段未生效」的中间态；
/// - `.axPrecise`：AX 通道——写原语自带读回，只需给 yabai 的 frame 缓存留一个节拍；
/// - `.yabaiPolled`：yabai 两段历史路径——fork 返回 ≠ 已应用，必须轮询到可观测。
enum FramePhase1Plan: Equatable {
    /// 单条 yabai 消息写全帧（--move + --resize），零段间等待。
    case combined
    /// AX 精确尺寸 + yabai move。resizeFirst 沿用历史写序语义
    /// （收窄/还原 resize→move，放大 move→resize）。
    ///
    /// 两臂的段间等待刻意不同：
    /// - resizeFirst：AX 写原语自带读回（返回即生效），只需固定 settleMs 让 yabai 的
    ///   frame 缓存跟上，随后发 move——**零轮询**（用户主诉的 300ms 停顿来源）；
    /// - !resizeFirst（放大）：move 后窗口必须先在目标屏落地，否则紧随的 AX size 写会被
    ///   **源屏可视区 clamp**（历史实测 1079 被钳到副屏可见 1055）。这里等到 origin
    ///   可观测（节拍 settleMs、预算 moveSettleBudgetMs、早满足早返回），比历史
    ///   300ms 预算短一个量级，clamp 防护不丢。
    case axPrecise(resizeFirst: Bool, settleMs: UInt32, moveSettleBudgetMs: UInt32)
    /// yabai 两段 + 段间轮询（order 决定先后）。
    case yabaiPolled(order: FrameWriteOrder)

    /// 是否走原子合发（供 RunOutcome 计时/日志）。
    var isCombined: Bool { self == .combined }

    /// 是否按「等到位」轮询段间（只有历史两段路径需要）。
    var pollsBetweenPhases: Bool {
        if case .yabaiPolled = self { return true }
        return false
    }

    /// 决策唯一事实源。
    ///
    /// 优先级刻意如此：**尺寸精度 > 单次 fork**。合发省下的是几十毫秒 fork 与一次轮询，
    /// 而绕过 AX 尺寸通道的代价是「还原到错误尺寸且永久不收敛」（用户主诉，frameOK=false
    /// 反复重试仍 664）。
    ///
    /// - Parameters:
    ///   - axPreciseSize: 尺寸可走 AX 精确写（AX 元素可写**且**尚未被证明吞写）。
    ///   - combinedAvailable: 调用方提供了合发通道（yabai 可用且未显式关闭）。
    ///   - order: 写序（历史语义：收窄/还原 resize 先行，放大 move 先行）。
    ///   - axSettleMs: AX 通道的段间固定节拍（WindowSettle.axPhaseSettleMs）。
    ///   - moveSettleBudgetMs: 放大序 move 后等落地再写 AX size 的预算
    ///     （WindowSettle.axMoveThenResizeWaitBudgetMs）。
    static func decide(
        axPreciseSize: Bool,
        combinedAvailable: Bool,
        order: FrameWriteOrder,
        axSettleMs: UInt32,
        moveSettleBudgetMs: UInt32
    ) -> FramePhase1Plan {
        if axPreciseSize {
            return .axPrecise(
                resizeFirst: order == .resizeThenMove,
                settleMs: axSettleMs,
                moveSettleBudgetMs: moveSettleBudgetMs)
        }
        if combinedAvailable { return .combined }
        return .yabaiPolled(order: order)
    }
}

/// 两段写入执行编排（Batch 3）。非隔离：deps 闭包由调用方（@MainActor 域）构造，
/// 本类型只同步调用它们，不持状态。
struct FrameWriteExecutor {

    struct Deps {
        /// CGWindowList 读回（热路径禁 AX frame）。
        let read: () -> CGRect?
        /// 原点写（恒 yabai --move abs，跨屏唯一可靠通道）。
        let applyMove: () -> Void
        /// 尺寸写·择优通道（AX 同屏写，一轮不收敛自动降级 yabai）。
        let applyResizeAdaptive: () -> Void
        /// 尺寸写·最稳通道（纯 yabai --resize abs，全缺计划且无 AX 时使用）。
        let applyResizeRobust: () -> Void
        /// 原子合发（yabai 单条消息内 --move + --resize）。nil = 通道不支持，退回两段。
        let applyCombined: (() -> Void)?
        /// 尺寸此刻是否仍可走 AX 精确通道（**实时**求值：AX 写一次失败即降级，
        /// 补发随之改走 yabai——不拿旧快照反复撞死胡同）。
        let axPreciseSize: () -> Bool

        init(
            read: @escaping () -> CGRect?,
            applyMove: @escaping () -> Void,
            applyResizeAdaptive: @escaping () -> Void,
            applyResizeRobust: @escaping () -> Void,
            applyCombined: (() -> Void)? = nil,
            axPreciseSize: @escaping () -> Bool = { false }
        ) {
            self.read = read
            self.applyMove = applyMove
            self.applyResizeAdaptive = applyResizeAdaptive
            self.applyResizeRobust = applyResizeRobust
            self.applyCombined = applyCombined
            self.axPreciseSize = axPreciseSize
        }
    }

    struct RunOutcome {
        let outcome: FrameWriteOutcome
        /// 补发次数 = write 总调用数 − 收敛轮数（停滞重发不换轮）。
        let resendCount: Int
        let convergedRounds: Int
        let phase1Ms: Int
        let phase2ConvergeMs: Int
        /// 段一走了原子合发（单次写全帧，无段间等待）。
        let combinedPhase1: Bool
        /// 段一的实际计划（日志/测试归因；2026-11-23）。
        let phase1Plan: FramePhase1Plan
    }

    let deps: Deps
    let tolerance: CGFloat
    let op: String
    let stage: String
    let windowID: UInt32
    /// 轮询睡眠（产线 usleep；测试注入空操作以虚拟时间跑满预算分支）。
    let pollSleep: (UInt32) -> Void
    /// AX 通道的段间固定节拍（区分于 pollSleep：这是**无条件**短睡，让 yabai 的进程内
    /// frame 缓存跟上 AX 写；测试可注入独立计数断言其被调用与时长）。
    let phaseSettle: (UInt32) -> Void

    init(
        deps: Deps,
        tolerance: CGFloat,
        op: String,
        stage: String,
        windowID: UInt32,
        pollSleep: @escaping (UInt32) -> Void = { usleep(useconds_t($0) * 1_000) },
        phaseSettle: ((UInt32) -> Void)? = nil
    ) {
        self.deps = deps
        self.tolerance = tolerance
        self.op = op
        self.stage = stage
        self.windowID = windowID
        self.pollSleep = pollSleep
        // 默认与 pollSleep 同源（生产同为 usleep）；测试可注入独立计数。
        self.phaseSettle = phaseSettle ?? pollSleep
    }

    /// 段一计划（暴露给调用方做日志归因）。
    func phase1Plan(order: FrameWriteOrder) -> FramePhase1Plan {
        FramePhase1Plan.decide(
            axPreciseSize: deps.axPreciseSize(),
            combinedAvailable: deps.applyCombined != nil,
            order: order,
            axSettleMs: WindowSettle.axPhaseSettleMs,
            moveSettleBudgetMs: WindowSettle.axMoveThenResizeWaitBudgetMs
        )
    }

    /// 执行两段写入并收敛验证。返回结果与分段计时（供调用方 segment timing 汇总日志）。
    func run(target: CGRect, order: FrameWriteOrder) -> RunOutcome {
        let plan = phase1Plan(order: order)
        let combined = deps.applyCombined
        let phase1Start = Date()
        switch plan {
        case .combined:
            if let applyCombined = combined {
                applyCombined()
            } else {
                // 计划说能合发但入口没给闭包（不可达的防御臂）：退回两段轮询。
                runYabaiPolledPhases(order: order, target: target)
            }
        case .axPrecise(let resizeFirst, let settleMs, let moveSettleBudgetMs):
            if resizeFirst {
                // 尺寸先精确到位（AX 写原语自带读回），短节拍让 yabai 缓存跟上，再落位。
                deps.applyResizeAdaptive()
                if settleMs > 0 { phaseSettle(settleMs) }
                applyMoveKeepingPreciseSize(target: target)
            } else {
                // 放大：先落位（否则 AX size 写被源屏可视区 clamp），等 origin 可观测
                // 再写尺寸（节拍 settleMs / 预算 moveSettleBudgetMs / 早满足早返回）。
                deps.applyMove()
                waitForPhase("move", intervalMs: settleMs, budgetMs: moveSettleBudgetMs) {
                    !FrameConvergence.shortfalls(current: deps.read(), target: target, tolerance: tolerance).contains(.origin)
                }
                deps.applyResizeAdaptive()
            }
        case .yabaiPolled(let polledOrder):
            runYabaiPolledPhases(order: polledOrder, target: target)
        }
        let phase1Ms = elapsedMilliseconds(since: phase1Start)

        let phase2Start = Date()
        var attemptNo = 0
        let outcome = FrameConvergence.convergeFramePolling(
            attempts: 2,
            intervalMs: WindowSettle.frameVerifyPollIntervalMs,
            budgetMs: WindowSettle.frameVerifyBudgetMs,
            write: {
                attemptNo += 1
                let shortfall = FrameConvergence.shortfalls(current: deps.read(), target: target, tolerance: tolerance)
                let segments = FrameConvergence.resendSegments(shortfall: shortfall, order: order)
                // 全缺 + 通道支持合发 + 无 AX 精确尺寸 → 一次写全帧（补发同样不拆两段）。
                let axPrecise = deps.axPreciseSize()
                if segments.count == 2, let applyCombined = combined, !axPrecise {
                    applyCombined()
                } else {
                    for segment in segments {
                        switch segment {
                        case .move:
                            // AX 精确通道下每次 move 都要守住尺寸：yabai 的 --move 会用
                            // 缓存宽高再写一次 size（吸附值），位置补发同样可能抹掉精确尺寸。
                            if axPrecise {
                                applyMoveKeepingPreciseSize(target: target)
                            } else {
                                deps.applyMove()
                            }
                        case .resize:
                            // 2026-11-23：尺寸补发优先 AX 精确通道——yabai 的 --resize
                            // 对字符网格吸附的终端窗口永远收敛不到目标值，重复发它只是
                            // 原地打转（664→664，用户主诉的「frameOK 恒 false」）。
                            if axPrecise {
                                deps.applyResizeAdaptive()
                            } else if segments.count == 2 {
                                deps.applyResizeRobust()
                            } else {
                                deps.applyResizeAdaptive()
                            }
                        }
                    }
                }
                // yabai 写不返回硬失败（exit code 吞掉，最终以读回判据为准）。
                return true
            },
            read: deps.read,
            isConverged: { FrameConvergence.shortfalls(current: $0, target: target, tolerance: tolerance).isEmpty },
            stallResendReads: 4,
            sleep: pollSleep
        )
        let phase2ConvergeMs = elapsedMilliseconds(since: phase2Start)

        let convergedRounds: Int
        switch outcome {
        case .converged(let attempt, _):
            convergedRounds = attempt
        case .mismatched(let attempts, _):
            convergedRounds = attempts
        case .writeFailed(let attempt):
            convergedRounds = attempt
        }
        return RunOutcome(
            outcome: outcome,
            resendCount: max(0, attemptNo - convergedRounds),
            convergedRounds: convergedRounds,
            phase1Ms: phase1Ms,
            phase2ConvergeMs: phase2ConvergeMs,
            combinedPhase1: plan.isCombined && combined != nil,
            phase1Plan: plan
        )
    }

    /// AX 精确尺寸 + yabai move 的收尾：move 会用它进程内缓存的宽高再写一次 size
    /// （见文件头「问题一」），可能把刚写好的精确尺寸盖回吸附值。这里读一次回
    /// （CGWindowList，零 fork），若尺寸重新偏差且 AX 通道仍可用，**立即**用 AX 补写
    /// 一次——不等段二轮询，视觉上仍是一次跳变。
    private func applyMoveKeepingPreciseSize(target: CGRect) {
        deps.applyMove()
        // 读回 + 补写只在「尺寸确实被盖回」时发生；正常路径（yabai 缓存已跟上）零额外写。
        guard let afterMove = deps.read(), deps.axPreciseSize() else { return }
        guard FrameConvergence.shortfalls(
            current: afterMove,
            target: target,
            tolerance: tolerance
        ).contains(.size) else { return }
        deps.applyResizeAdaptive()
    }

    /// 历史两段路径：写序 + 段间 waitForPhase 轮询（fork 返回 ≠ 已应用）。
    private func runYabaiPolledPhases(order: FrameWriteOrder, target: CGRect) {
        switch order {
        case .resizeThenMove:
            deps.applyResizeAdaptive()
            waitForPhase("resize") {
                !FrameConvergence.shortfalls(current: deps.read(), target: target, tolerance: tolerance).contains(.size)
            }
            deps.applyMove()
        case .moveThenResize:
            deps.applyMove()
            waitForPhase("move") {
                !FrameConvergence.shortfalls(current: deps.read(), target: target, tolerance: tolerance).contains(.origin)
            }
            deps.applyResizeAdaptive()
        }
    }

    /// 段间等待：轮询第一段效果可观测（早满足早返回），超时只告警不失败——最终由
    /// 段二的收敛轮询如实裁决（历史行为）。节拍/预算由调用臂注入（历史两段 25ms/300ms，
    /// AX 放大序 25ms/axMoveThenResizeWaitBudgetMs）。
    private func waitForPhase(
        _ label: String,
        intervalMs: UInt32 = WindowSettle.frameVerifyPollIntervalMs,
        budgetMs: UInt32 = WindowSettle.framePhaseVerifyBudgetMs,
        observed: @escaping () -> Bool
    ) {
        let outcome = ConditionPolling.waitUntil(
            intervalMs: intervalMs,
            budgetMs: budgetMs,
            sleep: pollSleep,
            condition: observed
        )
        if !outcome.satisfied {
            log("[WindowManager] moveWindowToFrameViaYabai: phase \(label) verify exhausted", level: .warn, fields: [
                "op": op, "stage": stage, "windowID": String(windowID),
                "intervalMs": String(intervalMs), "budgetMs": String(budgetMs),
                "budgetName": budgetMs == WindowSettle.framePhaseVerifyBudgetMs
                    ? "framePhaseVerify" : "axMoveThenResize"
            ])
        }
    }
}
