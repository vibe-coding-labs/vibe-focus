// Tests/Runner/RunnerSpaceQueryYabaiTests.swift — SpaceController 查询/Yabai 通道实例直测（B239）。
// 锁定：markOperationError 三分支状态迁移（SA 错误翻转 canControlSpaces）、queryWindow
// 缓存命中双呼叫（真实 yabai 窗口 id，只读）、exactNSScreen 兜底（表外索引）。
// 留白注记：runYabai 的「可执行文件不存在」分支与各查询的失败日志分支需要让真实 yabai
// 失败（无注入缝、热路径原语不为覆盖率加缝），归 E2E 基建；AutoShow tick 观察机器
// 同 B219 先例留白（会真弹气泡面板，用户在用机）。

import AppKit
import Foundation
@testable import VibeFocusKit

extension RunnerHarness {
    func runSpaceQueryYabaiTests() {
        let sc = SpaceController.shared
        check("spaceQY: yabai 可用（前置）", waitForSpaceAvailability())

        // A. markOperationError(from:) 三分支状态迁移
        do {
            let savedMessage = sc.lastErrorMessage
            let savedCanControl = sc.canControlSpaces
            defer {
                sc.lastErrorMessage = savedMessage
                sc.canControlSpaces = savedCanControl
            }

            // SA 错误特征 → 专用文案 + 翻转 canControlSpaces（跨 Space 控制权熔断）
            sc.canControlSpaces = true
            sc.markOperationError(
                from: YabaiClient.YabaiResult(exitCode: 1, stdout: "", stderr: "error with the scripting-addition"),
                fallback: "fallback-not-used")
            check("spaceQY: SA 错误 → 专用文案 + canControlSpaces 熔断",
                  sc.canControlSpaces == false
                  && sc.lastErrorMessage?.contains("scripting-addition") == true)

            // 非 SA 错误 → stderr 格式化透传，不碰控制权
            sc.canControlSpaces = true
            sc.markOperationError(
                from: YabaiClient.YabaiResult(exitCode: 1, stdout: "", stderr: "some other failure"),
                fallback: "fallback-not-used")
            check("spaceQY: 非 SA 错误 → 格式化透传且控制权不动",
                  sc.lastErrorMessage == "some other failure" && sc.canControlSpaces == true)

            // 结果 nil（进程没起来）→ fallback 文案
            sc.markOperationError(from: nil, fallback: "vf-fallback-message")
            check("spaceQY: 结果 nil → fallback 文案", sc.lastErrorMessage == "vf-fallback-message")
        }

        // B. queryWindow 缓存命中：同一真实窗口 id 连查两次（ignoreCache=false），
        //    第二次命中 windowQueryCache（分支=缓存日志与直取返回），两次结果一致
        do {
            guard let visibleIndex = sc.querySpaces(ignoreCache: true)?
                .first(where: { $0.isVisible == true })?.index,
                let windows = sc.queryWindowsOnSpace(visibleIndex, operationID: "vf-qy"),
                let target = windows.first?.id.flatMap({ UInt32($0) }) else {
                check("spaceQY: 真实窗口 id 可得（前置）", false)
                return
            }
            let first = sc.queryWindow(windowID: target, ignoreCache: false)
            let second = sc.queryWindow(windowID: target, ignoreCache: false)
            check("spaceQY: queryWindow 双呼叫结果一致（第二次走缓存）",
                  first != nil && second?.id == first?.id && second?.space == first?.space)
        }

        // C. exactNSScreen 表外索引兜底：映射表查不到 → CoordinateKit 猜序版兜底（此处
        //    非法索引返回 nil），函数整体不崩溃不误映射
        check("spaceQY: exactNSScreen 表外索引 → nil 兜底",
              sc.exactNSScreen(forYabaiDisplayIndex: 9999) == nil)
    }
}
