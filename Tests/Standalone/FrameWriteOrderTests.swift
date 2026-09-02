// Tests/Standalone/FrameWriteOrderTests.swift
// Verification: move/resize 两段写入顺序决策（收窄先 resize 后 move，放大先 move 后 resize）
// Mirrors: Sources/Support/FrameConvergence.swift (FrameConvergence.writeOrder / FrameWriteOrder)
// Run: swift Tests/Standalone/FrameWriteOrderTests.swift

import Foundation

// MARK: - Mirrored type

enum FrameWriteOrder: Equatable {
    case resizeThenMove
    case moveThenResize
}

enum FrameConvergence {
    static func writeOrder(currentSize: CGSize?, targetSize: CGSize) -> FrameWriteOrder {
        guard let current = currentSize else { return .moveThenResize }
        let shrinking = current.width > targetSize.width || current.height > targetSize.height
        return shrinking ? .resizeThenMove : .moveThenResize
    }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

print("1. 防御分支：currentSize 读不到")
do {
    check("currentSize=nil → moveThenResize（历史顺序）",
          FrameConvergence.writeOrder(currentSize: nil, targetSize: CGSize(width: 640, height: 527)) == .moveThenResize)
}

print("2. 收窄分支（任一维度大于目标 → 先 resize 后 move）")
do {
    check("宽高都大于 → resizeThenMove",
          FrameConvergence.writeOrder(currentSize: CGSize(width: 1649, height: 1079),
                                      targetSize: CGSize(width: 640, height: 527)) == .resizeThenMove)
    check("仅宽度大于 → resizeThenMove",
          FrameConvergence.writeOrder(currentSize: CGSize(width: 800, height: 400),
                                      targetSize: CGSize(width: 640, height: 527)) == .resizeThenMove)
    check("仅高度大于 → resizeThenMove",
          FrameConvergence.writeOrder(currentSize: CGSize(width: 500, height: 900),
                                      targetSize: CGSize(width: 640, height: 527)) == .resizeThenMove)
}

print("3. 放大/持平分支（先 move 后 resize）")
do {
    check("宽高都小于 → moveThenResize",
          FrameConvergence.writeOrder(currentSize: CGSize(width: 640, height: 527),
                                      targetSize: CGSize(width: 1649, height: 1079)) == .moveThenResize)
    check("尺寸完全相等 → moveThenResize",
          FrameConvergence.writeOrder(currentSize: CGSize(width: 640, height: 527),
                                      targetSize: CGSize(width: 640, height: 527)) == .moveThenResize)
}

print("4. 真实场景 fixture（三屏布局实测：主屏 1649×1079，副屏窗 640×527）")
do {
    // 主→副 restore：全屏大窗回副屏（2026-09-03 乱蹦 BUG 的实际尺寸）
    check("restore 主→副（1649×1079 → 640×527）→ resizeThenMove",
          FrameConvergence.writeOrder(currentSize: CGSize(width: 1649, height: 1079),
                                      targetSize: CGSize(width: 640, height: 527)) == .resizeThenMove)
    // 副→主 toggle：小窗到主屏放大
    check("toggle 副→主（640×527 → 1649×1079）→ moveThenResize",
          FrameConvergence.writeOrder(currentSize: CGSize(width: 640, height: 527),
                                      targetSize: CGSize(width: 1649, height: 1079)) == .moveThenResize)
}

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed == 0 ? 0 : 1)
