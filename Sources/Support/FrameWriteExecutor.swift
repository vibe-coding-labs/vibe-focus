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
// 还原场景实测 300~378ms。**这段等待保留**：它是 fork 返回 ≠ 已应用的必要同步
// （e16de7b 实证：去掉它会在窗台/尺寸尚未落定时发第二段，产生中间态）。
//
// ### 当前策略（2026-11-23 收敛：恒走历史两段 + 段间等生效）
//
// 真机反复投诉后确认：跨屏且要改尺寸时**一步完成在物理上不存在**（三条硬约束见
// FramePhase1Plan.decide 的注释）。因此本执行器回到 e16de7b 的形态：
// | 段一 | 段间 | 段二 |
// |---|---|---|
// | resize→move（收窄）或 move→resize（放大） | waitForPhase 等第一段可观测 | 收敛轮询 + 按偏差补发 |
//
// - **尺寸**补发优先 AX（yabai 的 --resize 对字符网格吸附的终端永远回到 664）；
// - **位置**只走 yabai（跨屏唯一验证过的通道）；
// - 位置补发后不紧跟尺寸补写（多一跳）；精度由段二的 AX 尺寸补发保证。
//
// 曾试过并被真机否掉的：原子合发（尺寸被吸附成 664）、全 AX 位置（跨屏被钳回 →
// 降级 yabai = 来回跳）、放大序先试终态（源屏先放大被钳 → 三跳）、AX resize
// 单次写不等读回（与 extra 补写叠加后仍跳）。全部撤回，`FramePhase1Plan.decide`
// 恒返回 `.yabaiPolled`。

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

    /// **全 AX 臂**（2026-11-23 双向单步修复）：尺寸与位置都由 App 直写 AX，零 yabai
    /// fork、零段间意义等待——两次 AX 写背靠背（各 ~30ms），视觉上是一次跳变。
    ///
    /// ## 为什么需要它（结构性的，不是优化）
    /// yabai 的 `--move abs` 会用**它进程内缓存的宽高**重新写一次 size
    /// （window_manager.c:342 → set_window_frame 三写）。只要位置经 yabai，尺寸就
    /// 必然被它覆盖一遍 → 「精确尺寸 + 跨屏移动」天生需要**第二次**尺寸写 →
    /// 视觉两步。要一步到位，位置也必须离开 yabai。
    ///
    /// ## 为什么敢用（与 tiled 窗口的区别）
    /// 历史上「裸 AX 跨屏 position 写被 clamp」是 **tiled（yabai 管理）窗口被 re-tile
    /// 对抗**的教训；本通道的调用点（restore / move_to_main / stuck）**恒先 float 脱管**。
    /// AX 直写通道真机探针（2026-09-29，一次性 Terminal 实例）实测：浮动窗口跨屏
    /// position 写 39ms 落地、size 写 33ms，未被 clamp。
    ///
    /// ## 不赌硬件：写后立即读回校验，不达标当场回退 yabai move
    /// `applyPreciseMove` 返回 Bool（内部写完读回，origin 漂移在容差内才 true）。
    /// false → 本臂原地改走 yabai move（行为退回 `axPrecise` 臂，不比现状差）。
    case axFull(resizeFirst: Bool, settleMs: UInt32, moveSettleBudgetMs: UInt32)
    /// yabai 两段 + 段间轮询（order 决定先后）。
    case yabaiPolled(order: FrameWriteOrder)

    /// 是否走原子合发（供 RunOutcome 计时/日志）。
    var isCombined: Bool { self == .combined }

    /// 是否按「等到位」轮询段间（只有历史两段路径需要）。
    var pollsBetweenPhases: Bool {
        if case .yabaiPolled = self { return true }
        return false
    }

    /// 是否走了「位置也由 AX 直写」的全 AX 臂（双向单步）。
    var isAXFull: Bool {
        if case .axFull = self { return true }
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
    ///   - axPreciseMove: 位置也可走 AX 直写（浮动窗跨屏 position 写；见 `.axFull`）。
    ///   - combinedAvailable: 调用方提供了合发通道（yabai 可用且未显式关闭）。
    ///   - order: 写序（历史语义：收窄/还原 resize 先行，放大 move 先行）。
    ///   - axSettleMs: AX 通道的段间固定节拍（WindowSettle.axPhaseSettleMs）。
    ///   - moveSettleBudgetMs: 放大序 move 后等落地再写 AX size 的预算
    ///     （WindowSettle.axMoveThenResizeWaitBudgetMs）。
    ///
    /// ## 优先级（双向单步，2026-11-23）
    /// 1. 位置与尺寸都能 AX → `.axFull`：**唯一能真正一步到位**的臂（yabai 只要参与
    ///    位置写，就会用缓存宽高覆盖尺寸 → 必然两次写）。写后读回不达标由执行器当场
    ///    回退 yabai move，不赌硬件。
    /// 2. 只有尺寸能 AX → `.axPrecise`（尺寸精度保住，位置仍走 yabai：两次写，但
    ///    段间从 300ms 轮询降到 25ms 节拍）。
    /// 3. 都不能 → `.combined`（单条 yabai 消息；尺寸会被终端网格吸附，是最后的
    ///    容量通道）；合发也关闭 → 历史两段。
    /// ## 2026-11-23 收敛：回到「两段 + 等生效」（用户真机背书的形态）
    ///
    /// 真机反复投诉「来回跳」后，逐条溯源得到的**硬约束**（都有源码或真机证据）：
    /// 1. yabai `--move` 会用**进程内缓存的宽高**重写一次 size（window_manager.c:342
    ///    → set_window_frame 三写）→ 位置只要经 yabai，尺寸必被覆盖一次。
    /// 2. iTerm2 在「位置+尺寸同时变」时按字符网格重算 → 640 被吸成 664；只改尺寸时
    ///    精确接受 640。
    /// 3. 裸 AX **跨屏** position 写被 WindowServer 钳回源屏（+AXWrite.swift 头注 +
    ///    真机「来回跳」实证）→ 跨屏位置只能走 yabai。
    ///
    /// 三条合起来是一个死结：跨屏且要改尺寸时，**一步完成在物理上不存在**。
    /// 只能二选一：
    /// - 先精确缩放（源屏）→ 再跨屏落位 = 两步，但尺寸精确、无回跳（e16de7b 实证正确）；
    /// - 一条消息同时移动+缩放 = 一步，但终端尺寸被吸附成 664（5e0b288 实证错误）。
    ///
    /// 2026-11-21~23 之间的各版尝试（合发 / 全 AX / 先试终态 / 单次写）各自解锁了一项
    /// 指标又打破另一项，全部已撤回。当前**恒走历史两段 + 段间等生效**：它不跳、
    /// 尺寸对，代价是段间等待（那是可调的，跳不是）。
    static func decide(
        axPreciseSize: Bool,
        axPreciseMove: Bool,
        combinedAvailable: Bool,
        order: FrameWriteOrder,
        axSettleMs: UInt32,
        moveSettleBudgetMs: UInt32
    ) -> FramePhase1Plan {
        _ = (axPreciseMove, combinedAvailable, axSettleMs, moveSettleBudgetMs)
        return .yabaiPolled(order: order)
    }
}

