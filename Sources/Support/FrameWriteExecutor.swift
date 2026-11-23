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
// - 段一恒为「按写序两段 + 段间等生效」（FramePhase1Plan 只有一条路径）；
// - 阶段等待超时只告警不失败——最终由段二收敛轮询如实裁决（历史行为）；
// - 段二补发计划 = resendSegments(shortfalls, order)；**尺寸**补发优先 AX（可用时），
//   位置补发恒走 yabai；全缺两段且 AX 不可用时 resize 走 robust 纯 yabai；
// - attempts=2、stallResendReads=4、轮询/预算常量取自 WindowSettle（与历史一致）。
//
// ## 尺寸精度问题（2026-11-23 溯源，必读）
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

/// 段一的执行计划。
///
/// ## 2026-11-23 收敛：只剩一条路径
/// 曾按通道分三种臂（合发 / 全 AX / 尺寸 AX），逐一被真机否掉（见文件头）。现在
/// 恒为 `.yabaiPolled`——保留枚举而非删类型，是因为调用方要用它做日志归因
/// （`phase1PlanName`）与「是否轮询段间」的判定。
enum FramePhase1Plan: Equatable {
    /// yabai 两段 + 段间轮询（order 决定先后）。**唯一**在用的形态。
    case yabaiPolled(order: FrameWriteOrder)

    /// 是否按「等到位」轮询段间。
    var pollsBetweenPhases: Bool { true }

    /// 决策唯一事实源：恒返回两段等生效。
    ///
    /// ## 为什么没有「更好」的选项（三条硬约束，都有源码/真机证据）
    /// 1. yabai `--move` 用**进程内缓存宽高**重写一次 size（window_manager.c:342
    ///    → set_window_frame 三写）→ 位置只要经 yabai，尺寸必被覆盖一次。
    /// 2. iTerm2 在「位置+尺寸同时变」时按字符网格重算（640→664）；只改尺寸时精确。
    /// 3. 裸 AX **跨屏** position 写被 WindowServer 钳回源屏（+AXWrite.swift 头注）。
    ///
    /// 三条互斥 → 跨屏且改尺寸时「一步完成」在物理上不存在。历史各版尝试：
    /// 合发（一步但 664）/ 全 AX 位置（跨屏被钳 → 回退 → 来回跳）/ 先试终态（三跳）/
    /// 单次写不等读回（仍跳）——全部回退。
    static func decide(order: FrameWriteOrder) -> FramePhase1Plan {
        .yabaiPolled(order: order)
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
        /// 尺寸此刻是否仍可走 AX 精确通道（写失败即降级，补发改走 yabai）。
        let axPreciseSize: () -> Bool

        init(
            read: @escaping () -> CGRect?,
            applyMove: @escaping () -> Void,
            applyResizeAdaptive: @escaping () -> Void,
            applyResizeRobust: @escaping () -> Void,
            axPreciseSize: @escaping () -> Bool = { false }
        ) {
            self.read = read
            self.applyMove = applyMove
            self.applyResizeAdaptive = applyResizeAdaptive
            self.applyResizeRobust = applyResizeRobust
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

    init(
        deps: Deps,
        tolerance: CGFloat,
        op: String,
        stage: String,
        windowID: UInt32,
        pollSleep: @escaping (UInt32) -> Void = { usleep(useconds_t($0) * 1_000) }
    ) {
        self.deps = deps
        self.tolerance = tolerance
        self.op = op
        self.stage = stage
        self.windowID = windowID
        self.pollSleep = pollSleep
    }

    /// 执行两段写入并收敛验证。返回结果与分段计时（供调用方 segment timing 汇总日志）。
    func run(target: CGRect, order: FrameWriteOrder) -> RunOutcome {
        let plan = FramePhase1Plan.decide(order: order)
        let phase1Start = Date()
        runYabaiPolledPhases(order: order, target: target)
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
                // 补发策略（2026-11-23 收敛）：
                // - **尺寸**补发优先 AX（yabai 的 --resize 对字符网格吸附的终端永远
                //   回到 664，重复发只是原地打转）——这是唯一保住尺寸精度的通道。
                //   注：e16de7b 在全缺时走 robust（纯 yabai）会退回 664；此处改为
                //   AX 可用即走 adaptive，是该缺陷的修复。只在「未收敛」的异常路径
                //   触发（正常一次到位不进这里），不产生额外可见变化。
                // - **位置**补发只走 yabai（跨屏唯一验证过的通道）；
                // - 位置写完**不**额外补写尺寸：yabai 会用缓存宽高覆盖一次，但那发生在
                //   同一轮内、紧随其后的尺寸补发会修正它；若再插一次补写就多一跳。
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
            phase1Plan: plan
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
    /// 段二的收敛轮询如实裁决（历史行为）。节拍 25ms / 预算 300ms 取自 WindowSettle。
    private func waitForPhase(_ label: String, observed: @escaping () -> Bool) {
        let outcome = ConditionPolling.waitUntil(
            intervalMs: WindowSettle.frameVerifyPollIntervalMs,
            budgetMs: WindowSettle.framePhaseVerifyBudgetMs,
            sleep: pollSleep,
            condition: observed
        )
        if !outcome.satisfied {
            log("[WindowManager] moveWindowToFrameViaYabai: phase \(label) verify exhausted", level: .warn, fields: [
                "op": op, "stage": stage, "windowID": String(windowID),
                "budgetMs": String(WindowSettle.framePhaseVerifyBudgetMs)
            ])
        }
    }
}
