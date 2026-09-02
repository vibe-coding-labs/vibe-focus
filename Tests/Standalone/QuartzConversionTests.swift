// Tests/Standalone/QuartzConversionTests.swift
// Verification: AppKit→Quartz 全局 y 换算（主屏/上方副屏/下方副屏统一公式）
// Mirrors: Sources/Space/CoordinateKit.swift (CoordinateKit.quartzY / quartzVisibleFrame 的 y 换算)
// Run: swift Tests/Standalone/QuartzConversionTests.swift

import Foundation

// MARK: - Mirrored type

enum CoordinateKit {
    static func quartzY(appKitRectMaxY: CGFloat, primaryMaxY: CGFloat) -> CGFloat {
        primaryMaxY - appKitRectMaxY
    }

    // quartzVisibleFrame 的 y 分支换算（x/w/h 直传，镜像换算公式整体）
    static func quartzVisibleFrameY(appKitVisibleMaxY: CGFloat, primaryMaxY: CGFloat) -> CGFloat {
        quartzY(appKitRectMaxY: appKitVisibleMaxY, primaryMaxY: primaryMaxY)
    }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

// 真实布局 fixture（2026-09-03 三屏实测）：
// 主屏 Quartz frame (0,0 1728x1117)；上方副屏 (-954,-1080 1920x1080)；AppKit 主屏 maxY=1117。
let primaryMaxY: CGFloat = 1117

print("1. 主屏（AppKit origin 为零，历史分支语义不变）")
do {
    // 主屏 visibleFrame：AppKit y ∈ [28(dock), 1092(1117-菜单栏25)]，Quartz y 应为 25
    check("主屏可见区 quartzY=25（菜单栏高度）",
          CoordinateKit.quartzVisibleFrameY(appKitVisibleMaxY: 1092, primaryMaxY: primaryMaxY) == 25)
    check("主屏满屏 quartzY=0",
          CoordinateKit.quartzVisibleFrameY(appKitVisibleMaxY: 1117, primaryMaxY: primaryMaxY) == 0)
}

print("2. 上方副屏（本机实际布局：AppKit frame y=1117..2197，Quartz 应为 -1080..0）")
do {
    // 上方副屏 visibleFrame：AppKit maxY = 2197-25(菜单栏) = 2172 → Quartz y = 1117-2172 = -1055
    check("上方副屏可见区 quartzY=-1055（修复前错误返回 +1117 → 窗口被写到主屏下方屏外）",
          CoordinateKit.quartzVisibleFrameY(appKitVisibleMaxY: 2172, primaryMaxY: primaryMaxY) == -1055)
    check("上方副屏满屏 quartzY=-1080",
          CoordinateKit.quartzVisibleFrameY(appKitVisibleMaxY: 2197, primaryMaxY: primaryMaxY) == -1080)
}

print("3. 下方副屏（假设排在主屏下方：AppKit y=-1083..34，Quartz 应为 1083..1117）")
do {
    // 下方副屏 AppKit frame minY=-1083、maxY=34 → 可见区 maxY=34 → Quartz y=1117-34=1083
    check("下方副屏可见区 quartzY=1083（落在主屏下方真实位置）",
          CoordinateKit.quartzVisibleFrameY(appKitVisibleMaxY: 34, primaryMaxY: primaryMaxY) == 1083)
}

print("4. 纯函数对称性（同一矩形换算往返）")
do {
    let quartzY = CoordinateKit.quartzY(appKitRectMaxY: 2172, primaryMaxY: primaryMaxY)
    // 反向换算：appKitMaxY = primaryMaxY - quartzY
    check("往返换算还原 AppKit maxY", primaryMaxY - quartzY == 2172)
}

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed == 0 ? 0 : 1)