/// 两段写入执行编排（Batch 3）。非隔离：deps 闭包由调用方（@MainActor 域）构造，
/// 本类型只同步调用它们，不持状态。
struct FrameWriteExecutor {

    struct Deps {
        /// CGWindowList 读回（热路径禁 AX frame）。
        let read: () -> CGRect?
        /// 原点写（yabai --move abs — 历史通道，也是全 AX 臂的回退）。
        let applyMove: () -> Void
        /// 原点写·AX 直写（浮动窗跨屏 position 写）。返回「写完读回 origin 是否达标」。
        /// nil = 该窗口没有可用 AX 位置通道（AX 元素缺失/不可写）。
        let applyMovePrecise: (() -> Bool)?
        /// 尺寸写·择优通道（AX 同屏写，一轮不收敛自动降级 yabai）。
        let applyResizeAdaptive: () -> Void
        /// 尺寸写·最稳通道（纯 yabai --resize abs，全缺计划且无 AX 时使用）。
        let applyResizeRobust: () -> Void
        /// 原子合发（yabai 单条消息内 --move + --resize）。nil = 通道不支持，退回两段。
        let applyCombined: (() -> Void)?
        /// 尺寸此刻是否仍可走 AX 精确通道（**实时**求值：AX 写一次失败即降级，
        /// 补发随之改走 yabai——不拿旧快照反复撞死胡同）。
        let axPreciseSize: () -> Bool
        /// 位置此刻是否仍可走 AX 直写（与 applyMovePrecise 成对；写失败即降级）。
        let axPreciseMove: () -> Bool

