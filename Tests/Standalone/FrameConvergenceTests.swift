// Tests/Standalone/FrameConvergenceTests.swift
// Verification: 窗口帧收敛判据（三处 verify-rewrite 循环的唯一事实源）
// Mirrors: Sources/Space/CoordinateKit.swift
//          （originDrift / sizeDrift / isSizeConverged / isFrameConverged）
// Run: swift Tests/Standalone/FrameConvergenceTests.swift
//
// 背景（playbook 2.16a 第十二刀）：三份 verify-rewrite 循环曾各写一种判据——
// yabai 路径漂移和、apply 循环逐轴（更宽松）、PostMove 漂移和，两层判据不一致
// 曾出现 apply 判收敛、PostMove 立即重写的自我打架。统一为"漂移和 ≤ 容差"。
// 本测试锁定：漂移和算法、边界（恰等于容差算收敛）、漂移和与逐轴的语义差异。

import Foundation
import CoreGraphics

// MARK: - Extracted pure logic

/// Mirrors CoordinateKit.originDrift
func mirrorOriginDrift(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    abs(a.x - b.x) + abs(a.y - b.y)
}

/// Mirrors CoordinateKit.sizeDrift
func mirrorSizeDrift(_ a: CGSize, _ b: CGSize) -> CGFloat {
    abs(a.width - b.width) + abs(a.height - b.height)
}

/// Mirrors CoordinateKit.isSizeConverged
func mirrorIsSizeConverged(actual: CGSize, target: CGSize, tolerance: CGFloat) -> Bool {
    mirrorSizeDrift(actual, target) <= tolerance
}

/// Mirrors CoordinateKit.isFrameConverged
func mirrorIsFrameConverged(actual: CGRect, target: CGRect, tolerance: CGFloat) -> Bool {
    mirrorOriginDrift(actual.origin, target.origin) <= tolerance &&
    mirrorSizeDrift(actual.size, target.size) <= tolerance
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

// MARK: 1. 漂移和计算

print("1. 漂移和计算")

check("零漂移", mirrorSizeDrift(CGSize(width: 800, height: 600), CGSize(width: 800, height: 600)) == 0)
check("宽高同向漂移求和 (3+4=7)",
      mirrorSizeDrift(CGSize(width: 803, height: 604), CGSize(width: 800, height: 600)) == 7)
check("反向漂移取绝对值 (|−3|+|−4|=7)",
      mirrorSizeDrift(CGSize(width: 797, height: 596), CGSize(width: 800, height: 600)) == 7)
check("一正一负混合 (|−3|+|4|=7)",
      mirrorSizeDrift(CGSize(width: 797, height: 604), CGSize(width: 800, height: 600)) == 7)
check("位置漂移和 (|−10|+|20|=30)",
      mirrorOriginDrift(CGPoint(x: -10, y: 20), CGPoint(x: 0, y: 0)) == 30)

// MARK: 2. 收敛边界 — 恰等于容差算收敛（≤）

print("\n2. 收敛边界（≤ 语义）")

let target = CGSize(width: 800, height: 600)
check("漂移和恰等于容差 10 → 收敛", mirrorIsSizeConverged(actual: CGSize(width: 806, height: 604), target: target, tolerance: 10))
check("漂移和超容差 0.5 → 不收敛", !mirrorIsSizeConverged(actual: CGSize(width: 807, height: 604), target: target, tolerance: 10))
check("单轴超容差另一轴为零 → 不收敛（漂移和语义）",
      !mirrorIsSizeConverged(actual: CGSize(width: 811, height: 600), target: target, tolerance: 10))
check("零容差要求精确", mirrorIsSizeConverged(actual: CGSize(width: 800.0001, height: 600), target: target, tolerance: 0) == false)

// MARK: 3. 漂移和 vs 逐轴 — 统一选择的语义依据

print("\n3. 漂移和 vs 逐轴（历史分歧点，锁定统一选择）")

// 逐轴（旧 apply 判据）允许 dw=8、dh=8：两轴各自 ≤10 → 判收敛；
// 漂移和 = 16 > 10 → 判不收敛。统一后采用漂移和（更严）：apply 不再放过
// PostMove 会立即重写的窗口（消除两层判据自我打架）。
let combinedDrift = CGSize(width: 808, height: 608)
check("dw=8,dh=8,T=10：逐轴会判收敛（旧 apply 行为）",
      abs(combinedDrift.width - 800) <= 10 && abs(combinedDrift.height - 600) <= 10)
check("dw=8,dh=8,T=10：漂移和判不收敛（统一后行为）",
      !mirrorIsSizeConverged(actual: combinedDrift, target: target, tolerance: 10))

// MARK: 4. 整 frame 判定 — 双维度独立把关

print("\n4. isFrameConverged 双维度")

let targetFrame = CGRect(x: 100, y: 200, width: 800, height: 600)
check("完全一致 → 收敛", mirrorIsFrameConverged(actual: targetFrame, target: targetFrame, tolerance: 10))
check("仅 size 漂移超差 → 不收敛",
      !mirrorIsFrameConverged(actual: CGRect(x: 100, y: 200, width: 800, height: 625), target: targetFrame, tolerance: 10))
check("仅 origin 漂移超差 → 不收敛",
      !mirrorIsFrameConverged(actual: CGRect(x: 130, y: 200, width: 800, height: 600), target: targetFrame, tolerance: 10))
check("双维度都在容差内 → 收敛",
      mirrorIsFrameConverged(actual: CGRect(x: 104, y: 204, width: 804, height: 604), target: targetFrame, tolerance: 10))

// MARK: 5. 生产场景 — yabai 直写闭环与 PostMove 兜底

print("\n5. 生产场景")

// 场景 A：yabai --move/--resize 后窗口完全到位
let written = CGRect(x: 0, y: 0, width: 1920, height: 1117)
check("yabai 直写精确落位 → 验证通过",
      mirrorIsFrameConverged(actual: written, target: written, tolerance: 10))

// 场景 B：WindowServer clamp 了 1px（浮点栅格化），仍在容差内
check("栅格化 1px 漂移 → 收敛（不触发无谓重写）",
      mirrorIsFrameConverged(actual: CGRect(x: 0.5, y: 0.5, width: 1920, height: 1117), target: written, tolerance: 10))

// 场景 C：yabai re-tile 异步覆盖（半屏高 bug 形态），height 差 410
let halfHeighted = CGRect(x: 0, y: 0, width: 1920, height: 707)
check("半屏高形态（dh=410）→ 不收敛，触发 PostMove 重写兜底",
      !mirrorIsSizeConverged(actual: halfHeighted.size, target: written.size, tolerance: 10))

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
