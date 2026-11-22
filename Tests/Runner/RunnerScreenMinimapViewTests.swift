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

        // --- screenTapHelp 三分支（悬停/无障碍文案的唯一来源）---
        // ① 可见 space 且能算出屏内位次 → 「当前工作区 屏号-位次」；
        // ② 可见 space 但位次算不出（不在表内）→ 回落全局「Space N」；
        // ③ 无可见 space → 纯「编排到「屏名」（标号）」。
        let mapped = ScreenLayoutMapper.map(
            screens: [mainScreen, secondary], viewSize: CGSize(width: 500, height: 216), padding: 14)
        let helpView = ScreenMinimapView(
            screens: [mainScreen, secondary], selected: nil,
            gridPreviewRows: 1, gridPreviewCols: 1, height: 216, onSelect: { _ in })
        if let mappedMain = mapped.screens.first(where: { $0.displayID == 1 }) {
            let help = helpView.screenTapHelp(mappedMain)
            check("minimap: screenTapHelp 位次可算 → 屏号-位次文案（实际：\(help)）",
                  help.contains("屏\(mainScreen.yabaiDisplayIndex ?? -1)")
                  && help.contains("当前工作区"))
        }
        // ② 位次算不出：构造一个 visibleSpaceIndex 不在 spaces 表内的映射屏
        let ghostScreen = ScreenLayoutMapper.MappedScreen(
            displayID: 9, name: "ghost", isMain: false,
            frame: CGRect(x: 0, y: 0, width: 200, height: 120),
            spaces: [ScreenLayoutMapper.MappedSpace(
                yabaiIndex: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 14), isVisible: true)],
            visibleSpaceIndex: 42,
            yabaiDisplayIndex: 9)
        let ghostHelp = helpView.screenTapHelp(ghostScreen)
        check("minimap: screenTapHelp 位次算不出 → 回落全局 Space 42（实际：\(ghostHelp)）",
              ghostHelp.contains("Space 42"))
        // ③ 无可见 space
        let blankScreen = ScreenLayoutMapper.MappedScreen(
            displayID: 8, name: "blank", isMain: false,
            frame: CGRect(x: 0, y: 0, width: 200, height: 120),
            spaces: [], visibleSpaceIndex: nil, yabaiDisplayIndex: nil)
        let blankHelp = helpView.screenTapHelp(blankScreen)
        check("minimap: screenTapHelp 无可见 space → 纯编排文案并回落 #displayID（实际：\(blankHelp)）",
              blankHelp == "编排到「blank」（#8）")
    }
}
