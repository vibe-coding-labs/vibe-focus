import Foundation

// MARK: - Restore 决策层（纯判定，编排见 +Restore.swift）
// 文件分层（2026-09-07 拆分，行为不变）：
//   +Restore+Decision.swift（本文件） — 结局类型 + record 处置/源屏预切回纯决策
//   +Restore.swift                    — 视角守卫 + 生产入口 + performRestore 编排
// 全部声明为纯函数/纯类型（无 IO、无实例状态），分支穷尽锁定于
// Tests/Runner performRestore 分支穷举双通道锁定；本拆分为纯代码搬移，锁不失效。

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

    /// 4-pre fresh 拓扑裁决（2026-11-03）：`sourceSpace` 已是按 display-local
    /// 序号回译后的**当次拓扑目标**（RestoreSpaceTargetResolver 产物）。
    ///
    /// 与旧决策的差异只在「可观测性是否可信」：
    /// - 显示不在 fresh 拓扑 / 目标 space 不在该显示 → `.targetUnresolvable`
    ///   （不盲切、不谎报精确）；
    /// - 可见 space 未知（拓扑里有该屏但没有 is-visible 项）→ `.switchNeeded(nil)`：
    ///   切回命令幂等，尝试一次比默认「已精确」诚实；spaceExact 由切后轮询裁决。
    enum FreshSourceSpacePreSwitch: Equatable {
        /// record 无 space/display 上下文
        case noContext
        /// 目标显示/space 在 fresh 拓扑里无法定位（拔屏/索引漂移）——不可判定
        case targetUnresolvable
        /// 源屏可见 space 已等于目标
        case notNeeded
        /// 需要切回；visibleSpace=nil 表示可见性未知（仍尝试幂等切回）
        case switchNeeded(visibleSpace: Int?)
    }

    static func freshSourceSpacePreSwitch(
        sourceSpace: Int,
        targetDisplay: Int?,
        displayInTopology: Bool,
        spaceOnDisplay: Bool,
        visibleSpaceOnSourceDisplay: Int?
    ) -> FreshSourceSpacePreSwitch {
        guard sourceSpace > 0, let targetDisplay, targetDisplay > 0 else { return .noContext }
        guard displayInTopology, spaceOnDisplay else { return .targetUnresolvable }
        if visibleSpaceOnSourceDisplay == sourceSpace { return .notNeeded }
        return .switchNeeded(visibleSpace: visibleSpaceOnSourceDisplay)
    }

    /// move 后落位裁决（2026-11-03）：地面真值优先。
    /// - 落位与目标都可知 → 相等才精确；
    /// - 任一未知 → 沿用预切回结论（绝不把未知伪装成精确）。
    static func landingSpaceExact(preSwitch: Bool?, landedSpace: Int?, targetSpace: Int?) -> Bool? {
        guard let landedSpace, let targetSpace else { return preSwitch }
        return landedSpace == targetSpace
    }
}
