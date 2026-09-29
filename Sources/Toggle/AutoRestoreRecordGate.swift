import Foundation

/// 提交自动归位的 toggle 记录资格门。
///
/// ## 最终语义（2026-09-30 凌晨用户裁决，第八次收敛：**按记录来源分流**）
/// - **agent 拉来的窗**（记录 reason=claude_session_end / agent_command）：提交归位
///   保留——Stop 召唤→审查→提交→回副屏 的核心承诺不变；
/// - **用户 ⌃Q 亲手摆的窗**（reason=manual_hotkey）：提交**不拽**（manualPlacement）。
///
/// ## 为什么推翻 0.0.91 的「来源无关」（两次裁决的真实对账）
/// - 0.0.90「粘滞」被回退，是因为它拦掉了 9 次「⌃Q 拉上去后回车」场景的归位
///   （当时用户裁「原来这个功能还是可以的」）；但 **2026-09-30 00:49-00:57Z 铁证**：
///   同一场景用户三循环对抗（⌃Q 拉窗→提交→被拽回→2 秒后再 ⌃Q→再被拽回），随后
///   怒斥「又发生了一次莫名其妙的跳」。两次裁决冲突时，以「全场景自适应」收口：
///   不做单方向开关，按**最后一次移动的来源**这个运行时事实自动分流——agent 线
///   归位承诺原样保留，用户手动摆位不再被拽。
/// - 与 0.0.90 的本质区别：**零粘性状态**——只读当前记录自己的 reason 字段
///   （记录只由真实移动创建、restore 成功即清除），没有跨提交的 skip 标记，
///   不存在「粘住后续 agent 归位」的回归面。
///
/// ## 其余三门不动（9-28 主诉病态路径的既有承担者）
/// - **记录时效窗**（expired，>30min，只管 agent 来源）：超时效记录不再驱动归位；
/// - **已在原位短路**（alreadyAtOriginalFrame）：窗口当前帧已等于 origFrame 仅清理；
/// - **双通道在途去重**（RestoreInFlightRegistry）：气泡提交与注入回车引发的 UPS
///   不再背靠背跑两遍全量管线。
/// 「UPS 永不搬窗」红线不动（本门只裁决是否回原位，不裁决拉主屏）。
///
/// ## 钟摆史（供后续会话理解；全量取证 docs/log-audit-2026-09-29.md 第八轮）
/// B126(9-11 userPlacedSkip) → 65a1ad2(9-16 有记录即归位) → 0.0.90(9-28 手动粘滞，
/// 拦 9 次被回退) → 0.0.91(9-29 来源无关+时效+短路) → 0.0.92(失焦归位，被否) →
/// 0.0.93(延迟 3 秒，被否) → 0.0.94(9-29 深夜：提交瞬间归位=0.0.91 执行形态) →
/// 0.0.95(9-30 凌晨：Terminal.app ⌃Q 支持拍) → **0.0.96(本版：来源分流——
/// agent 拉的归位、用户摆的不拽)**。
enum AutoRestoreRecordGate: Equatable {
    /// 无记录
    case none
    /// agent 来源（claude_session_end / agent_command 等）+ 时效内 + 不在原位 → 可自动归位
    case eligible
    /// 用户 ⌃Q 亲手摆位（manual_hotkey）→ 提交不拽（⌃Q 手动还原不受影响）
    case manualPlacement
    /// 超时效记录（agent 来源）→ 不再驱动自动归位
    case expired
    /// 窗口已在记录原位 → 无需移动（陈旧记录，调用方负责清理）
    case alreadyAtOriginalFrame

    /// 记录时效窗（秒）。
    static let maxRecordAgeSeconds: TimeInterval = 30 * 60

    /// 纯判定：给定记录与窗口当前帧，归类资格。
    /// currentFrame 传 nil（查询失败/调用方不做几何检测）时跳过「已在原位」检测，
    /// 保守按时效裁决——不因查询失败扩大豁免面。
    /// 判序：已在原位（含手动记录的清理语义）→ 手动摆位（来源主导，先于时效）→
    /// 时效 → eligible。
    static func evaluate(
        record: ToggleRecord?,
        now: Date,
        currentFrame: CGRect?,
        tolerance: CGFloat,
        maxAge: TimeInterval = maxRecordAgeSeconds
    ) -> AutoRestoreRecordGate {
        guard let record else { return .none }
        if let currentFrame,
           CoordinateKit.originDrift(currentFrame.origin, record.origFrame.origin) <= tolerance,
           CoordinateKit.isSizeConverged(actual: currentFrame.size, target: record.origFrame.size, tolerance: tolerance) {
            return .alreadyAtOriginalFrame
        }
        if record.reason == WindowMoveReason.manualHotkey.rawValue { return .manualPlacement }
        if now.timeIntervalSince(record.toggledAt) > maxAge { return .expired }
        return .eligible
    }
}
