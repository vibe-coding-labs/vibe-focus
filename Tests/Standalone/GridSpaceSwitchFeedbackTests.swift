// Tests/Standalone/GridSpaceSwitchFeedbackTests.swift
// Verification: Minimap 胶囊 live 切换结局 → 反馈文案映射（三态穷举）
// Mirrors: Sources/Settings/GridSpaceSwitchFeedback.swift
// Run: swift Tests/Standalone/GridSpaceSwitchFeedbackTests.swift
//
// 背景（2026-09-07 用户报告）：minimap 点胶囊只设编排目标不切屏，用户感知
// 「点了没反应」。修复 = 点击同时走 restore 视角链 live 切换；本测试锁定结局
// 映射文案——失败必须如实说明（空工作区无 SA 切不动是平台事实），禁止静默。

import Foundation

// MARK: - Mirrors (与源码同步维护)

enum MirrorPerspectiveRefocusOutcome: Equatable {
    case noDrift
    case refocused(postSpace: Int)
    case failed(postSpace: Int)
}

func switchFeedbackMessage(
    for outcome: MirrorPerspectiveRefocusOutcome,
    spaceIndex: Int
) -> String {
    switch outcome {
    case .noDrift:
        return "Space \(spaceIndex) 已是当前工作区"
    case .refocused:
        return "已切换到 Space \(spaceIndex)"
    case .failed:
        return "无法切换到 Space \(spaceIndex)：该工作区没有可聚焦的窗口（空工作区需要 SA 直切通道，本机未装）"
    }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

// MARK: - Tests

check("spaceSwitchFeedback: noDrift → 已是当前工作区（含 space 号）",
      switchFeedbackMessage(for: .noDrift, spaceIndex: 5).contains("已是当前工作区")
      && switchFeedbackMessage(for: .noDrift, spaceIndex: 5).contains("Space 5"))
check("spaceSwitchFeedback: refocused → 已切换（含 space 号）",
      switchFeedbackMessage(for: .refocused(postSpace: 4), spaceIndex: 5) == "已切换到 Space 5")
check("spaceSwitchFeedback: failed → 如实说明失败原因（含 space 号与 SA 事实，不静默）",
      switchFeedbackMessage(for: .failed(postSpace: 4), spaceIndex: 5).contains("无法切换到 Space 5")
      && switchFeedbackMessage(for: .failed(postSpace: 4), spaceIndex: 5).contains("SA"))
check("spaceSwitchFeedback: 三态文案互异",
      Set([
          switchFeedbackMessage(for: .noDrift, spaceIndex: 2),
          switchFeedbackMessage(for: .refocused(postSpace: 1), spaceIndex: 2),
          switchFeedbackMessage(for: .failed(postSpace: 1), spaceIndex: 2),
      ]).count == 3)

// MARK: - Summary

print("\nGridSpaceSwitchFeedbackTests: \(passed + failed) checks, \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
