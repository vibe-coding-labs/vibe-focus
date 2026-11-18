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
            // 无窗环境下 post-install 写 @State 不落 storage（B317 注记），
            // 走 init(gridTargetCode:) 测试缝注入初始值。
            func summary(_ code: String) -> String? {
                SettingsView(gridTargetCode: code).gridTargetSummary
            }
            check("gridSettings: main 摘要", summary(GridTargetCode.main.code) == "→ 主屏")
            check("gridSettings: focused 摘要", summary(GridTargetCode.focused.code) == "→ 焦点屏")
            check("gridSettings: display 快照缺失→#ID 回退",
                  summary(GridTargetCode.display(displayID: 4_292_000_001).code) == "→ #4292000001 当前 Space")
            check("gridSettings: displaySpace 快照缺失→全局索引回退",
                  summary(GridTargetCode.displaySpace(displayID: 4_292_000_001, spaceIndex: 7).code) == "→ #4292000001 · Space 7")
            check("gridSettings: 非法目标码→无摘要", summary("not-a-target") == nil)
        }

        // MARK: B. 快照命中：屏号-位次语言
        do {
            let screens = [
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
            func summary(_ code: String) -> String? {
                SettingsView(gridTargetCode: code, gridMinimapScreens: screens).gridTargetSummary
            }
            check("gridSettings: display 快照命中→屏号",
                  summary(GridTargetCode.display(displayID: 4_292_000_001).code) == "→ 屏1 当前 Space")
            check("gridSettings: displaySpace 快照命中→屏号-位次",
                  summary(GridTargetCode.displaySpace(displayID: 4_292_000_001, spaceIndex: 7).code) == "→ 屏1 · 1-2")
        }

        // MARK: C. 快照装配（纯函数；异步 @State 落账不在无窗容器内可观测）
        do {
            let screens = NSScreen.screens
            let assembled = SettingsView.inputScreens(
                from: screens,
                spacesByYabaiDisplay: [1: [ScreenLayoutMapper.InputSpace(yabaiIndex: 3, isVisible: true)]],
                yabaiIndex: { _ in 1 },
                displayID: { _ in 42 },
                mainDisplayID: 42
            )
            check("gridSettings: 快照装配数量与屏数一致（CI 至少一屏）",
                  assembled.count == screens.count)
            check("gridSettings: 快照字段与 yabai 分组命中",
                  assembled.allSatisfy {
                      $0.displayID == 42 && $0.isMain && $0.yabaiDisplayIndex == 1
                          && $0.spaces.map(\.yabaiIndex) == [3]
                  })
        }

        // MARK: D. 整段渲染：空态 / 断显横幅 / 切换反馈 / 参数区
        do {
            let empty = ImageRenderer(content: SettingsView().terminalGridSection)
            check("gridSettings: 空快照整段渲染出图", empty.nsImage != nil)

            let warned = SettingsView(
                gridTargetCode: GridTargetCode.display(displayID: 4_292_000_999).code,
                gridMinimapScreens: [
                    ScreenLayoutMapper.InputScreen(
                        displayID: 4_292_000_001,
                        name: "Synthetic Display",
                        cocoaFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                        isMain: true,
                        spaces: [ScreenLayoutMapper.InputSpace(yabaiIndex: 3, isVisible: true)],
                        yabaiDisplayIndex: 1)
                ],
                gridSpaceSwitchMessage: "已切换到 屏1-位次2"
            )
            let renderer = ImageRenderer(content: warned.terminalGridSection)
            check("gridSettings: 断显横幅+切换反馈整段渲染出图", renderer.nsImage != nil)
        }
    }
}
