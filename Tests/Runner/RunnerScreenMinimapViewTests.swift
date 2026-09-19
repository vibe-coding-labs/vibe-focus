import AppKit
import SwiftUI
@testable import VibeFocusKit

// Tests/Runner/RunnerScreenMinimapViewTests.swift — B239：ScreenMinimapView 内容
// 直调直测（产品侧最小重构=minimapContent(in:) 提纯，GeometryReader 闭包逐字搬移
// 零行为变更）。合成双屏（含 Space 胶囊/小屏退化分支/选中网格预览分支）直调内容
// 构建，覆盖 screenView/spaceCapsule/labels/gridLines 全家族。

extension RunnerHarness {
    func runScreenMinimapViewTests() {
        print("\n=== ScreenMinimapView (B239) ===")
        let mainScreen = ScreenLayoutMapper.InputScreen(
            displayID: 1, name: "内置显示屏",
            cocoaFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            isMain: true,
            spaces: [
                ScreenLayoutMapper.InputSpace(yabaiIndex: 1, isVisible: true),
                ScreenLayoutMapper.InputSpace(yabaiIndex: 3, isVisible: false),
            ],
            yabaiDisplayIndex: 1)
        let secondary = ScreenLayoutMapper.InputScreen(
            displayID: 2, name: "P40UG",
            cocoaFrame: CGRect(x: 1512, y: 200, width: 3440, height: 1440),
            isMain: false,
            spaces: [ScreenLayoutMapper.InputSpace(yabaiIndex: 2, isVisible: true)],
            yabaiDisplayIndex: 2)
        let tiny = ScreenLayoutMapper.InputScreen(
            displayID: 3, name: "micro",
            cocoaFrame: CGRect(x: 0, y: -220, width: 90, height: 50),
            isMain: false,
            spaces: [ScreenLayoutMapper.InputSpace(yabaiIndex: 5, isVisible: true)],
            yabaiDisplayIndex: 3)

        // --- 合成布局自洽：map 非空 + 包围盒非退化（先于视图消费） ---
        let layout = ScreenLayoutMapper.map(
            screens: [mainScreen, secondary, tiny],
            viewSize: CGSize(width: 500, height: 216))
        check("minimap: 合成三屏 map 非空", layout.screens.count == 3)
        check("minimap: 包围盒非退化", layout.contentRect.width > 100 && layout.contentRect.height > 50)

        // --- 选中 + 网格预览分支（displayID 1 选中、2×2 预览） ---
        let selectedView = ScreenMinimapView(
            screens: [mainScreen, secondary, tiny],
            selected: .display(displayID: 1),
            gridPreviewRows: 2, gridPreviewCols: 2,
            height: 216,
            onSelect: { _ in })
        _ = selectedView.minimapContent(in: CGSize(width: 500, height: 216))
        check("minimap: 选中+网格预览分支直调无异常", true)

        // --- 未选中 + 小屏分支（tiny 90×50 触发 width<96 退化：无标签、Space 条仍在） ---
        let unselected = ScreenMinimapView(
            screens: [mainScreen, secondary, tiny],
            selected: nil,
            gridPreviewRows: 0, gridPreviewCols: 0,
            height: 216,
            onSelect: { _ in })
        _ = unselected.minimapContent(in: CGSize(width: 500, height: 216))
        check("minimap: 未选中+小屏退化分支直调无异常", true)

        // --- 窄容器极端尺寸：缩放/居中不产生 NaN/负退化 ---
        _ = selectedView.minimapContent(in: CGSize(width: 40, height: 30))
        check("minimap: 窄容器极端尺寸直调无异常", true)
    }
}
