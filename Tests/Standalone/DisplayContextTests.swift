// Tests/Standalone/DisplayContextTests.swift
// Verification: displayContext 显示器归属判定（Quartz→Cocoa 统一变换 + yabai 索引语义）
// Mirrors: Sources/Window/WindowManager+ScreenPosition.swift (displayContext)
//          Sources/Space/CoordinateKit.swift (yabaiDisplayIndex / nsScreen(forYabaiDisplayIndex:))
// Run: swift Tests/Standalone/DisplayContextTests.swift
//
// 背景（playbook 2.16a 第十三刀，2.15"断言脚本先行"教训的执行样例）：
// 旧 displayContext 把 Quartz 中心点直接去比 NSScreen 的 Cocoa frame——
// 只有主屏（数值区间等价）和与主屏垂直完全对齐的副屏（翻转后区间不变）碰巧正确；
// 纵向偏移的副屏永远匹配不上（Quartz 负 y 段 vs Cocoa 正 y 段），且
// intersects 兜底还可能误配。另外它返回 NSScreen 数组 0-based 索引，
// 消费端却按 yabai 1-based 显示器索引写进 ToggleRecord.sourceDisplay（双重错位：
// 副屏被记成 yabai(1)=主屏）。本文件锁定修复后的语义，并保留旧判据缺陷
// 断言防止回退。

import Foundation
import CoreGraphics

// MARK: - Mirror world（无 AppKit 的屏幕模型；frame 均为 Cocoa 坐标）

struct MirrorScreen {
    let frame: CGRect        // Cocoa 坐标（同 NSScreen.frame）
    let displayID: UInt32
}

/// 全局 Quartz→Cocoa 变换（变换常量恒为主屏高，与点在哪块屏无关）
func quartzToCocoa(_ quartzFrame: CGRect, mainHeight: CGFloat) -> CGRect {
    CGRect(x: quartzFrame.origin.x,
           y: mainHeight - quartzFrame.maxY,
           width: quartzFrame.width,
           height: quartzFrame.height)
}

/// Cocoa frame → 同一块屏的 Quartz frame（构造窗口输入用）
func cocoaToQuartz(_ cocoaFrame: CGRect, mainHeight: CGFloat) -> CGRect {
    CGRect(x: cocoaFrame.origin.x,
           y: mainHeight - cocoaFrame.maxY,
           width: cocoaFrame.width,
           height: cocoaFrame.height)
}

// MARK: - 旧判据（历史，防回退镜像）

/// Mirrors 修复前的 displayContext 判定：Quartz 点/rect 直接比 Cocoa frame
func mirrorLegacyDisplayContext(screens: [MirrorScreen], quartzFrame: CGRect) -> MirrorScreen? {
    let center = CGPoint(x: quartzFrame.midX, y: quartzFrame.midY)
    for screen in screens {
        if screen.frame.contains(center) || screen.frame.intersects(quartzFrame) {
            return screen
        }
    }
    return nil
}

// MARK: - 新判据（修复后语义）

/// Mirrors 修复后的 displayContext 判定：先做全局 Quartz→Cocoa 变换再比较
func mirrorFixedDisplayContext(screens: [MirrorScreen], quartzFrame: CGRect, mainHeight: CGFloat) -> MirrorScreen? {
    let cocoaFrame = quartzToCocoa(quartzFrame, mainHeight: mainHeight)
    let cocoaCenter = CGPoint(x: cocoaFrame.midX, y: cocoaFrame.midY)
    for screen in screens {
        if screen.frame.contains(cocoaCenter) || screen.frame.intersects(cocoaFrame) {
            return screen
        }
    }
    return nil
}

// MARK: - yabai 索引语义

/// Mirrors nsScreen(forYabaiDisplayIndex:)（CoordinateKit 既有约定：1=主屏，2..=非主屏次序）
func mirrorNsScreen(forYabaiDisplayIndex index: Int, screens: [MirrorScreen]) -> MirrorScreen? {
    guard index >= 1, index <= screens.count else { return nil }
    if index == 1 {
        return screens.first { $0.frame.origin == .zero } ?? screens.first
    }
    let nonMain = screens.filter { $0.frame.origin != .zero }
    let i = index - 2
    guard i >= 0, i < nonMain.count else { return nil }
    return nonMain[i]
}

/// Mirrors yabaiDisplayIndex(for:)（新增：nsScreen(forYabaiDisplayIndex:) 的逆映射）
func mirrorYabaiDisplayIndex(for target: MirrorScreen, screens: [MirrorScreen]) -> Int? {
    if target.frame.origin == .zero { return 1 }
    var yabaiIndex = 2
    for screen in screens where screen.frame.origin != .zero {
        if screen.frame == target.frame && screen.displayID == target.displayID { return yabaiIndex }
        yabaiIndex += 1
    }
    return nil
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

// MARK: 布局（真实形态：主屏 + 右侧纵向偏移副屏 + 上方副屏）

let H: CGFloat = 1080
let main = MirrorScreen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), displayID: 1)
// 右下方副屏：Cocoa y ∈ [-900, 0]（负 y 在主屏下方），Quartz y ∈ [1080, 1980]
let belowRight = MirrorScreen(frame: CGRect(x: 1920, y: -900, width: 1920, height: 900), displayID: 2)
// 上方副屏：Cocoa y ∈ [1080, 1980]（正 y 超过主屏高），Quartz y ∈ [-900, 0]
let above = MirrorScreen(frame: CGRect(x: -1920, y: 1080, width: 1920, height: 900), displayID: 3)
let screens = [main, belowRight, above]

