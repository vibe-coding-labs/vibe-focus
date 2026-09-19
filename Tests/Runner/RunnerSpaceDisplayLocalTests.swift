import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerSpaceDisplayLocalTests.swift — 覆盖率批次 21（B252）：
// displayLocalSpaceIndex（spaces 注入，零 yabai fork）+ YabaiClient 查找链直测。
//
// displayLocalSpaceIndex 带 spaces 参数时直接走纯函数 resolveDisplayLocalSpaceIndex
// （nil 输入守卫也在本地）；不带 spaces 才 fork querySpaces——本批一律注入 spaces。
// findViaUserShell/findViaBashWhich 是只读 shell fork（which yabai），无系统状态变更；
// 本机 yabai 已装 → 非 nil 且为绝对路径，无 yabai 环境合法 nil，断言只锁路径形态。

extension RunnerHarness {
    func runSpaceDisplayLocalTests() {
        let controller = SpaceController.shared
        let spaces = [
            YabaiSpaceInfo(id: 1, index: 1, display: 1, isVisible: true),
            YabaiSpaceInfo(id: 2, index: 2, display: 1, isVisible: false),
            YabaiSpaceInfo(id: 3, index: 5, display: 2, isVisible: true),
        ]
        // 全局 index 5 在 display 2 上是本地第 1 个工作区。
        check("spaceLocal: 全局 5@display2 → 本地 1",
              controller.displayLocalSpaceIndex(forGlobalSpaceIndex: 5, displayIndex: 2, spaces: spaces) == 1)
        // 全局 index 2 在 display 1 上是本地第 2 个。
        check("spaceLocal: 全局 2@display1 → 本地 2",
              controller.displayLocalSpaceIndex(forGlobalSpaceIndex: 2, displayIndex: 1, spaces: spaces) == 2)
        // 不属于该 display 的全局 index → nil。
        check("spaceLocal: 跨 display 不命中 → nil",
              controller.displayLocalSpaceIndex(forGlobalSpaceIndex: 5, displayIndex: 1, spaces: spaces) == nil)
        // nil 输入守卫。
        check("spaceLocal: nil 全局索引 → nil",
              controller.displayLocalSpaceIndex(forGlobalSpaceIndex: nil, displayIndex: 1, spaces: spaces) == nil
              && controller.displayLocalSpaceIndex(forGlobalSpaceIndex: 5, displayIndex: nil, spaces: spaces) == nil)

        // MARK: YabaiClient 查找链（只读 shell fork；断言只锁路径形态）
        if let viaShell = YabaiClient.findViaUserShell() {
            check("yabaiFind: 用户 shell 查找返回绝对路径",
                  viaShell.hasPrefix("/") && viaShell.hasSuffix("yabai"))
        } else {
            check("yabaiFind: 用户 shell 查找无 yabai 合法 nil", true)
        }
        if let viaWhich = YabaiClient.findViaBashWhich() {
            check("yabaiFind: bash which 返回绝对路径",
                  viaWhich.hasPrefix("/") && viaWhich.hasSuffix("yabai"))
        } else {
            check("yabaiFind: bash which 无 yabai 合法 nil", true)
        }
    }
}
