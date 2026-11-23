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
    static func decide(
        axPreciseSize: Bool,
        axPreciseMove: Bool,
        combinedAvailable: Bool,
        order: FrameWriteOrder,
        axSettleMs: UInt32,
        moveSettleBudgetMs: UInt32
    ) -> FramePhase1Plan {
        if axPreciseSize, axPreciseMove {
            return .axFull(
                resizeFirst: order == .resizeThenMove,
                settleMs: axSettleMs,
                moveSettleBudgetMs: moveSettleBudgetMs)
        }
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

    /// 位置写：优先「AX 直写 + 读回校验」，不达标当场回退 `applyMove`。
    ///
    /// 返回值 = **是否发生了到 `applyMove` 的回退**（调用方据此决定是否需要补写尺寸：
    /// yabai 的 --move 会用缓存宽高覆盖 size，而 AX 通道自己的 applyMove 不会）。
    ///
    /// - 未提供 `applyMovePrecise`（nil）→ `applyMove` 就是该通道的位置原语（AX 直写
    ///   通道即如此），不算回退，返回 false；
    /// - 提供但 `axPreciseMove()` 已转 false（此前失败过）→ 直接走 `applyMove`，
    ///   也算回退（此时 yabai 语义可能成立，补尺寸是安全的多一层）。
    ///
    /// 注意**不能**在这里无条件补写 AX size——放大序的 size 还没写（写序
    /// move→resize），提前补写反而会被源屏可视区 clamp。由调用方按写序决定。
    @discardableResult
    private func moveFrame() -> Bool {
        guard let precise = deps.applyMovePrecise else {
            deps.applyMove()
            return false
        }
        if deps.axPreciseMove(), precise() { return false }
        deps.applyMove()
        return true
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
        let combined = deps.applyCombined
        let phase1Start = Date()
        var phase1FellBackToYabaiMove = false
        switch plan {
        case .combined:
            if let applyCombined = combined {
                applyCombined()
            } else {
                // 计划说能合发但入口没给闭包（不可达的防御臂）：退回两段轮询。
                runYabaiPolledPhases(order: order, target: target)
            }
        case .axFull(let resizeFirst, let settleMs, let moveSettleBudgetMs):
            // 双向单步：尺寸与位置都走 AX，两次 AX 写背靠背（各 ~30ms），
            // 没有 yabai fork、没有「先缩小再跳屏」的中间可见态。
            //
            // 写序仍按历史语义（收窄/还原 resize→move，放大 move→resize），因为
            // WindowServer 对**单次** AX 写的可见区约束没有变；差别只在两次写之间
            // 不再经过 yabai（fork 82~322ms + 缓存尺寸覆盖）。
            //
            // 收窄/还原序（resize→move）：AX resize 原语自带读回验证（返回即已生效），
            // 紧随的 move 也走 AX —— 不使用 yabai 的进程内 frame 缓存，因此这里
            // **不需要**任何段间睡眠。两次 AX 写真正背靠背，是一帧内的跳变。
            //
            // （axPrecise 臂仍保留 settleMs：那条臂的 move 走 yabai，yabai 会用缓存
            //   宽高覆盖尺寸，需要给它一个节拍让 AX 通知把缓存更新过来。）
            //
            // 放大序（2026-11-23 回退）：**必须**先 move 后 resize。
            //
            // ## 为什么试过的「先试终态」被撤回（真机实证，用户投诉「来回跳来跳去」）
            // 曾改成「先 resize，读回不达标再回落」，理由是 AX 写自带读回、clamp 可观测。
            // 真机上这造成明显的多次跳变：
            //   1. 窗口还在副屏时写 1079 高 → 被副屏可视区钳到 1055，
            //      **窗口在副屏上先变大一次**（用户看到的第 1 跳）；
            //   2. 读回判未到位 → 回落再 move（第 2 跳）→ 再 resize（第 3 跳）。
            // 「可观测」只保证最终值对，保证不了**中间不产生可见变化**——而后者才是
            // 用户关心的。跨屏 clamp 无法预防，只能靠写序避开（历史 move→resize 的
            // 原意）。已在源屏被钳的窗口还白付一次尺寸写与一次读回。
            if resizeFirst {
                deps.applyResizeAdaptive()
                if moveFrame() {
                    phase1FellBackToYabaiMove = true
                }
                if phase1FellBackToYabaiMove, deps.axPreciseSize() {
                    // 位置降级到 yabai move 时，yabai 会用缓存宽高把刚写好的精确尺寸
                    // 覆盖掉（问题一）——立刻补写回 AX 精确值。
                    deps.applyResizeAdaptive()
                }
            } else {
                if moveFrame() { phase1FellBackToYabaiMove = true }
                waitForPhase("move", intervalMs: settleMs, budgetMs: moveSettleBudgetMs) {
                    !FrameConvergence.shortfalls(current: deps.read(), target: target, tolerance: tolerance).contains(.origin)
                }
                deps.applyResizeAdaptive()
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
                let axMove = deps.applyMovePrecise != nil && deps.axPreciseMove()
                if segments.count == 2, let applyCombined = combined, !axPrecise {
                    applyCombined()
                } else {
                    for segment in segments {
                        switch segment {
                        case .move:
                            if axMove {
                                // 全 AX 臂：位置补发同样走 AX（yabai 只要碰位置就会用缓存
                                // 宽高覆盖尺寸，等于把刚修好的 640 又抹成 664）。
                                if moveFrame(), axPrecise {
                                    // 降级到 yabai move 了：尺寸被缓存宽高覆盖，补写回精确值。
                                    deps.applyResizeAdaptive()
                                }
                            } else if axPrecise {
                                // 位置只能走 yabai 时，每次 move 都要守住尺寸（同上原因）。
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
            phase1Plan: plan,
            phase1WriteSteps: Self.phase1WriteSteps(
                plan: plan, didFallBackToYabaiMove: phase1FellBackToYabaiMove)
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
