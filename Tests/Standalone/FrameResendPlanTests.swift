// Tests/Standalone/FrameResendPlanTests.swift
// Verification: 补发计划唯一事实源（shortfalls 偏差维判定 + resendSegments 补发序列）
// Mirrors: Sources/Support/FrameConvergence.swift (FrameShortfall/FrameSegment/
//          FrameConvergence.shortfalls/resendSegments)
// Run: swift Tests/Standalone/FrameResendPlanTests.swift

import Foundation
import CoreGraphics

// MARK: - Mirrored types

enum FrameWriteOrder: Equatable {
    case resizeThenMove
    case moveThenResize
}

enum FrameSegment: Equatable {
    case move
    case resize
}

struct FrameShortfall: OptionSet, Equatable {
    let rawValue: UInt8
    static let origin = FrameShortfall(rawValue: 1 << 0)
    static let size = FrameShortfall(rawValue: 1 << 1)
}

enum FrameConvergence {
    static func shortfalls(
        current: CGRect?,
        target: CGRect,
        tolerance: CGFloat
    ) -> FrameShortfall {
        guard let current else { return [.origin, .size] }
        var shortfall: FrameShortfall = []
        if abs(current.origin.x - target.origin.x) + abs(current.origin.y - target.origin.y) > tolerance { shortfall.insert(.origin) }
        if abs(current.size.width - target.size.width) + abs(current.size.height - target.size.height) > tolerance { shortfall.insert(.size) }
        return shortfall
    }

    static func resendSegments(
        shortfall: FrameShortfall,
        order: FrameWriteOrder
    ) -> [FrameSegment] {
        switch shortfall {
        case []: return []
        case .origin: return [.move]
        case .size: return [.resize]
        default:
            return order == .resizeThenMove ? [.resize, .move] : [.move, .resize]
        }
    }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

print("1. shortfalls：偏差维判定（真机 fixture：主屏目标 75,38 1653×1079，容差 20）")
do {
    let target = CGRect(x: 75, y: 38, width: 1653, height: 1079)
    check("双维容差内 → 空集",
          FrameConvergence.shortfalls(current: CGRect(x: 80, y: 40, width: 1650, height: 1075),
                                      target: target, tolerance: 20).isEmpty)
    check("origin 漂移和 21 > 20 → [.origin]",
          FrameConvergence.shortfalls(current: CGRect(x: 96, y: 38, width: 1653, height: 1079),
                                      target: target, tolerance: 20) == [.origin])
    check("size 漂移和 21 > 20 → [.size]",
          FrameConvergence.shortfalls(current: CGRect(x: 75, y: 38, width: 1653, height: 1058),
                                      target: target, tolerance: 20) == [.size])
    check("双维超 → [.origin, .size]",
          FrameConvergence.shortfalls(current: CGRect(x: 500, y: 500, width: 800, height: 600),
                                      target: target, tolerance: 20) == [.origin, .size])
    check("恰在容差边界（=20，≤ 判定）→ 空集",
          FrameConvergence.shortfalls(current: CGRect(x: 95, y: 38, width: 1653, height: 1079),
                                      target: target, tolerance: 20).isEmpty)
    check("current=nil → 全缺（最坏防御，历史 ?? false 语义）",
          FrameConvergence.shortfalls(current: nil, target: target, tolerance: 20) == [.origin, .size])
}

print("2. resendSegments：四分支 × 两写序")
do {
    check("无偏差 → 空计划（防御分支）",
          FrameConvergence.resendSegments(shortfall: [], order: .resizeThenMove).isEmpty)
    check("仅 origin 缺 → [.move]（两写序同）",
          FrameConvergence.resendSegments(shortfall: [.origin], order: .resizeThenMove) == [.move]
          && FrameConvergence.resendSegments(shortfall: [.origin], order: .moveThenResize) == [.move])
    check("仅 size 缺 → [.resize]（两写序同）",
          FrameConvergence.resendSegments(shortfall: [.size], order: .moveThenResize) == [.resize]
          && FrameConvergence.resendSegments(shortfall: [.size], order: .resizeThenMove) == [.resize])
    check("全缺 × resizeThenMove → resize→move（源屏先行序，水波修复）",
          FrameConvergence.resendSegments(shortfall: [.origin, .size], order: .resizeThenMove) == [.resize, .move])
    check("全缺 × moveThenResize → move→resize（历史序）",
          FrameConvergence.resendSegments(shortfall: [.origin, .size], order: .moveThenResize) == [.move, .resize])
}

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed == 0 ? 0 : 1)
