// Tests/Standalone/ScreenYabaiDisplayMatchTests.swift
// Verification: NSScreen ↔ yabai display 几何精确匹配（Quartz↔Cocoa 翻转 + 最近中心贪心唯一配对）
// Mirrors: Sources/Space/CoordinateKit+Screen.swift matchYabaiDisplayIndices
// Run: swift Tests/Standalone/ScreenYabaiDisplayMatchTests.swift
//
// 背景（2026-09-08 用户实测「屏幕对应关系完全错误」）：旧实现按 NSScreen 顺序猜
// yabai display 索引——两块同尺寸副屏在两套排序里反序时，Space 胶囊挂错屏、
// 点击切换切错屏。本测试锁定几何匹配：顺序无关、翻转正确、异常输入回退空表。

import CoreGraphics
import Foundation

// MARK: - Mirrors (与源码同步维护)

func matchYabaiDisplayIndices(
    cocoaFrames: [CGRect],
    mainHeight: CGFloat,
    yabaiIndices: [Int],
    yabaiQuartzFrames: [CGRect]
) -> [Int: Int] {
    guard mainHeight > 0,
          !cocoaFrames.isEmpty,
          yabaiIndices.count == yabaiQuartzFrames.count,
          !yabaiIndices.isEmpty
    else { return [:] }

    let yabaiCocoaFrames: [CGRect] = yabaiQuartzFrames.map { q in
        CGRect(x: q.minX, y: mainHeight - q.maxY, width: q.width, height: q.height)
    }

    var pairs: [(cocoa: Int, yabai: Int, distance: CGFloat)] = []
    for (ci, cf) in cocoaFrames.enumerated() {
        for (yi, yf) in yabaiCocoaFrames.enumerated() {
            let dx = cf.midX - yf.midX
            let dy = cf.midY - yf.midY
            pairs.append((ci, yi, dx * dx + dy * dy))
        }
    }
    pairs.sort { $0.distance < $1.distance }

    var result: [Int: Int] = [:]
    var usedCocoa = Set<Int>()
    var usedYabai = Set<Int>()
    for pair in pairs where pair.distance <= 64 {
        if usedCocoa.contains(pair.cocoa) || usedYabai.contains(pair.yabai) { continue }
        usedCocoa.insert(pair.cocoa)
        usedYabai.insert(pair.yabai)
        result[pair.cocoa] = yabaiIndices[pair.yabai]
    }
    return result
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

// MARK: - Tests

// A. 回归主案例：主屏 + 左右两块同尺寸副屏，yabai 真实序与 NSScreen 序相反
//（NSScreen 序：main, 左, 右；yabai 序：1=main, 2=右, 3=左）——按顺序猜必错，几何匹配必须对。
let cocoaAB = [
    CGRect(x: 0, y: 0, width: 1920, height: 1080),      // main
    CGRect(x: -1920, y: 0, width: 1920, height: 1080),  // 左副屏
    CGRect(x: 1920, y: 0, width: 1920, height: 1080),   // 右副屏
]
let quartzReversed = [
    CGRect(x: 0, y: 0, width: 1920, height: 1080),      // yabai 1 = main
    CGRect(x: 1920, y: 0, width: 1920, height: 1080),   // yabai 2 = 右
    CGRect(x: -1920, y: 0, width: 1920, height: 1080),  // yabai 3 = 左
]
let matchA = matchYabaiDisplayIndices(
    cocoaFrames: cocoaAB, mainHeight: 1080,
    yabaiIndices: [1, 2, 3], yabaiQuartzFrames: quartzReversed)
check("yabaiMatch A: 反序副屏按几何正确配对（左→3 / 右→2）",
      matchA[0] == 1 && matchA[1] == 3 && matchA[2] == 2)

// B. 副屏在主屏上方（quartz 负 y 区，Cocoa 正 y 区）——翻转语义。
let matchB = matchYabaiDisplayIndices(
    cocoaFrames: [
        CGRect(x: 0, y: 0, width: 1728, height: 1117),    // main（下）
        CGRect(x: 0, y: 1117, width: 1920, height: 1080), // 副屏（上）
    ],
    mainHeight: 1117,
    yabaiIndices: [1, 2],
    yabaiQuartzFrames: [
        CGRect(x: 0, y: 0, width: 1728, height: 1117),
        CGRect(x: 0, y: -1080, width: 1920, height: 1080),
    ])
check("yabaiMatch B: 主屏上方副屏（quartz 负 y）翻转匹配", matchB[0] == 1 && matchB[1] == 2)

// C. 异常输入回退空表（调用方回退老标注 + 空 Space 带）。
check("yabaiMatch C1: 数量不符 → 空表",
      matchYabaiDisplayIndices(
        cocoaFrames: cocoaAB, mainHeight: 1080,
        yabaiIndices: [1], yabaiQuartzFrames: quartzReversed).isEmpty)
check("yabaiMatch C2: 空输入 / 零主屏高 → 空表",
      matchYabaiDisplayIndices(cocoaFrames: [], mainHeight: 1080, yabaiIndices: [], yabaiQuartzFrames: []).isEmpty
      && matchYabaiDisplayIndices(
        cocoaFrames: cocoaAB, mainHeight: 0,
        yabaiIndices: [1, 2, 3], yabaiQuartzFrames: quartzReversed).isEmpty)

// D. 精确同位（无舍入）匹配不受贪心顺序影响。
let matchD = matchYabaiDisplayIndices(
    cocoaFrames: cocoaAB, mainHeight: 1080,
    yabaiIndices: [1, 2, 3],
    yabaiQuartzFrames: [
        CGRect(x: 0, y: 0, width: 1920, height: 1080),      // main
        CGRect(x: -1920, y: 0, width: 1920, height: 1080),  // 左（与 NSScreen 同序）
        CGRect(x: 1920, y: 0, width: 1920, height: 1080),   // 右
    ])
check("yabaiMatch D: 同序布局恒等匹配", matchD[0] == 1 && matchD[1] == 2 && matchD[2] == 3)

// MARK: - Summary

print("\nScreenYabaiDisplayMatchTests: \(passed + failed) checks, \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
