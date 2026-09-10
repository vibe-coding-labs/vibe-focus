import Foundation

// MARK: - Restore 决策层（纯判定，编排见 +Restore.swift）
// 文件分层（2026-09-07 拆分，行为不变）：
//   +Restore+Decision.swift（本文件） — 结局类型 + record 处置/源屏预切回纯决策
//   +Restore.swift                    — 视角守卫 + 生产入口 + performRestore 编排
// 全部声明为纯函数/纯类型（无 IO、无实例状态），分支穷尽锁定于
// Tests/Runner performRestore 分支穷举双通道锁定；本拆分为纯代码搬移，锁不失效。

@MainActor
extension ToggleEngine {

    /// restore 的真实结局（record 处置与审计事件的唯一依据）。
    enum RestoreOutcome: Equatable {
        /// frame 已收敛：窗口回到源屏 origFrame。spaceExact：
        ///   true  = 源屏可见 space 已精确等于 sourceSpace；
        ///   false = 源屏切回失败（源 space 无可聚焦窗口等），窗口落在源屏可见 space；
        ///   nil   = record 无 space 信息（sourceSpace=0），从未尝试切回。
        case restored(spaceExact: Bool?)
        /// 移动前的放弃：无 toggle record / AX 窗口已不存在。record 不动、无审计事件
        /// （与历史行为一致；不是移动失败，别把语义让给 moveFailed*）。
        case aborted(reason: String)
        /// frame 未收敛但 origFrame 仍在某块现有屏上——瞬时失败（yabai 抖动/窗口最小化等）。
        /// record 保留：用户再次触发 restore 即重试。
        case moveFailedRetryable
        /// frame 未收敛且 origFrame 已不在任何屏幕（断显/分辨率变更）——永久失败。
        /// record 清除：下次 toggle 走 stuck 解堵路径兜底，避免每次热键空转整段恢复耗时。
        case moveFailedPermanent

        /// 机器可读结局标签（WindowManager 失败日志与 CrashContextRecorder 用；
        /// RunnerRegistryStoreTests 序列锁分支穷尽）。
        var outcomeLabel: String {
            switch self {
            case .restored(let spaceExact):
                return "restored(spaceExact=\(String(describing: spaceExact)))"
            case .aborted(let reason):
                return "aborted_\(reason)"
            case .moveFailedRetryable:
                return "move_failed_retryable_record_kept"
            case .moveFailedPermanent:
                return "move_failed_permanent_record_cleared"
            }
        }
    }

    /// 失败时 record 处置的纯决策（RunnerRegistryStoreTests retryable 直测锁定）。
    /// origFrame 中心仍落在某块现有屏上 → 瞬时失败保留 record；已不在任何屏 → 清除。
    static func isMoveFailureRetryable(origFrameOnAnyDisplay: Bool) -> Bool {
        origFrameOnAnyDisplay
    }

    /// 4-pre 源屏预切回决策（纯函数，RunnerRegistryStoreTests preSwitch 直测锁定）。
    enum SourceSpacePreSwitch: Equatable {
        /// record 无 space/display 上下文（0 值）——无从预切，spaceExact=nil。
        case noContext
        /// 源屏可见 space 已是 sourceSpace；或可见性查询失败（不盲切，历史行为视作
        /// 已精确）——无需切换，spaceExact=true。
        case notNeeded
        /// 源屏停在别的 space——需要预切回 sourceSpace；spaceExact=切回是否成功。
        case switchNeeded(visibleSpace: Int)
    }

    static func sourceSpacePreSwitch(
        sourceSpace: Int,
        sourceYabaiDisp: Int,
        visibleSpaceOnSourceDisplay: Int?
    ) -> SourceSpacePreSwitch {
        guard sourceSpace > 0, sourceYabaiDisp > 0 else { return .noContext }
        guard let visible = visibleSpaceOnSourceDisplay else { return .notNeeded }
        return visible == sourceSpace ? .notNeeded : .switchNeeded(visibleSpace: visible)
    }
}
