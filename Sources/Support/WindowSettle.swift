// WindowSettle.swift
// VibeFocus — 窗口落定等待时长表（微秒）
// 收敛此前散落 4 文件 7 处的裸 usleep 魔法数（playbook 2.16 第九刀）。
// 数值本身为实测经验值，改动必须走真实窗口闭环验证（2.15 教训：
// 2026-09-01 toggle 尺寸错乱根因即 float 后等待不足、写被 yabai 重摆覆盖）。

import Foundation

/// 窗口操作各阶段的落定等待时长。语义分两级：
/// yabai 级（float 重摆/abs 写，数百 ms）与 WindowServer 级（AX 写后读回节拍，数十 ms 内）。
enum WindowSettle {

    // MARK: - yabai 级

    /// float 脱管（--toggle float）后等 yabai 默认重摆落定，再写目标 frame。
    /// 300ms 为重摆耗时上界（实测低于此值 AX/yabai 写会被随后的重摆覆盖，
    /// 2026-09-01 尺寸错乱根因）。
    /// 使用点语义分两档（2026-09-03 流畅度第二刀）：
    /// - ToggleEngine+Restore 4a：仅真 toggle 时等待（didToggle 条件，历史行为）；
    /// - move_to_main P2/AX、moveStuckWindowToSecondaryScreen：同改 didToggle 条件
    ///   （已 float 零等待），真 toggle 时走 waitForRelayout 等稳定代等固定——
    ///   下限 floatRelayoutMinSettleMicros，本值作总预算兜底。
    static let floatRelayoutSettleMicros: useconds_t = 300_000

    /// float 重摆等稳定的下限：120ms。`--toggle float` 后重摆有启动延迟，过早的
    /// 「连续两读相等」是静默窗口的假稳定；先睡满下限再开始稳定性轮询。
    /// 使用点：FrameConvergence.waitForRelayout。
    static let floatRelayoutMinSettleMicros: useconds_t = 120_000

    /// yabai frame 直写后的验证轮询（原固定 settle 400ms 的等到位版，2026-09-03
    /// restore「水中移动」优化：写多数几十 ms 落定，固定睡是纯等待——改每 25ms 读一次，
    /// 一收敛立即返回；预算 400ms 兜底「fork 返回 ≠ 已生效」的上界）。
    /// 使用点：moveWindowToFrameViaYabai 段二收敛轮询（convergeFramePolling）。
    /// （restore 4-pre 的 space 切回等待已改 ConditionPolling 等到位轮询，不再消费本值。）
    static let frameVerifyPollIntervalMs: UInt32 = 25
    static let frameVerifyBudgetMs: UInt32 = 400

    // MARK: - WindowServer 级（AX 写 → 读回节拍）

    /// AX size 写后等落定再 readback 的唯一节拍：25ms。
    /// 使用点：writeSizeWithReadback 主循环、verifyAndCorrectPostMoveSize rewrite 循环
    /// （第十四刀归一：原 postRewriteSettle 15ms 与本值同语义不同值，属历史拍脑袋不一致，
    /// 随 convergeFrame 循环统一并入本档，取保守大值）。
    static let axWriteSettleMicros: useconds_t = 25_000

    /// Mission Control dismiss 后等动画结束再操作 space。150ms。
    /// 使用点：NativeSpaceBridge.dismissMissionControl。
    static let missionControlDismissSettleMicros: useconds_t = 150_000

    // MARK: - 等到位轮询（P1-2 等落定改等到位；骨架 ConditionPolling.waitUntil）
    //
    // 适用边界：仅用于**有可观测目标态**的等待（如源屏可见 space == sourceSpace）。
    // float 重摆完成无可观测信号（is-floating 翻转远早于重摆结束），float 等待
    // 保留 floatRelayoutSettleMicros 固定档，勿改轮询（2.15 尺寸错乱教训）。

    /// 等到位轮询节拍：50ms（space 可见性 yabai 查询 fork ~30ms，50ms 不空转）。
    static let conditionPollIntervalMs: UInt32 = 50

    /// 源屏 space 切回后的到位预算：800ms（原固定 400ms usleep 的等到位版；
    /// SA 直切/聚焦带动后 yabai 状态异步落定，大多数 <300ms，早满足早返回）。
    /// 使用点：ToggleEngine+Restore 4-pre（切回成功后的可见性确认）。
    static let spaceSwitchWaitBudgetMs: UInt32 = 800

    /// move/resize 分段写入的段间到位预算：300ms。fork 返回 ≠ 窗口服务已应用
    /// （2026-09-03 乱蹦二次修复实测：move 命令 179ms 返回时窗口服务尚未应用 resize，
    /// 第一段必须轮询到效果可观测才能发第二段）；yabai 单命令 fork 实测 82~322ms。
    /// 被源屏可视区 clamp 的 resize 永不生效（等也白等，由段二按偏差补发自愈），
    /// 2026-09-03 四次修复起预算 600→300ms 收窄白等。
    /// 使用点：moveWindowToFrameViaYabai 段间轮询。
    static let framePhaseVerifyBudgetMs: UInt32 = 300
}
