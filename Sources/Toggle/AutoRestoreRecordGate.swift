import Foundation

/// 提交自动归位的 toggle 记录资格门。
///
/// ## 最终语义（2026-09-30 第十次收敛：**普适归位 + 焦点跟随**）
/// 存在 toggle 记录（不论来源：manual_hotkey / claude_session_end / agent_command）
/// 且新鲜（≤30 分钟）且窗口不在原位 → 提交一律回原位。
///
/// ## 0.0.96 来源分流为何只活了 4 小时（两次裁决的真实对账与化解）
/// 0.0.96 按「用户 ⌃Q 摆的窗不拽」分流（半夜 00:49-00:57Z 三循环对抗的产物）；
/// 但 04:29-04:32Z 日志显示用户的真实节奏是 **⌃Q 拉上→气泡发送→2 秒后自己 ⌃Q
/// 送回**——分流的豁免把「送回」这步还给了用户手脚，用户裁「提交后不归位=BUG」。
/// 与半夜暴怒对账后的本质认识：**用户否的从来不是归位本身，而是「窗飞走焦点被
/// 摔给随机 app」的断崖感**（0.0.98 已修：归位时焦点跟随窗口回副屏，不再有
/// 「窗消失我在原地懵逼」）。故撤掉来源豁免，归位承诺普适恢复，与焦点跟随组合
/// 成一个顺滑动作；若半夜式不适复发，杠杆在归位后的焦点体验而非停掉归位。
///
/// ## 三门不动（9-28 主诉病态路径的既有承担者）
/// - **记录时效窗**（expired，>30min）：超时效记录不再驱动归位；
/// - **已在原位短路**（alreadyAtOriginalFrame）：窗口当前帧已等于 origFrame 仅清理；
/// - **双通道在途去重**（RestoreInFlightRegistry）：气泡提交与注入回车引发的 UPS
///   不再背靠背跑两遍全量管线。
/// 「UPS 永不搬窗」红线不动（本门只裁决是否回原位，不裁决拉主屏）。
///
/// ## 钟摆史（供后续会话理解；全量取证 docs/log-audit-2026-09-29.md 各轮）
/// B126(9-11 userPlacedSkip) → 65a1ad2(9-16 有记录即归位) → 0.0.90(9-28 手动粘滞，
/// 拦 9 次被回退) → 0.0.91(9-29 来源无关+时效+短路) → 0.0.92(失焦归位，被否) →
/// 0.0.93(延迟 3 秒，被否) → 0.0.94(提交瞬间归位) → 0.0.95(Terminal.app ⌃Q 拍) →
/// 0.0.96(来源分流：agent 拉的归位、用户摆的不拽) → 0.0.97(文案对齐) →
/// 0.0.98(AX 判据+焦点跟随) → **0.0.99(本版：撤豁免恢复普适归位——焦点跟随已
/// 化解半夜式断崖，钟摆的两端在「归位带着焦点走」下合一)**。
enum AutoRestoreRecordGate: Equatable {
    /// 无记录
    case none
    /// 时效内 + 不在原位 → 可自动归位（不论来源）
    case eligible
    /// 超时效记录 → 不再驱动自动归位（⌃Q 手动还原不受影响）
    case expired
    /// 窗口已在记录原位 → 无需移动（陈旧记录，调用方负责清理）
    case alreadyAtOriginalFrame

    /// 记录时效窗（秒）。
    static let maxRecordAgeSeconds: TimeInterval = 30 * 60

    /// 纯判定：给定记录与窗口当前帧，归类资格。
    /// currentFrame 传 nil（查询失败/调用方不做几何检测）时跳过「已在原位」检测，
    /// 保守按时效裁决——不因查询失败扩大豁免面。
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
        if now.timeIntervalSince(record.toggledAt) > maxAge { return .expired }
        return .eligible
    }
}
