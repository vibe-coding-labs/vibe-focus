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
    /// 300ms；实测低于此值 AX/yabai 写会被随后的重摆覆盖（2026-09-01 尺寸错乱根因）。
    /// 使用点：ToggleEngine+Restore 4a、move_to_main P2 pre-float、
    /// move_to_main AX apply 前、moveStuckWindowToSecondaryScreen。
    static let floatRelayoutSettleMicros: useconds_t = 300_000

    /// yabai --move abs + --resize abs 直写后等落定，再做 frame 读回验证。
    /// 400ms（含 move+resize 两次命令的生效余量，故大于 float 重摆节拍）。
    /// 使用点：moveWindowToFrameViaYabai 闭环验证；
    /// ToggleEngine+Restore 4-pre（源屏视角切回后、写 frame 前等同级 yabai 状态落定）。
    static let yabaiFrameWriteSettleMicros: useconds_t = 400_000

    // MARK: - WindowServer 级（AX 写 → 读回节拍）

    /// writeSizeWithReadback 主循环：AX size 写后等落定再 readback。25ms。
    /// （与 postRewriteSettleMicros 同语义不同值，属历史拍脑袋不一致；
    /// 待 P3"frame 收敛循环统一"以 convergeFrame 一并归一。）
    static let axWriteSettleMicros: useconds_t = 25_000

    /// PostMove verify-rewrite 循环：AX size 重写后等落定再读回。15ms。
    static let postRewriteSettleMicros: useconds_t = 15_000

    /// Mission Control dismiss 后等动画结束再操作 space。150ms。
    /// 使用点：NativeSpaceBridge.dismissMissionControl。
    static let missionControlDismissSettleMicros: useconds_t = 150_000
}
