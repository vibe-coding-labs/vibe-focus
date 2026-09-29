import Foundation

/// 提交自动归位的 toggle 记录资格门。
///
/// ## 最终语义（2026-09-29 凌晨用户裁决第四次收敛 + 当晚第五次收敛/0.0.92）
/// **提交归位与记录来源无关**：存在 toggle 记录且新鲜（≤30 分钟）且窗口不在原位
/// → 归位资格成立。手动 ⌃Q 拉上去 → 回车 → 窗**终将**回副屏 是既定承诺
/// （9-15/9-29 两度明示）。本轮 0.0.90 的「手动摆位粘滞」实测拦掉 9 次真实提交
/// 归位（17:00~17:39Z 日志铁证），当日即回退。
/// **0.0.93 延迟归位（终局时机）**：当晚两度裁决——先「正在输入时被拽回=无法
/// 正常使用」（39 次/小时日志实锤），0.0.92 失焦保持装机后即刻被否（「提交之后
/// 不会自动恢复了」，开关承诺被违背）→ 定案「提交后 ~3 秒归位，气泡正开着输入
/// 则顺延」。本门裁决的**资格**不变，**执行时机**由 SubmitRestoreDeferral 承担；
/// 超时效 → 执行点判 expired 不归位。
///
/// ## 9-28 主诉「莫名拽回」的真凶与本门的分工
/// 主诉的病灶不是「提交归位」本身，而是三类病态路径，由下列门承担：
/// - **记录时效窗**：超 30 分钟的记录不再驱动归位（12:35 案：几小时前的记录 +
///   self-heal 绑定 = 窗口跳回很久前的位置；Stop→读结果→提交 的正常分钟级节奏
///   不受影响）；
/// - **已在原位短路**：窗口当前帧已等于记录 origFrame = 记录陈旧（消费完成未
///   清理），无需任何移动仅清理（12:35 案 6 秒逐窗 focus 空转的根治点）；
/// - **双通道在途去重**（RestoreInFlightRegistry，0.0.92 起 mark 移到执行点）：
///   气泡提交与注入回车引发的 UPS 不再背靠背跑两遍全量管线。
/// 「UPS 永不搬窗」红线不动（本门只裁决是否回原位，不裁决拉主屏）。
///
/// ## 钟摆史（供后续会话理解，勿再单方向推翻）
/// B126(9-11 userPlacedSkip) → 65a1ad2(9-16 有记录即归位) → 0.0.90(9-28 手动粘滞，
/// 实测回归) → 0.0.91(9-29 来源无关 + 时效 + 短路) → 0.0.92(9-29 失焦归位) →
/// 0.0.93(9-29 延迟 3 秒 + 气泡输入顺延)。争议事件的全量取证在
/// docs/log-audit-2026-09-29.md。
enum AutoRestoreRecordGate: Equatable {
    /// 无记录
    case none
    /// 时效内 + 不在原位 → 可自动归位（任何来源：manual_hotkey / claude_session_end /
    /// agent_command）
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
