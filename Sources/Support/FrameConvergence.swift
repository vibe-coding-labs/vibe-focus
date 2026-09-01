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
}
