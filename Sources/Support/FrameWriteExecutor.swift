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
// - phase1 按写序执行：resizeThenMove = adaptive resize → 等 size 收敛 → move；
//   moveThenResize = move → 等 origin 收敛 → adaptive resize；
// - 阶段等待超时只告警不失败——最终由段二收敛轮询如实裁决（历史行为）；
// - 段二补发计划 = resendSegments(shortfalls, order)；执行器差异：单 .resize 走
//   adaptive（AX/yabai 择优），计划含两段（全缺）时 resize 走 robust 纯 yabai——
//   「大漂移用最稳通道」的历史行为；
// - attempts=2、stallResendReads=4、轮询/预算常量取自 WindowSettle（与历史一致）。

import Foundation

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
        /// 尺寸写·最稳通道（纯 yabai --resize abs，全缺计划使用）。
        let applyResizeRobust: () -> Void
    }

    struct RunOutcome {
        let outcome: FrameWriteOutcome
        /// 补发次数 = write 总调用数 − 收敛轮数（停滞重发不换轮）。
        let resendCount: Int
        let convergedRounds: Int
        let phase1Ms: Int
        let phase2ConvergeMs: Int
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
        let phase1Start = Date()
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
                for segment in segments {
                    switch segment {
                    case .move:
                        deps.applyMove()
                    case .resize:
                        if segments.count == 2 { deps.applyResizeRobust() } else { deps.applyResizeAdaptive() }
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
            phase2ConvergeMs: phase2ConvergeMs
        )
    }

    /// 段间等待：轮询第一段效果可观测（早满足早返回），超时只告警不失败——最终由
    /// 段二的收敛轮询如实裁决（历史行为）。
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