        init(
            read: @escaping () -> CGRect?,
            applyMove: @escaping () -> Void,
            applyResizeAdaptive: @escaping () -> Void,
            applyResizeRobust: @escaping () -> Void,
            applyCombined: (() -> Void)? = nil,
            applyMovePrecise: (() -> Bool)? = nil,
            axPreciseSize: @escaping () -> Bool = { false },
            axPreciseMove: @escaping () -> Bool = { false }
        ) {
            self.read = read
            self.applyMove = applyMove
            self.applyResizeAdaptive = applyResizeAdaptive
            self.applyResizeRobust = applyResizeRobust
            self.applyCombined = applyCombined
            self.applyMovePrecise = applyMovePrecise
            self.axPreciseSize = axPreciseSize
            self.axPreciseMove = axPreciseMove
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
        /// 段一**实际**的帧写入步数（1 = 单步跳变，2 = 两步）。
        ///
        /// 这是给真机验收用的唯一事实字段：计划是「应该几步」，这里是「实际发了几次
        /// 会改变窗口可见状态的写」。两者不等的唯一情形是 `.axFull` 的 AX 位置写被
        /// 系统钳住、当场降级到 yabai move（此时实际 = 2，且另有 warn 日志）。
        let phase1WriteSteps: Int
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
            axPreciseMove: deps.applyMovePrecise != nil && deps.axPreciseMove(),
            combinedAvailable: deps.applyCombined != nil,
            order: order,
            axSettleMs: WindowSettle.axPhaseSettleMs,
            moveSettleBudgetMs: WindowSettle.axMoveThenResizeWaitBudgetMs
        )
    }

    /// 段一实际帧写入步数（日志验收字段，见 RunOutcome.phase1WriteSteps）。
    ///
    /// 只数「会改变窗口可见位置/尺寸的写」，口径：
    /// - `.combined`：1（单条 yabai 消息内部连写两段，用户眼里一次跳变）；
    /// - `.axFull`：位置经 AX 实际生效 = 1（尺寸+位置各一次 AX 写，但同一帧内完成）；
    ///   位置降级到 yabai move = 2（yabai 会用缓存宽高再写一次尺寸）；
    /// - `.axPrecise`：2（尺寸走 AX、位置走 yabai，中间隔着一次 yabai fork）；
    /// - `.yabaiPolled`：2。
    static func phase1WriteSteps(plan: FramePhase1Plan, didFallBackToYabaiMove: Bool) -> Int {
        switch plan {
        case .combined:
            return 1
        case .axFull:
            return didFallBackToYabaiMove ? 2 : 1
        case .axPrecise, .yabaiPolled:
            return 2
        }
    }

    /// 执行两段写入并收敛验证。返回结果与分段计时（供调用方 segment timing 汇总日志）。
    func run(target: CGRect, order: FrameWriteOrder) -> RunOutcome {
        let plan = phase1Plan(order: order)
        let phase1Start = Date()
        // 2026-11-23 收敛：只走历史两段 + 段间等生效（e16de7b 的实证正确形态）。
        // 其余臂保留为防御性兜底（decide 已恒返回 yabaiPolled），不参与正常路径。
        switch plan {
        case .combined, .axFull, .axPrecise:
            runYabaiPolledPhases(order: order, target: target)
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
                // 补发策略（2026-11-23 收敛，回到「不跳」的形态）：
                // - **尺寸**补发优先 AX（yabai 的 --resize 对字符网格吸附的终端永远
                //   回到 664，重复发只是原地打转）——这是唯一保住尺寸精度的通道；
                // - **位置**补发只走 yabai（跨屏唯一验证过的通道）；
                // - 位置写完**不**额外补写尺寸：yabai 会用缓存宽高覆盖一次，但那次覆盖
                //   发生在同一轮内、紧随其后的尺寸补发会修正它；若在这一步再插一次补写，
                //   就变成「move → resize → resize」多一跳（真机「来回跳」的来源之一）。
                for segment in segments {
                    switch segment {
                    case .move:
                        deps.applyMove()
                    case .resize:
                        if deps.axPreciseSize() {
                            deps.applyResizeAdaptive()
                        } else if segments.count == 2 {
                            deps.applyResizeRobust()
                        } else {
                            deps.applyResizeAdaptive()
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
            combinedPhase1: false,   // 恒走两段路径（见 decide 收敛注释）
            phase1Plan: plan,
            // 恒走历史两段路径（见 decide 的收敛注释）→ 固定 2。
            phase1WriteSteps: 2
        )
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
