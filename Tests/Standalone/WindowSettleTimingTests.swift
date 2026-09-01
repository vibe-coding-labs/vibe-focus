// Tests/Standalone/WindowSettleTimingTests.swift
// Verification: 窗口落定等待时长表（散落 4 文件的裸 usleep 魔法数收敛点）
// Mirrors: Sources/Support/WindowSettle.swift
// Run: swift Tests/Standalone/WindowSettleTimingTests.swift
//
// 背景（playbook 2.16 第九刀）：300/400/25/15/150ms 曾以裸数字散落 7 处，
// 改谁都说不清影响面。本测试锁定两级语义（yabai 级 vs WindowServer 级）的
// 关系不变量与当前基准值——任何数值调整都必须是看过本表的显式决定，
// 且按 2.15 教训需真实窗口闭环验证后才能改。
// 2.16a 第十四刀：15ms postRewrite 档与 25ms axWriteSettle 同语义不同值，
// 随 convergeFrame 循环统一并入 25ms 档，原常量下线。

import Foundation

// MARK: - Extracted pure logic

/// Mirrors WindowSettle（数值基准锁定）
enum MirrorWindowSettle {
    static let floatRelayoutSettleMicros: UInt32 = 300_000
    static let yabaiFrameWriteSettleMicros: UInt32 = 400_000
    static let axWriteSettleMicros: UInt32 = 25_000
    static let missionControlDismissSettleMicros: UInt32 = 150_000
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

// MARK: 1. 基准值锁定 — 与实测经验值一致（改动需闭环验证）

print("1. 基准值锁定")

check("float 重摆落定 = 300ms", MirrorWindowSettle.floatRelayoutSettleMicros == 300_000)
check("yabai 直写落定 = 400ms", MirrorWindowSettle.yabaiFrameWriteSettleMicros == 400_000)
check("AX 写读回节拍唯一 = 25ms（writeSizeWithReadback 与 PostMove rewrite 共用；原 15ms 档已归一下线）",
      MirrorWindowSettle.axWriteSettleMicros == 25_000)
check("MC 动画结束 = 150ms", MirrorWindowSettle.missionControlDismissSettleMicros == 150_000)

// MARK: 2. 两级语义不变量 — yabai 级必须比 WindowServer 级高一个量级

print("\n2. 两级语义不变量")

let yabaiMin = min(MirrorWindowSettle.floatRelayoutSettleMicros, MirrorWindowSettle.yabaiFrameWriteSettleMicros)
let axMax = MirrorWindowSettle.axWriteSettleMicros
check("yabai 级最短等待 ≥ WindowServer 级最长等待的 10 倍（重摆是异步布局动画，AX 写是同步 IPC）",
      yabaiMin >= axMax * 10)
check("yabai 直写落定 ≥ float 重摆落定（move+resize 两条命令需更多余量）",
      MirrorWindowSettle.yabaiFrameWriteSettleMicros >= MirrorWindowSettle.floatRelayoutSettleMicros)

// MARK: 3. 有界性 — 防止"调优"越界破坏交互手感

print("\n3. 有界性")

check("MC 动画等待 ≥ 100ms（系统动画 ~0.2s，过短 dismiss 未完 space 操作会失败）",
      MirrorWindowSettle.missionControlDismissSettleMicros >= 100_000)
check("MC 动画等待 ≤ 500ms（dismiss 在 space 操作关键路径上）",
      MirrorWindowSettle.missionControlDismissSettleMicros <= 500_000)
check("AX 读回节拍 ≤ 50ms（writeSizeWithReadback 最多 3 轮 + PostMove rewrite 最多 2 轮共用本档，过大会拖慢 hook 同步响应）",
      MirrorWindowSettle.axWriteSettleMicros <= 50_000)
check("yabai 级等待 ≤ 1s（toggle/hook 移动都在用户可感知路径上）",
      max(MirrorWindowSettle.floatRelayoutSettleMicros, MirrorWindowSettle.yabaiFrameWriteSettleMicros) <= 1_000_000)

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
