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
/// ## 门序契约（RunnerRegistryStoreTests overlayGate 块穷尽锁定）
/// 1. `refreshGate`：suspend 先于 enabled——「已 suspend 且非 force」最优先短路
///    （toggle 期间的自动刷新抑制，P3.6 语义）；force 穿透 suspend 但不穿透
///    disabled（用户关掉 overlay 后任何刷新都不该发生）。
/// 2. `isDuplicateForceTrigger`：距上次触发不足 minInterval 视为重复触发丢弃
///    （SIGUSR1 连发的第二道闸）。
/// 3. `forceRefreshDecision`：重复去重只保护 overlay 重活，不吞 space-state 广播——
///    挂起期间（设置窗持焦）广播必须照发：编排页 minimap 恰在此时依赖它自愈
///    （2026-09-11 用户报告「已切工作区、minimap 高亮停格」根因 = 挂起 return
///    在广播之前，SIGUSR1/toggle 变化永远到不了设置页）。
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

    /// triggerForceRefresh 三分支判定结果。
    enum ForceRefreshDecision: Equatable {
        /// 连发重复且未挂起：整单丢弃（不广播、不刷新——与历史语义一致）。
        case skipDuplicate
        /// 挂起中（设置窗持焦等）：只发 vibefocusSpaceStateMayHaveChanged 广播，
        /// overlay 重活（清缓存+重刷+follow-up）跳过——overlay 此时本就隐藏，
        /// 广播接收方自带 400ms 防抖与轻量重建。
        case broadcastOnly
        /// 常态：广播 + overlay 缓存清理与重刷。
        case broadcastAndRefresh
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

    /// - Parameters:
    ///   - suspended: 自动刷新抑制中（设置窗持焦/toggle 等编排入口 suspend 期间）。
    ///   - duplicate: 距上次真实 overlay 刷新不足 minInterval（连发第二道闸）。
    /// 挂起时不去重、也不推进去重时钟：广播本身零 yabai fork（接收方 400ms 防抖 +
    /// 重建仅单次 querySpaces），且恢复后首个信号应尽快触发真实 overlay 刷新。
    static func forceRefreshDecision(suspended: Bool, duplicate: Bool) -> ForceRefreshDecision {
        if duplicate && !suspended { return .skipDuplicate }
        return suspended ? .broadcastOnly : .broadcastAndRefresh
    }
}
