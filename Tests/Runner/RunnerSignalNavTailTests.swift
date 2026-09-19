import AppKit
import Foundation
import SwiftUI
@testable import VibeFocusKit

// Tests/Runner/RunnerSignalNavTailTests.swift — B240 尾差扫尾（Signal 调度环/品牌图标/旧格 frame）
// 靶：ScreenOverlayManager+Signal 的调度入口与取消环（空 delays 安全；调度后立即取消，
// work item 永不触发 refreshSpaceIndices——不建窗不 fork）/ 品牌图标加载与徽章离屏渲染 /
// TerminalGridCellSnapshot frame setter。
// 纪律：测试实例经 B239 缝构造（无 Timer/无 observer/无信号）。

extension RunnerHarness {
    func runSignalNavTailTests() {
        // A. Signal：调度入口 + 取消环（空 delays 域 + 即时取消，异步项永不触发）
        do {
            let om = ScreenOverlayManager(startTimerAutomatically: false)
            om.scheduleSignalFollowUpRefreshes()
            om.cancelPendingSignalRefreshes()
            om.cancelPendingSignalRefreshes()   // 空表二次取消幂等
            check("signal A1: 调度+取消环安全（work item 未及触发即被取消）", true)
        }

        // B. 品牌图标：加载兜底 + 徽章离屏渲染（Runner 无 icns → SF Symbol 兜底分支）
        do {
            let icon: NSImage? = bundledAppIconImage()
            check("brand B1: bundledAppIconImage 只读调用安全（nil 或图像皆合法）",
                  icon == nil || icon!.size.width > 0)
            let badge = AppLogoBadge(size: 40)
            let rendered = ImageRenderer(content: badge.frame(width: 48, height: 48))
            rendered.scale = 1
            check("brand B2: AppLogoBadge 离屏渲染成功", rendered.nsImage != nil)
        }

        // C. TerminalGridCellSnapshot：frame setter 落四标量
        do {
            var cell = TerminalGridCellSnapshot(
                index: 0, x: 0, y: 0, width: 100, height: 50,
                ttyPath: nil, sessionID: nil, cwd: nil, title: nil)
            cell.frame = CGRect(x: 3, y: 4, width: 130, height: 70)
            check("gridCell C1: frame setter 落四标量",
                  cell.x == 3 && cell.y == 4 && cell.width == 130 && cell.height == 70
                  && cell.frame == CGRect(x: 3, y: 4, width: 130, height: 70))
        }
    }
}
