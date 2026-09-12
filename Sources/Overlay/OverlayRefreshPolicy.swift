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
/// 3. `forceRefreshDecision`：去重与挂起都只免 overlay 重活，不吞 space-state 广播——
///    B162（2026-09-11）：挂起 return 在广播之前，minimap 停格 → 广播任何分支照发；
///    B175（2026-09-12）：挂起不再把事件刷新降级为 broadcastOnly——「设置窗持焦
///    期间 overlay 本就隐藏」前提不成立（overlay 从不因设置窗持焦隐藏，多屏独立
///    Spaces 下另一屏角标全程可见），实测挂起期间切工作区角标停格 7.2s
///    （挂起 5.2s + 恢复后 Timer 相位 2s）。挂起只治理兜底 Timer 的周期 fork。
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

    /// triggerForceRefresh 两分支判定结果（B175 起；旧 skipDuplicate/broadcastAndRefresh
    /// 三分支退役——skipDuplicate 整单丢弃会让 minimap 错过最后一次切换且无 yabai 收益）。
    enum ForceRefreshDecision: Equatable {
        /// 连发重复（距上次真实刷新 < minInterval）：免 overlay 重活（清缓存+重刷），
        /// 广播照发（零 yabai fork，接收方 400ms 防抖 + 单次 querySpaces 自愈）——
        /// minimap 不许因去重停格。
        case broadcastOnly
        /// 非重复：广播 + overlay 缓存清理与重刷。挂起（设置窗持焦/toggle）不降级：
        /// 事件驱动的索引刷新是「真相展示」，可见的角标不许为旧值停留（B175 契约）。
        case refreshAndBroadcast
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
    ///     只治理兜底 Timer 的周期 fork（见 refreshGate），不参与本判定——SIGUSR1
    ///     到达时 yabai 状态已稳态，fast path 单次 query 即真相，挂起期间照常全量
    ///     刷新。此参数保留是为让四象限契约锁死「挂起不降级事件刷新」（B175），
    ///     防止降级语义回归。
    ///   - duplicate: 距上次真实 overlay 刷新不足 minInterval（连发第二道闸）。
    ///     去重只免重活不吞广播（B175 起）。
    static func forceRefreshDecision(suspended: Bool, duplicate: Bool) -> ForceRefreshDecision {
        if duplicate { return .broadcastOnly }
        return .refreshAndBroadcast
    }
}
