import CoreGraphics

// ScreenGeometry.swift
// VibeFocus — 屏幕几何值模块（纯值，无 AppKit 依赖）
//
// 一次采集的 Cocoa 屏帧表 + 全仓统一的两条判定口径：
//   1. 主屏 = frame.origin == .zero（菜单栏屏 / Quartz 原点屏）；
//   2. 矩形命中 = 中心点所在屏优先；中心不在任何屏时退回正面积相交屏
//      （仅共边不算命中——相邻屏边界上的全屏窗口归中心所在屏）。
// 之前这套口径散在 CoordinateKit.primaryScreen、CoordinateKit.screenIndex、
// WindowManager.displayContext、TerminalGridController.displayContextDisplayID、
// SpaceController 几何匹配表五处，任一处改成 `screens.first` 或 `NSScreen.main`
// 就会出现「副屏窗口判成主屏」类静默错配。判定算法集中到这里，
// AppKit 侧只负责把 NSScreen.screens 映射成 cocoaFrames。

/// 一组屏幕的 Cocoa 帧几何表（与 `NSScreen.screens` 同序）。
struct ScreenGeometry: Equatable {

    /// Cocoa 全局帧（主屏左下原点，y 向上）。
    let cocoaFrames: [CGRect]

    init(cocoaFrames: [CGRect]) {
        self.cocoaFrames = cocoaFrames
    }

    var isEmpty: Bool { cocoaFrames.isEmpty }

    /// 主屏下标：origin == .zero 那块；无 origin-zero 屏时回退首元素（与
    /// `CoordinateKit.primaryScreen` 的历史兜底一致）；空表 nil。
    ///
    /// ⚠️ 不得改成 `NSScreen.main` 语义——那是焦点屏，多屏下随键盘焦点漂移。
    var primaryIndex: Int? {
        guard !cocoaFrames.isEmpty else { return nil }
        return cocoaFrames.firstIndex { $0.origin == .zero } ?? 0
    }

    /// 主屏高度（Quartz↔Cocoa 全局换算常量）；空表 0。
    var primaryHeight: CGFloat {
        primaryIndex.map { cocoaFrames[$0].height } ?? 0
    }

    /// Cocoa 全局点所在屏（严格包含，不含 max 边）；无命中 nil。
    /// 语义等价 `NSMouseInRect(point, frame, false)`，供气泡/面板「中心点在哪块屏」用。
    func index(containingCocoaPoint point: CGPoint) -> Int? {
        cocoaFrames.firstIndex { $0.contains(point) }
    }

    /// Cocoa 全局矩形所在屏：中心点命中的屏优先；中心不在任何屏（超大/越界窗）
    /// 时退回「正面积相交」的屏；无命中 nil。
    ///
    /// ## 两处刻意语义
    /// - 先做全表中心判定再退回相交：跨屏窗口按中心归属，不被屏序更靠前的
    ///   相交屏抢走（旧实现逐屏 `contains || intersects`，A 屏只沾一点就赢过
    ///   中心所在的 B 屏）。
    /// - 相交必须是正面积：`CGRect.intersects` 对**仅共边**的矩形也返回 true
    ///   （交叠面积为 0）。相邻屏边界上恰好铺满的窗口（最大化/网格格子）会与
    ///   上一块屏共边，若按 intersects 判定就会把副屏窗口记成主屏
    ///   （2026-11-05 Linux 实跑复现：全尺寸副屏 Quartz 帧被判给主屏）。
    func index(containingCocoa rect: CGRect) -> Int? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let index = cocoaFrames.firstIndex(where: { $0.contains(center) }) {
            return index
        }
        return cocoaFrames.firstIndex { frame in
            let overlap = frame.intersection(rect)
            return !overlap.isNull && overlap.width > 0 && overlap.height > 0
        }
    }

    /// Quartz 全局矩形所在屏：先按调用方给定的主屏高换算成 Cocoa 再判定。
    /// 主屏高显式注入，纯测试可传夹具值（不必依赖真机屏幕高度）。
    func index(containingQuartz rect: CGRect, primaryHeight: CGFloat) -> Int? {
        index(containingCocoa: CoordinateKit.cocoaRect(fromQuartz: rect, primaryHeight: primaryHeight))
    }

    /// Quartz 全局矩形所在屏（主屏高取自本表 primaryIndex）。
    func index(containingQuartz rect: CGRect) -> Int? {
        index(containingQuartz: rect, primaryHeight: primaryHeight)
    }
}
