import AppKit
import SwiftUI
@testable import VibeFocusKit

// Tests/Runner/RunnerMinimapLabelTests.swift — 覆盖率批次 10（B241）：
// ScreenMinimapView 标注/判定纯逻辑直测（B241 提缝：6 个 private 方法升 internal，
// 仅可见性零行为变更）。MappedScreen 由 ScreenLayoutMapper.map 真实映射产物构造。

extension RunnerHarness {
    func runMinimapLabelTests() {
        // 双屏样例：主屏 1728×1117（yabai 1，可见 Space 1）；副屏 3440×1440（yabai 2，可见 Space 3）
        let inputs: [ScreenLayoutMapper.InputScreen] = [
            ScreenLayoutMapper.InputScreen(
                displayID: 1, name: "Built-in",
                cocoaFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117), isMain: true,
                spaces: [ScreenLayoutMapper.InputSpace(yabaiIndex: 1, isVisible: true)],
                yabaiDisplayIndex: 1),
            ScreenLayoutMapper.InputScreen(
                displayID: 2, name: "P40UG",
                cocoaFrame: CGRect(x: 0, y: 1117, width: 3440, height: 1440), isMain: false,
                spaces: [ScreenLayoutMapper.InputSpace(yabaiIndex: 1, isVisible: false),
                         ScreenLayoutMapper.InputSpace(yabaiIndex: 3, isVisible: true)],
                yabaiDisplayIndex: 2),
        ]
        let mapped = ScreenLayoutMapper.map(screens: inputs, viewSize: CGSize(width: 400, height: 220))
        check("minimapLabel: map 产出两块 MappedScreen",
              mapped.screens.count == 2)
        guard let mainScreen = mapped.screens.first(where: { $0.displayID == 1 }),
              let sideScreen = mapped.screens.first(where: { $0.displayID == 2 }) else {
            check("minimapLabel: 双屏可定位", false)
            return
        }

        let view = ScreenMinimapView(
            screens: inputs, selected: .display(displayID: 1),
            gridPreviewRows: 3, gridPreviewCols: 4, height: 216, onSelect: { _ in })

        // MARK: A. isSelectedScreen：selected displayID 匹配判定
        check("minimapLabel: isSelectedScreen 选中屏 true",
              view.isSelectedScreen(mainScreen))
        check("minimapLabel: isSelectedScreen 未选屏 false",
              !view.isSelectedScreen(sideScreen))

        // MARK: B. smallScreen：渲染阈值（宽 <96 或高 <64 不画文字标签）
        let tiny = ScreenLayoutMapper.MappedScreen(
            displayID: 9, name: "tiny", isMain: false,
            frame: CGRect(x: 0, y: 0, width: 90, height: 50),
            spaces: [], visibleSpaceIndex: nil, yabaiDisplayIndex: nil)
        check("minimapLabel: smallScreen 小屏阈值命中",
              view.smallScreen(tiny) && !view.smallScreen(mainScreen))

        // MARK: C. labelLine：尺寸 × 屏号（yabai 优先/#CG 兜底）× S标注 三段
        check("minimapLabel: labelLine yabai 屏号+可见 Space 位次标注",
              view.labelLine(mainScreen).contains("1728×1117")
              && view.labelLine(mainScreen).contains("屏1")
              && view.labelLine(mainScreen).contains("S1-1"))
        // yabai 不可用 → #displayID 兜底；无可见 Space 数据 → 无 S 段
        let noYabai = ScreenLayoutMapper.MappedScreen(
            displayID: 77, name: "ghost", isMain: false,
            frame: CGRect(x: 0, y: 0, width: 200, height: 120),
            spaces: [], visibleSpaceIndex: nil, yabaiDisplayIndex: nil)
        check("minimapLabel: labelLine 无 yabai 走 #displayID 兜底且无 S 段",
              view.labelLine(noYabai).contains("#77")
              && !view.labelLine(noYabai).contains("S"))

        // MARK: D. screenTapHelp：点击帮助文案（含屏标注与工作区提示）
        let mainHelp = view.screenTapHelp(mainScreen)
        check("minimapLabel: screenTapHelp 含屏标注与工作区字样",
              mainHelp.contains("屏1") && mainHelp.contains("工作区"))

        // MARK: E. screenView/screenLabels 求值（构建表达式，选中/未选/hover 三态参数化）
        let _ = view.screenView(mainScreen)
        let _ = view.screenView(sideScreen)
        let _ = view.screenView(tiny)
        let _ = view.screenLabels(mainScreen, selected: true)
        let _ = view.screenLabels(sideScreen, selected: false)
        check("minimapLabel: screenView/screenLabels 三态求值无异常", true)
    }
}
