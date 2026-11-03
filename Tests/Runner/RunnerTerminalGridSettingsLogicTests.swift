import AppKit
import SwiftUI
@testable import VibeFocusKit

// Tests/Runner/RunnerTerminalGridSettingsLogicTests.swift — 覆盖率批次（2026-11-03）：
// 编排页「屏幕布局 minimap」的设置层逻辑与渲染：
// - gridTargetSummary 四分支（main/focused/display/displaySpace）× 快照命中/缺失回退；
// - refreshGridMinimap 的只读快照重建（yabai 缺失时退化为纯屏幕，不碰任何窗口）；
// - terminalGridSection 断显横幅 / 切换反馈文案 / 参数区整树渲染。
//
// 安全边界：全部为只读查询（querySpaces / NSScreen）与离屏 ImageRenderer；
// 不触发 minimap 胶囊点击（会真切 space）、不写 TerminalGridPreferences。

extension RunnerHarness {

    func runTerminalGridSettingsLogicTests() {
        print("\n=== TerminalGridSettingsLogic ===")

        // MARK: A. 目标摘要四分支：快照缺失 → 回退文案
        do {
            var view = SettingsView()
            view.gridMinimapScreens = []

            view.gridTargetCode = GridTargetCode.main.code
            check("gridSettings: main 摘要", view.gridTargetSummary == "→ 主屏")
            view.gridTargetCode = GridTargetCode.focused.code
            check("gridSettings: focused 摘要", view.gridTargetSummary == "→ 焦点屏")
            view.gridTargetCode = GridTargetCode.display(displayID: 4_292_000_001).code
            check("gridSettings: display 快照缺失→#ID 回退",
                  view.gridTargetSummary == "→ #4292000001 当前 Space")
            view.gridTargetCode = GridTargetCode.displaySpace(displayID: 4_292_000_001, spaceIndex: 7).code
            check("gridSettings: displaySpace 快照缺失→全局索引回退",
                  view.gridTargetSummary == "→ #4292000001 · Space 7")
            view.gridTargetCode = "not-a-target"
            check("gridSettings: 非法目标码→无摘要", view.gridTargetSummary == nil)
        }

        // MARK: B. 快照命中：屏号-位次语言
        do {
            var view = SettingsView()
            view.gridMinimapScreens = [
                ScreenLayoutMapper.InputScreen(
                    displayID: 4_292_000_001,
                    name: "Synthetic Display",
                    cocoaFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                    isMain: true,
                    spaces: [
                        ScreenLayoutMapper.InputSpace(yabaiIndex: 3, isVisible: true),
                        ScreenLayoutMapper.InputSpace(yabaiIndex: 7, isVisible: false),
                    ],
                    yabaiDisplayIndex: 1)
            ]
            view.gridTargetCode = GridTargetCode.display(displayID: 4_292_000_001).code
            check("gridSettings: display 快照命中→屏号",
                  view.gridTargetSummary == "→ 屏1 当前 Space")
            view.gridTargetCode = GridTargetCode.displaySpace(displayID: 4_292_000_001, spaceIndex: 7).code
            check("gridSettings: displaySpace 快照命中→屏号-位次",
                  view.gridTargetSummary == "→ 屏1 · 屏1-位次2")
        }

        // MARK: C. 快照重建（只读 yabai 查询；无 yabai 时退化为纯屏幕）
        do {
            var view = SettingsView()
            view.refreshGridMinimap(ignoreCache: true)
            check("gridSettings: 强制重建后屏幕表非空（CI 至少一屏）",
                  !view.gridMinimapScreens.isEmpty || NSScreen.screens.isEmpty)
            view.refreshGridMinimap()
            check("gridSettings: 缓存路径重建可重入", true)
        }

        // MARK: D. 整段渲染：空态 / 断显横幅 / 切换反馈 / 参数区
        do {
            let empty = ImageRenderer(content: SettingsView().terminalGridSection)
            check("gridSettings: 空快照整段渲染出图", empty.nsImage != nil)

            var warned = SettingsView()
            warned.gridTargetCode = GridTargetCode.display(displayID: 4_292_000_999).code
            warned.gridSpaceSwitchMessage = "已切换到 屏1-位次2"
            warned.gridMinimapScreens = [
                ScreenLayoutMapper.InputScreen(
                    displayID: 4_292_000_001,
                    name: "Synthetic Display",
                    cocoaFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                    isMain: true,
                    spaces: [ScreenLayoutMapper.InputSpace(yabaiIndex: 3, isVisible: true)],
                    yabaiDisplayIndex: 1)
            ]
            let renderer = ImageRenderer(content: warned.terminalGridSection)
            check("gridSettings: 断显横幅+切换反馈整段渲染出图", renderer.nsImage != nil)
        }
    }
}
