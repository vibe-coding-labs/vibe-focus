// Tests/Standalone/FrameWriteOrderTests.swift
// Verification: move/resize 两段写入顺序决策（收窄先 resize 后 move；放大无 clamp+包含时
// 源屏先行，否则 move 后 resize——2026-09-06 水波修复）
// Mirrors: Sources/Support/FrameConvergence.swift (FrameConvergence.writeOrder / FrameWriteOrder)
// Run: swift Tests/Standalone/FrameWriteOrderTests.swift

import Foundation
import CoreGraphics

// MARK: - Mirrored type

enum FrameWriteOrder: Equatable {
    case resizeThenMove
    case moveThenResize
}

enum FrameConvergence {
    static func writeOrder(
        currentSize: CGSize?,
        targetSize: CGSize,
        sourceVisibleSize: CGSize? = nil,
        currentFrame: CGRect? = nil,
        sourceVisibleFrame: CGRect? = nil
    ) -> FrameWriteOrder {
        guard let current = currentSize else { return .moveThenResize }
        let shrinking = current.width > targetSize.width || current.height > targetSize.height
        if shrinking {
            if let vis = sourceVisibleSize,
               targetSize.width > vis.width || targetSize.height > vis.height {
                return .moveThenResize
            }
            return .resizeThenMove
        }
        // 放大/持平：源屏安全先行（终态落地，目的地无生长水波）；中间态必须同时
        // 无 clamp（尺寸 fits 源屏可视区）与无归属漂移（整框仍在源屏可视区内）。
        if let frame = currentFrame,
           let visFrame = sourceVisibleFrame,
           targetSize.width <= visFrame.width, targetSize.height <= visFrame.height,
           visFrame.contains(CGRect(origin: frame.origin, size: targetSize)) {
            return .resizeThenMove
        }
        return .moveThenResize
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

print("3. 放大/持平分支（新参数未传 → 历史顺序 move 后 resize）")
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
    // 副→主 toggle：小窗到主屏放大（新参数未传，历史行为兼容）
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

print("6. 放大序源屏先行（2026-09-06：副→主终态落地，目的地无生长水波）")
do {
    // 真机 fixture（2026-09-06 toggle-00001276）：副屏小窗 1145×705@(-814,-1415) →
    // 主屏 1653×1079@(75,38)；副屏可视区 (-856,-1415,3440,1415)。中间态
    // (-814,-1415,1653,1079) 完整落在副屏可视区内 → resize 先行安全。
    check("副→主小窗放大+中间态在源屏内 → resizeThenMove（终态落地）",
          FrameConvergence.writeOrder(currentSize: CGSize(width: 1145, height: 705),
                                      targetSize: CGSize(width: 1653, height: 1079),
                                      sourceVisibleSize: CGSize(width: 3440, height: 1415),
                                      currentFrame: CGRect(x: -814, y: -1415, width: 1145, height: 705),
                                      sourceVisibleFrame: CGRect(x: -856, y: -1415, width: 3440, height: 1415)) == .resizeThenMove)
    // restore 主→副全屏放大：目标 3440×1415 超源屏（主屏）可视区 → clamp 风险 → 维持旧序
    check("主→副全屏放大目标超源屏可视区 → moveThenResize（clamp 规避）",
          FrameConvergence.writeOrder(currentSize: CGSize(width: 1653, height: 1079),
                                      targetSize: CGSize(width: 3440, height: 1415),
                                      sourceVisibleSize: CGSize(width: 1728, height: 1079),
                                      currentFrame: CGRect(x: 75, y: 0, width: 1653, height: 1079),
                                      sourceVisibleFrame: CGRect(x: 0, y: 38, width: 1728, height: 1079)) == .moveThenResize)
    // 中间态（旧 origin + 目标尺寸）越出源屏可视区右缘 → 归属漂移风险 → 维持旧序
    check("放大但中间态越出源屏右缘 → moveThenResize（归属漂移规避）",
          FrameConvergence.writeOrder(currentSize: CGSize(width: 600, height: 400),
                                      targetSize: CGSize(width: 1653, height: 1079),
                                      sourceVisibleSize: CGSize(width: 3440, height: 1415),
                                      currentFrame: CGRect(x: 3000, y: -1400, width: 600, height: 400),
                                      sourceVisibleFrame: CGRect(x: -856, y: -1415, width: 3440, height: 1415)) == .moveThenResize)
    // 尺寸 fits 但缺 currentFrame/sourceVisibleFrame → 历史行为
    check("放大但新参数未传（仅 sourceVisibleSize）→ moveThenResize（行为兼容）",
          FrameConvergence.writeOrder(currentSize: CGSize(width: 640, height: 527),
                                      targetSize: CGSize(width: 1649, height: 1079),
                                      sourceVisibleSize: CGSize(width: 3440, height: 1415)) == .moveThenResize)
    // 中间态恰好完全贴合源屏可视区（边界相等算包含）→ 允许先行
    check("放大中间态贴合源屏可视区边界 → resizeThenMove（边界包含成立）",
          FrameConvergence.writeOrder(currentSize: CGSize(width: 600, height: 400),
                                      targetSize: CGSize(width: 3440, height: 1415),
                                      sourceVisibleSize: CGSize(width: 3440, height: 1415),
                                      currentFrame: CGRect(x: -856, y: -1415, width: 600, height: 400),
                                      sourceVisibleFrame: CGRect(x: -856, y: -1415, width: 3440, height: 1415)) == .resizeThenMove)
}

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed == 0 ? 0 : 1)
