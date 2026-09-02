// FrameConvergence.swift
// VibeFocus — 帧写入收敛循环唯一骨架（write → settle → read → 判据 → 不收敛重写）
// 收敛此前 3 文件各写一份的平行循环（playbook 2.16a 第十四刀）：
//   moveWindowToFrameViaYabai（yabai abs 直写版）/ writeSizeWithReadback（AX size 版）/
//   verifyAndCorrectPostMoveSize rewrite 循环（AX size 兜底版）。
// 收敛判据唯一事实源为 CoordinateKit 漂移和系列（2.16a 第十二刀），
// 等待时长唯一事实源为 WindowSettle 常量表（2.16 第九刀）。

import Foundation
import Darwin

/// convergeFrame 一轮的结局。converged 携带首次达标轮次与实际读回 frame；
/// mismatched 携带耗尽轮次与最后一次成功读回（全程读失败则为 nil）；
/// writeFailed 表示写入原语硬失败（如 AX 错误码），当轮的 settle/read 不再执行。
enum FrameWriteOutcome: Equatable {
    case converged(attempt: Int, frame: CGRect)
    case mismatched(attempts: Int, lastFrame: CGRect?)
    case writeFailed(attempt: Int)
}

/// move/resize 两段写入的顺序决策（纯函数，FrameWriteOrderTests 分支穷尽锁定）。
///
/// ## 场景（2026-09-03 跨屏乱蹦修复）
/// yabai `--move abs` 与 `--resize abs` 是两条命令，先后生效之间存在中间态窗口
/// （一条已生效、另一条未生效）。若中间态窗口的中心落在**第三方 display**，macOS
/// 会把窗口归属划给那块屏几百 ms（实测主→副 restore：1649×1079 全屏窗先 --move 到
/// 副屏坐标，中心越过两块副屏的边界落屏 C，~320ms 后 --resize 才落回屏 B——用户
/// 感知为「先蹦到错误的屏再蹦回来」+ 读回重试的连续卡顿）。顺序按尺寸关系自适应，
/// 使中间态中心只会在源屏或目标屏：
/// - 收窄（当前尺寸大于目标任一维度）：先 resize 再 move——收窄后的中间态小于目标，
///   仍被源屏当前位置包含；
/// - 放大/持平：先 move 再 resize——move 后的中间态小于目标，被目标 frame 包含
///   （目标 frame 本身完整落在目标屏内）。
enum FrameWriteOrder: Equatable {
    case resizeThenMove
    case moveThenResize
}

/// 帧写入收敛循环唯一骨架。
///
/// ## 语义契约（FrameConvergenceLoopTests 锁定）
/// - 每轮严格 write → settle → read → 判据：读回必须等写落定，settle 不跳过；
/// - 读失败视为本轮未收敛，继续下一轮重试（不提前放弃——读回原语偶发 nil 不该终止收敛）；
/// - 写硬失败（write 返回 false）立即短路，当轮不再 settle/read；
/// - attempts 归一为 max(1, attempts)，防 `1...0` 越界崩溃；
/// - 判据与 settle 时长由调用点注入：判据用 CoordinateKit 漂移和系列，
///   settle 用 WindowSettle 常量；写机制（yabai/AX）与读机制（CGWindowList/AX）同为调用点策略。
enum FrameConvergence {

    /// float 重摆落定等待（等稳定代等固定，2026-09-03 流畅度第二刀）。
    ///
    /// ## 场景
    /// `--toggle float` 后 yabai 会默认重摆 float 窗口，过早写目标 frame 会被重摆覆盖
    /// （2026-09-01 尺寸错乱根因）。固定睡 300ms 是重摆耗时的上界保护，实际多数
    /// 100~150ms 即稳定——改为「先睡下限（防重摆未启动的静默误判），再轮询 frame
    /// 稳定（连续两读漂移在容差内）早返回」，总预算兜底不变。
    ///
    /// ## 语义契约（Tests/Runner 分支穷尽锁定）
    /// - 先无条件睡 minSettleMicros（重摆启动前的静默窗口，下限内两次读相等 ≠ 已稳定）；
    /// - 之后每 intervalMs 读一次：本次与上次读回漂移达标（isSame）即返回；
    /// - 读失败（nil）不终止、清空 prev（下一对相等才稳定）；下限后从未稳定则走满总预算；
    /// - 总等待（下限+轮询）不超过 minSettle+budget；无稳定性信号时退化为固定等待。
    static func waitForRelayout(
        minSettleMicros: useconds_t,
        intervalMs: UInt32,
        budgetMs: UInt32,
        read: () -> CGRect?,
        isSame: (CGRect, CGRect) -> Bool,
        sleep: (useconds_t) -> Void = { usleep($0) },
        pollSleep: (UInt32) -> Void = { usleep(useconds_t($0) * 1_000) }
    ) {
        sleep(minSettleMicros)
        var waitedMs: UInt32 = 0
        var prev = read()
        while waitedMs < budgetMs {
            let nap = min(intervalMs, budgetMs - waitedMs)
            pollSleep(nap)
            waitedMs += nap
            let current = read()
            if let p = prev, let c = current, isSame(p, c) {
                return
            }
            prev = current
        }
    }

