import Foundation

/// Overlay 刷新门与去重判定（纯函数命名空间，非 @MainActor——与 ScreenHotplugGuard
/// 同款的 Overlay 域纯策略层，Batch 12 从 ScreenOverlayManager+Refresh/+Signal 的
/// 内联守卫提取）。
///
/// ## 为什么存在
/// 刷新风暴是 Overlay 的历史事故类（SIGUSR1 连发 / toggle 连续触发的 force refresh
/// 堆积占用 yabai 单进程）。防风暴的两道门此前内联在编排函数里，语义只活在现场；
/// 提取为纯判定后由镜像 + Runner 双锁穷尽锁定，编排层只做门结果分派。
///
/// ## 门序契约（OverlayRefreshPolicyTests 穷尽锁定）
/// 1. `refreshGate`：suspend 先于 enabled——「已 suspend 且非 force」最优先短路
///    （toggle 期间的自动刷新抑制，P3.6 语义）；force 穿透 suspend 但不穿透
///    disabled（用户关掉 overlay 后任何刷新都不该发生）。
/// 2. `isDuplicateForceTrigger`：距上次触发不足 minInterval 视为重复触发丢弃
///    （SIGUSR1 连发的第二道闸）。
enum OverlayRefreshPolicy {

    /// refreshSpaceIndices 入口门判定结果。
    enum GateDecision: Equatable {
        /// 已 suspend 且非 force：toggle 等编排方抑制期间，自动刷新静默跳过。
        case skipSuspended
        /// 用户偏好关闭 overlay：一切刷新跳过（force 也不豁免）。
        case skipDisabled
        /// 放行。
        case proceed
    }

    /// - Parameters:
    ///   - suspended: 自动刷新抑制中（toggle 等编排入口 suspend/resume 对）。
    ///   - enabled: 用户偏好 overlay 总开关。
    ///   - force: 强制刷新（穿透 suspend，不穿透 disabled）。
    static func refreshGate(suspended: Bool, enabled: Bool, force: Bool) -> GateDecision {
        if suspended && !force { return .skipSuspended }
        if !enabled { return .skipDisabled }
        return .proceed
    }

    /// force refresh 去重：距上次触发不足 minInterval 视为连发重复，丢弃。
    /// 恰好等于间隔（>=）不算重复。
    static func isDuplicateForceTrigger(lastTriggerAt: Date, now: Date, minInterval: TimeInterval) -> Bool {
        now.timeIntervalSince(lastTriggerAt) < minInterval
    }
}
