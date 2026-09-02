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
    static func writeOrder(
        currentSize: CGSize?,
        targetSize: CGSize,
        sourceVisibleSize: CGSize? = nil
    ) -> FrameWriteOrder {
        guard let current = currentSize else { return .moveThenResize }
        let shrinking = current.width > targetSize.width || current.height > targetSize.height
        guard shrinking else { return .moveThenResize }
        if let vis = sourceVisibleSize,
           targetSize.width > vis.width || targetSize.height > vis.height {
            return .moveThenResize
        }
        return .resizeThenMove
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

print("5. clamp 规避分支（2026-09-03：目标任一维超源屏可见区 → 禁用收窄序）")
do {
    // 实测场景：move_to_main 副屏 1922×1055 → 主屏 1646×1079（宽缩高放），源屏 display2 可见 1920×1055。
    // 修复前判收窄序 → resize 被钳到 1055 高 → MOVE FAILED 走满 2s。
    let current = CGSize(width: 1922, height: 1055)
    let target = CGSize(width: 1646, height: 1079)
    let sourceVis = CGSize(width: 1920, height: 1055)
    check("副→主混合（宽缩高放）+ 目标高超源屏可见 → moveThenResize（clamp 规避）",
          FrameConvergence.writeOrder(currentSize: current, targetSize: target,
                                      sourceVisibleSize: sourceVis) == .moveThenResize)
    check("同场景 sourceVisibleSize=nil → 退回收窄判定 resizeThenMove（行为兼容）",
          FrameConvergence.writeOrder(currentSize: current, targetSize: target) == .resizeThenMove)
    // restore 主→副收窄：目标 640×527 远小于源屏可见 1646×1079 → clamp 不触发，维持收窄序
    check("restore 主→副目标不超源屏可见区 → 维持 resizeThenMove",
          FrameConvergence.writeOrder(currentSize: CGSize(width: 1649, height: 1079),
                                      targetSize: CGSize(width: 640, height: 527),
                                      sourceVisibleSize: CGSize(width: 1646, height: 1079)) == .resizeThenMove)
    // 宽度超源屏可见也规避
    check("目标宽超源屏可见区 → moveThenResize",
          FrameConvergence.writeOrder(currentSize: CGSize(width: 1000, height: 400),
                                      targetSize: CGSize(width: 2000, height: 300),
                                      sourceVisibleSize: CGSize(width: 1646, height: 1079)) == .moveThenResize)
}

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed == 0 ? 0 : 1)