    /// 写入顺序决策：按当前尺寸与目标尺寸的关系选两段写入的先后（见 FrameWriteOrder 场景注释）。
    /// currentSize 读不到（CGWindowList 偶发 nil）时沿用历史顺序 move→resize（防御分支，
    /// 中间态行为退回修复前，不比现状更差）。
    ///
    /// sourceVisibleSize = 窗口**当前所在 display** 的可视区尺寸（2026-09-03 clamp 修复）：
    /// yabai 对窗口所在屏之外的 `--resize abs` 会把尺寸钳到该屏可视区——收窄序（resize
    /// 先行）在「目标任一维超源屏可见区」时必被钳住（实测副→主 move_to_main：1079 高
    /// 被钳到副屏可见 1055，且后续重写只补发 move，永不收敛，MOVE FAILED 走满 2s）。
    /// 此类场景改走 moveThenResize，resize 在窗口落目标屏后补发，clamp 不触发。
    static func writeOrder(
        currentSize: CGSize?,
        targetSize: CGSize,
        sourceVisibleSize: CGSize? = nil
    ) -> FrameWriteOrder {
        guard let current = currentSize else { return .moveThenResize }
        let shrinking = current.width > targetSize.width || current.height > targetSize.height
        guard shrinking else { return .moveThenResize }
        if let vis = sourceVisibleSize,
           targetSize.width > vis.width || targetSize.height > vis.height {
            return .moveThenResize
        }
        return .resizeThenMove
    }

    static func convergeFrame(
        attempts: Int,
        settleMicros: useconds_t,
        write: () -> Bool,
        read: () -> CGRect?,
        isConverged: (CGRect) -> Bool,
        sleep: (useconds_t) -> Void = { usleep($0) }
    ) -> FrameWriteOutcome {
        let totalAttempts = max(1, attempts)
        var lastFrame: CGRect? = nil
        for attempt in 1...totalAttempts {
            guard write() else { return .writeFailed(attempt: attempt) }
            sleep(settleMicros)
            guard let actual = read() else { continue }
            lastFrame = actual
            if isConverged(actual) {
                return .converged(attempt: attempt, frame: actual)
            }
        }
        return .mismatched(attempts: totalAttempts, lastFrame: lastFrame)
    }

    /// 帧写入收敛循环轮询版：write → 轮询读（intervalMs 节拍、budgetMs 预算，早满足早返回）
    /// → 预算内未收敛重写下一段。
    ///
    /// ## 场景（2026-09-03 restore「水中移动」优化）
    /// convergeFrame 固定 settle（400ms）在写早已落定时是纯等待——fork 返回 ≠ 已生效
    /// 的延迟上界才是 400ms，实际多数几十 ms 即落定。轮询版每 intervalMs 读一次，
    /// 一收敛立即返回，预算兜底不变；yabai 路径实测 move 阶段 550ms → ~250ms。
    ///
    /// ## 语义契约（Tests/Runner 分支穷尽锁定）
    /// - 首查在首睡之前（写后立即读，零等待收敛路径不付任何睡眠）；
    /// - 读失败（nil）视为未收敛继续轮询，不终止本轮；
    /// - 预算内收敛 → .converged(attempt:)；预算耗尽 → 重写（下一 attempt）；
    /// - 写硬失败短路 .writeFailed(attempt:)；attempts 归一 max(1, attempts)；
    /// - 轮询耗尽全程未读到 → .mismatched 携带 nil frame。
    static func convergeFramePolling(
        attempts: Int,
        intervalMs: UInt32,
        budgetMs: UInt32,
        write: () -> Bool,
        read: () -> CGRect?,
        isConverged: (CGRect) -> Bool,
        sleep: (UInt32) -> Void = { usleep(useconds_t($0) * 1_000) }
    ) -> FrameWriteOutcome {
        let totalAttempts = max(1, attempts)
        var lastFrame: CGRect? = nil
        for attempt in 1...totalAttempts {
            guard write() else { return .writeFailed(attempt: attempt) }
            var waitedMs: UInt32 = 0
            while true {
                if let actual = read() {
                    lastFrame = actual
                    if isConverged(actual) {
                        return .converged(attempt: attempt, frame: actual)
                    }
                }
                if waitedMs >= budgetMs { break }
                let nap = min(intervalMs, budgetMs - waitedMs)
                sleep(nap)
                waitedMs += nap
            }
        }
        return .mismatched(attempts: totalAttempts, lastFrame: lastFrame)
    }
}
