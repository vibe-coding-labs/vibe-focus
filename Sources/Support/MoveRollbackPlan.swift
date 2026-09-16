import Foundation

/// B193 残窗防护决策表（纯函数，Runner 直测）。
///
/// 移动管线失败后，凡「窗已被动过」且有移动前快照，必须回写原帧——
/// 真机实锤（move-00000824，2026-09-17 00:28）：Stop 拉主屏对窗 690 两轮收敛
/// 失败，读回 102,143 263x216（目标 82,38 1646x1079，sizeDrift=2246），窗以
/// 错乱尺寸留在屏幕上——即用户反复投诉的「窗口大小、位置完全错乱」（此类
/// 残窗在 Stop 触发开着的岁月里反复出现）。原则：**宁可没移动，不可留残窗**。
enum MoveRollbackPlan {

    enum Decision: Equatable {
        /// 回写原帧（帧为移动前快照）。
        case rollback(frame: CGRect)
        /// 无需回滚（移动成功 / 窗未被改过 / 无快照可回）。
        case skip
    }

    /// - Parameters:
    ///   - movedOK: 移动是否成功（成功不回滚）。
    ///   - didModifyWindow: 管线是否已对窗发起过任何改动（float/apply/space 移动）；
    ///     false 时窗从未被动过，失败只是「没干活」，无残窗可言。
    ///   - origFrame: 移动前帧快照（nil = 无回滚目标，如实跳过）。
    static func decide(movedOK: Bool, didModifyWindow: Bool, origFrame: CGRect?) -> Decision {
        guard !movedOK, didModifyWindow, let origFrame else { return .skip }
        return .rollback(frame: origFrame)
    }
}
