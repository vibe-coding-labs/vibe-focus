// Tests/Standalone/GridSpaceDeliveryTests.swift
// Verification: 建窗后 Space 投递的单窗决策纯函数
// Mirrors: Sources/TerminalGrid/TerminalGridController.swift (spaceDeliveryDecision)
// Run: swift Tests/Standalone/GridSpaceDeliveryTests.swift
//
// 背景（2026-09-06 用户反馈）：选了 Space 5 创建网格，窗口全部落进 Space 4。
// 根因：AppleScript 建窗落点由终端 app 自己的活跃 space 决定，与系统视角脱节
// （视角切到 5，iTerm2 把窗口建进不可见的 4）。修复 = 建窗后逐窗校验 + 分类投递：
// 窗口在其它屏 → 跨屏 frame 直写；同屏错位 → 泊到其它屏再写回。

import Foundation

// MARK: - Mirrored logic

enum SpaceDeliveryDecision: Equatable {
    case notNeeded              // 已在目标 space
    case notApplicable          // 非显式 space 目标（display 级 / 主屏 / 焦点屏）
    case skipNoYabai            // yabai 不可用，无法验证也无通道
    case skipNoParkingDisplay   // 单屏机：同屏错位无法往返
    case skipViewNotOnTarget    // 目标屏当前没显示目标 space（视角切换失败场景）
    case deliverCrossDisplay    // 窗口在其它屏：一次跨屏 frame 直写即入目标屏可见 space
    case deliverRoundTrip       // 窗口在目标屏但错位 space：泊到其它屏 → 写回
}

func spaceDeliveryDecision(
    targetSpaceIndex: Int?,
    targetDisplayVisibleSpace: Int?,
    targetDisplayIndex: Int?,
    windowDisplayIndex: Int?,
    hasParkingDisplay: Bool,
    windowSpaceIndex: Int?
) -> SpaceDeliveryDecision {
    guard let targetSpaceIndex else { return .notApplicable }
    guard let visible = targetDisplayVisibleSpace else { return .skipNoYabai }
    guard visible == targetSpaceIndex else { return .skipViewNotOnTarget }
    guard let windowSpaceIndex, windowSpaceIndex == targetSpaceIndex else {
        if windowDisplayIndex == targetDisplayIndex, !hasParkingDisplay {
            return .skipNoParkingDisplay
        }
        if windowDisplayIndex == targetDisplayIndex {
            return .deliverRoundTrip
        }
        return .deliverCrossDisplay
    }
    return .notNeeded
}

func decide(target: Int?, visible: Int?, targetD: Int?, winD: Int?, parking: Bool, winSpace: Int?) -> SpaceDeliveryDecision {
    spaceDeliveryDecision(targetSpaceIndex: target, targetDisplayVisibleSpace: visible,
                          targetDisplayIndex: targetD, windowDisplayIndex: winD,
                          hasParkingDisplay: parking, windowSpaceIndex: winSpace)
}

// MARK: - Checks

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition {
        print("  PASS: \(name)")
    } else {
        failures += 1
        print("  FAIL: \(name)")
    }
}

// 非显式 space 目标 → 不适用（display 级/主屏/焦点屏创建流程零改动）
check("非显式目标: notApplicable",
      decide(target: nil, visible: 5, targetD: 2, winD: 1, parking: true, winSpace: 4) == .notApplicable)

// yabai 不可用（可见 space 采集不到）→ 放弃投递
check("yabai 不可用: skipNoYabai",
      decide(target: 5, visible: nil, targetD: 2, winD: 1, parking: true, winSpace: 4) == .skipNoYabai)

// 目标屏没显示目标 space（视角切换失败）→ 投递只会落错，放弃
check("视角不在目标 space: skipViewNotOnTarget",
      decide(target: 5, visible: 4, targetD: 2, winD: 1, parking: true, winSpace: 6) == .skipViewNotOnTarget)

// 窗口已在目标 space → 无需投递（happy path 零额外动作）
check("已在目标 space: notNeeded",
      decide(target: 5, visible: 5, targetD: 2, winD: 2, parking: true, winSpace: 5) == .notNeeded)

// 用户实证案例：视角在 5，iTerm2 把窗建进同屏不可见的 4 → 泊位往返
check("同屏错位: deliverRoundTrip",
      decide(target: 5, visible: 5, targetD: 2, winD: 2, parking: true, winSpace: 4) == .deliverRoundTrip)

// E2E 场景：iTerm2 把窗甩到主屏（display 1）→ 跨屏直写
check("跨屏错位: deliverCrossDisplay",
      decide(target: 4, visible: 4, targetD: 2, winD: 1, parking: true, winSpace: 1) == .deliverCrossDisplay)

// 同屏错位但单屏机（不存在第二块屏）→ 无法往返
check("同屏错位+单屏: skipNoParkingDisplay",
      decide(target: 5, visible: 5, targetD: 2, winD: 2, parking: false, winSpace: 4) == .skipNoParkingDisplay)

// 窗口 display/space 查询失败 → 按「不在目标屏」走跨屏直写兜底（写回目标格位无害）
check("查询失败: deliverCrossDisplay",
      decide(target: 5, visible: 5, targetD: 2, winD: nil, parking: true, winSpace: nil) == .deliverCrossDisplay)

print(failures == 0 ? "\nAll tests passed." : "\n\(failures) test(s) FAILED.")
exit(failures == 0 ? 0 : 1)