// MARK: 1. 全局变换不变量

print("1. Quartz↔Cocoa 全局变换不变量")

let sample = CGRect(x: 2400, y: 1300, width: 800, height: 500)
check("矩形 roundtrip：cocoaToQuartz ∘ quartzToCocoa == 恒等",
      cocoaToQuartz(quartzToCocoa(sample, mainHeight: H), mainHeight: H) == sample)
check("主屏区间在两坐标系下数值相等（历史'碰巧正确'的根源）",
      cocoaToQuartz(CGRect(x: 0, y: 0, width: 1920, height: 1080), mainHeight: H) ==
      CGRect(x: 0, y: 0, width: 1920, height: 1080))
check("偏移副屏区间在两坐标系下数值不等（缺陷触发条件）",
      cocoaToQuartz(belowRight.frame, mainHeight: H) != belowRight.frame)

// MARK: 2. 新判据 — 多布局归属矩阵

print("\n2. 新判据：窗口 → 显示器归属矩阵")

// 主屏窗口（Quartz 与 Cocoa 数值相同）
let qOnMain = cocoaToQuartz(CGRect(x: 400, y: 300, width: 800, height: 600), mainHeight: H)
check("主屏窗口 → 主屏", mirrorFixedDisplayContext(screens: screens, quartzFrame: qOnMain, mainHeight: H)?.displayID == 1)

// 右下副屏窗口：Quartz y ∈ [1080, 1980]（正 y 段）
let qOnBelowRight = cocoaToQuartz(CGRect(x: 2200, y: -700, width: 800, height: 500), mainHeight: H)
check("右下偏移副屏窗口 → 正确副屏（旧判据永远 miss 的场景）",
      mirrorFixedDisplayContext(screens: screens, quartzFrame: qOnBelowRight, mainHeight: H)?.displayID == 2)

// 上方副屏窗口：Quartz y ∈ [-900, 0]（负 y 段）
let qOnAbove = cocoaToQuartz(CGRect(x: -1500, y: 1300, width: 800, height: 500), mainHeight: H)
check("上方副屏窗口（Quartz 负 y）→ 正确副屏",
      mirrorFixedDisplayContext(screens: screens, quartzFrame: qOnAbove, mainHeight: H)?.displayID == 3)

// MARK: 3. 旧判据缺陷锁定（防回退）

print("\n3. 旧判据缺陷（历史，防回退断言）")

check("旧判据在右下偏移副屏上 miss（Quartz 正 y 段 vs Cocoa 负 y 段）",
      mirrorLegacyDisplayContext(screens: screens, quartzFrame: qOnBelowRight) == nil)
check("旧判据在上方副屏上 miss（Quartz 负 y 段 vs Cocoa 正 y 段）",
      mirrorLegacyDisplayContext(screens: screens, quartzFrame: qOnAbove) == nil)
check("旧判据在主屏上恰好正确（数值等价区间）——它因此长期未被发现",
      mirrorLegacyDisplayContext(screens: screens, quartzFrame: qOnMain)?.displayID == 1)

// MARK: 4. yabai 索引语义 — 1-based 主屏优先

print("\n4. yabai 索引语义")

check("主屏 → yabai 1", mirrorYabaiDisplayIndex(for: main, screens: screens) == 1)
check("第一个非主屏 → yabai 2（数组下标 1；旧判据曾把 0-based 数组下标直接当 yabai 索引写入审计）",
      mirrorYabaiDisplayIndex(for: belowRight, screens: screens) == 2)
check("第二个非主屏 → yabai 3",
      mirrorYabaiDisplayIndex(for: above, screens: screens) == 3)

// roundtrip：yabaiIndex(for:) 与 nsScreen(forYabaiDisplayIndex:) 互逆
var allRoundtrip = true
for screen in screens {
    guard let idx = mirrorYabaiDisplayIndex(for: screen, screens: screens),
          let back = mirrorNsScreen(forYabaiDisplayIndex: idx, screens: screens),
          back.displayID == screen.displayID else {
        allRoundtrip = false
        break
    }
}
check("yabaiIndex ↔ nsScreen 全量 roundtrip", allRoundtrip)

// MARK: 5. 新旧索引写入审计的对比

print("\n5. 审计列写入对比")

check("旧逻辑把右下副屏记为 yabai(1)=主屏（数组下标 1 当 yabai 索引，倒置）",
      mirrorYabaiDisplayIndex(for: mirrorLegacyDisplayContext(screens: screens, quartzFrame: qOnBelowRight) ?? main,
                              screens: screens) != 2)
check("新逻辑把右下副屏正确记为 yabai(2)",
      mirrorYabaiDisplayIndex(
          for: mirrorFixedDisplayContext(screens: screens, quartzFrame: qOnBelowRight, mainHeight: H)!,
          screens: screens) == 2)

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
