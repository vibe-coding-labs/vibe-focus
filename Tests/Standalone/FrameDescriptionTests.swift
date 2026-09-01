// Tests/Standalone/FrameDescriptionTests.swift
// Verification: 帧日志描述族（"x,y WxH" / "x,y" / "WxH"）唯一事实源
// Mirrors: Sources/Space/CoordinateKit.swift (QuartzRect description / originDescription / sizeDescription)
// Run: swift Tests/Standalone/FrameDescriptionTests.swift
//
// 背景（playbook 2.16a 第十五刀）：帧日志描述曾以 27 处内联格式串散落 7 文件
// （"\(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))" 及其
// origin-only / size-only 变体），任何人手滑改一处（空格/逗号/取整方式）日志格式即漂移，
// 依赖日志 grep 的问题排查随之失真。本测试锁定格式族契约：
// 格式本身、Int() 向零截断语义（含负坐标——副屏在主屏左侧/上方时坐标为负）、
// 三变体组合一致性，以及与历史内联格式的逐字符等价（防漂移断言）。

import Foundation
import CoreGraphics

// MARK: - Extracted pure logic

/// Mirrors QuartzRect（CoordinateKit.swift）的日志描述族
struct MirrorQuartzRect {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    /// 全帧描述 "x,y WxH"（Mirrors QuartzRect.description）
    var description: String { "\(Int(x)),\(Int(y)) \(Int(width))x\(Int(height))" }
    /// origin-only 描述 "x,y"（Mirrors QuartzRect.originDescription）
    var originDescription: String { "\(Int(x)),\(Int(y))" }
    /// size-only 描述 "WxH"（Mirrors QuartzRect.sizeDescription）
    var sizeDescription: String { "\(Int(width))x\(Int(height))" }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

// MARK: 1. 格式锁定 — 三变体

print("1. 格式锁定")

let sample = MirrorQuartzRect(x: 100, y: 200, width: 800, height: 600)
check("全帧格式 \"x,y WxH\"", sample.description == "100,200 800x600")
check("origin-only 格式 \"x,y\"", sample.originDescription == "100,200")
check("size-only 格式 \"WxH\"", sample.sizeDescription == "800x600")

// MARK: 2. 截断语义 — Int() 向零截断（非四舍五入、非 floor）

print("\n2. 截断语义")

let fractional = MirrorQuartzRect(x: 100.7, y: 200.3, width: 800.9, height: 600.1)
check("小数截断：100.7,200.3 800.9x600.1 → \"100,200 800x600\"（与历史内联格式逐字符一致）",
      fractional.description == "100,200 800x600")

let negative = MirrorQuartzRect(x: -1.9, y: -10.5, width: 300.7, height: 200.2)
check("负坐标向零截断：-1.9 → -1（不是 floor 的 -2；副屏在主屏左侧/上方时坐标为负）",
      negative.originDescription == "-1,-10")

check("正小数向零截断：0.9 → 0（不是四舍五入的 1）",
      MirrorQuartzRect(x: 0.9, y: 0.9, width: 0.9, height: 0.9).description == "0,0 0x0")

// MARK: 3. 组合一致性 — 三变体出自同一份数值

print("\n3. 组合一致性")

func consistent(_ r: MirrorQuartzRect) -> Bool {
    r.description == "\(r.originDescription) \(r.sizeDescription)"
}
check("全帧 = origin-only + 空格 + size-only",
      consistent(sample) && consistent(fractional) && consistent(negative))

let cases: [MirrorQuartzRect] = [
    MirrorQuartzRect(x: 0, y: 0, width: 0, height: 0),
    MirrorQuartzRect(x: -1920, y: -500, width: 1920, height: 1080),
    MirrorQuartzRect(x: 2560.99, y: 144.01, width: 1280.5, height: 720.5),
    MirrorQuartzRect(x: 3000, y: 2000, width: 100, height: 80),
]
check("边界矩阵（零帧/全负 origin/正小数/大坐标）组合一致性全成立",
      cases.allSatisfy(consistent))

// MARK: 4. 防漂移 — 与历史内联格式逐字符等价

print("\n4. 防漂移断言")

func legacyInline(x: Double, y: Double, w: Double, h: Double) -> String {
    // 第十五刀前 27 处调用点的写法（截取自 WindowManager+MoveWindow.swift 旧实现）
    return "\(Int(x)),\(Int(y)) \(Int(w))x\(Int(h))"
}

let probes: [(MirrorQuartzRect, String)] = [
    (sample, legacyInline(x: 100, y: 200, w: 800, h: 600)),
    (fractional, legacyInline(x: 100.7, y: 200.3, w: 800.9, h: 600.1)),
    (negative, legacyInline(x: -1.9, y: -10.5, w: 300.7, h: 200.2)),
]
check("新描述族与历史内联格式串逐字符等价（纯接线重构，日志输出零变化）",
      probes.allSatisfy { $0.0.description == $0.1 })

check("origin-only/size-only 与历史内联等价",
      negative.originDescription == "\(Int(-1.9)),\(Int(-10.5))"
      && negative.sizeDescription == "\(Int(300.7))x\(Int(200.2))")

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
