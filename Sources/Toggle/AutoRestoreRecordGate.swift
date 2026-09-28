import Foundation

/// 提交自动归位的 toggle 记录资格门（2026-09-28 日志审计批）。
///
/// ## 为什么修订 9-16 的「有记录即归位」
/// 2026-09-16（65a1ad2）为一致性退役了 B126 的 userPlacedSkip。2026-09-28 生产日志
/// 审计（docs/log-audit-2026-09-29.md）实锤两 类伤害：①四天 43 次 UPS 拽回中过半是
/// 「用户手动 ⌃Q 摆位后正常提交 prompt」被拽回副屏（15:12~15:16 连续两轮拉回-拽回
/// 实录）；②陈旧记录（窗口早已回家）仍驱动全量 restore 管线空转（12:35 实录：6 秒
/// 逐窗 focus 带动切空间全败 + 视图被带跳）。修订语义：
/// - **手动摆位粘滞**：manual_hotkey 记录不被任何自动链 Undo（气泡提交与直接回车
///   一致跳过）；⌃Q 再按一次仍可手动还原——9-15 的一致性诉求以「一致跳过」满足；
/// - **记录时效窗**：超 30 分钟的记录不再驱动自动归位（覆盖 Stop→读结果→提交 的
///   正常分钟级节奏，掐掉「几小时前 ⌃Q/Stop 拉过」的陈旧凭证）；
/// - **已在原位短路**：窗口当前帧已等于记录 origFrame = 记录陈旧（消费完成未清理），
///   无需任何移动，仅清理。
/// 自动化来源（Stop 拉回 claude_session_end / 命令 API agent_command）时效窗内
/// 行为不变。「UPS 永不搬窗」红线不动（本门只裁决是否回原位，不裁决拉主屏）。
enum AutoRestoreRecordGate: Equatable {
    /// 无记录
    case none
    /// 自动化来源 + 时效内 + 不在原位 → 可自动归位
    case eligible
    /// 手动 ⌃Q 摆位记录 → 粘滞，自动链不 Undo
    case manualPlacement
    /// 超时效记录 → 不再驱动自动归位
    case expired
    /// 窗口已在记录原位 → 无需移动（陈旧记录，调用方负责清理）
    case alreadyAtOriginalFrame

    /// 记录时效窗（秒）。
    static let maxRecordAgeSeconds: TimeInterval = 30 * 60

    /// 纯判定：给定记录与窗口当前帧，归类资格。
    /// currentFrame 传 nil（查询失败/调用方不做几何检测）时跳过「已在原位」检测，
    /// 保守按来源/时效裁决——不因查询失败扩大豁免面。
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
