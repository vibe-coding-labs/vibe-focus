// Tests/Standalone/FrameClampTests.swift
// Verification: 帧夹取纯函数（保守退让共用）
// Mirrors: Sources/Space/CoordinateKit.swift (clampFrame)
// Run: swift Tests/Standalone/FrameClampTests.swift
//
// 背景（2026-09-06 P1 破坏性兜底清查）：restore 的 origFrame 落在所有屏之外时
// 旧行为直接清 record 放弃还原，窗口卡在主屏全屏态（用户主诉「尺寸/位置搞错」）。
// 修复 = 原始帧夹进源屏可视区重试。stuck 解堵的尺寸保持也复用本函数。

import Foundation
import CoreGraphics

// MARK: - Mirrored logic

func clampFrame(_ frame: CGRect, into bounds: CGRect) -> CGRect {
    let width = min(frame.width, bounds.width)
    let height = min(frame.height, bounds.height)
    let x = max(bounds.minX, min(frame.origin.x, bounds.maxX - width))
    let y = max(bounds.minY, min(frame.origin.y, bounds.maxY - height))
    return CGRect(x: x, y: y, width: width, height: height)
}

// MARK: - Assertions

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond {
        print("  PASS: \(name)")
    } else {
        failures += 1
        print("  FAIL: \(name)")
    }
}

// 副屏可视区（本机实况：P40UG 在主屏上方，Quartz 负 y 区）
let secondaryVisible = CGRect(x: -814, y: -1440, width: 3440, height: 1440)

// 1. 完全在界内 → 原样返回（不扰动）
let inside = CGRect(x: 100, y: -1000, width: 800, height: 600)
check(clampFrame(inside, into: secondaryVisible) == inside, "界内帧原样保留")

// 2. 完全屏外（x 超右界、y 超下界）→ 尺寸不变、位置夹回右下角内侧
let offScreen = CGRect(x: 5000, y: 500, width: 800, height: 600)
let clamped = clampFrame(offScreen, into: secondaryVisible)
check(clamped.size == offScreen.size, "屏外帧尺寸保持")
check(clamped.maxX <= secondaryVisible.maxX && clamped.maxY <= secondaryVisible.maxY,
      "夹回后整框在界内")
check(abs(clamped.minX - (secondaryVisible.maxX - 800)) < 0.5
      && abs(clamped.minY - (secondaryVisible.maxY - 600)) < 0.5,
      "位置夹到右/下边界内侧")

// 3. 窗口大于 bounds → 尺寸收窄到 bounds、钉在原点
let huge = CGRect(x: -2000, y: -2000, width: 5000, height: 3000)
let shrunk = clampFrame(huge, into: secondaryVisible)
check(shrunk.size == secondaryVisible.size, "超大帧尺寸收窄为 bounds")
check(shrunk.origin == secondaryVisible.origin, "超大帧位置钉在 bounds 原点")

// 4. 部分越界（左/上越界）→ 位置夹回，尺寸不变
let partialOff = CGRect(x: -2000, y: -1700, width: 800, height: 600)
let partial = clampFrame(partialOff, into: secondaryVisible)
check(partial.origin == secondaryVisible.origin && partial.size == partialOff.size,
      "部分越界位置夹回且尺寸不变")

// 5. 零尺寸帧 → 退化合法（夹到原点）
let zero = clampFrame(CGRect(x: 9999, y: 9999, width: 0, height: 0), into: secondaryVisible)
check(zero.width == 0 && zero.height == 0
      && zero.origin.x >= secondaryVisible.minX && zero.origin.y >= secondaryVisible.minY,
      "零尺寸帧不产生非法值")

print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
exit(failures == 0 ? 0 : 1)
