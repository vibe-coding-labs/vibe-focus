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

// MARK: - B248：setWindowFloat 编排层 skip 路径（knownWindowInfo 注入，零 yabai fork）

extension RunnerHarness {
    func runSpaceFloatSkipTests() {
        let sc = SpaceController.shared
        // knownWindowInfo 注入后 @autoclosure 不求值 → 全程零 yabai 调用；
        // enabled/disabled 两世界结果同为 skipNoOp，断言在两种环境都成立。
        let floatingInfo = YabaiWindowInfo(id: 1, pid: 1, app: "Terminal", title: "t", space: 1, display: 1,
                                           frame: nil, isFloatingRaw: true, hasAXReferenceRaw: true)
        check("floatSkip: 已 float 注入短路 skipNoOp",
              sc.setWindowFloat(1, operationID: "b248-floatskip", knownWindowInfo: floatingInfo) == .skippedNoOp)
        let unmanagedInfo = YabaiWindowInfo(id: 1, pid: 1, app: "Terminal", title: "t", space: 1, display: 1,
                                            frame: nil, isFloatingRaw: false, hasAXReferenceRaw: false)
        check("floatSkip: 无 AX 引用注入 skipNoOp",
              sc.setWindowFloat(1, operationID: "b248-floatskip", knownWindowInfo: unmanagedInfo) == .skippedNoOp)
        if sc.isEnabled {
            // enabled 世界：幽灵窗 id 走真实 queryWindow 只读查询（yabai 无此窗返 nil）→ query_nil 跳过
            check("floatSkip: enabled 态幽灵窗 query_nil skipNoOp",
                  sc.setWindowFloat(999_999, operationID: "b248-floatskip", knownWindowInfo: nil) == .skippedNoOp)
        } else {
            // disabled 世界：决策序最先短路，连查询 fork 都不发起
            check("floatSkip: disabled 态幽灵窗 skipNoOp",
                  sc.setWindowFloat(999_999, operationID: "b248-floatskip", knownWindowInfo: nil) == .skippedNoOp)
        }
    }
}

// MARK: - B250：yabai 路径发现链直测（private→internal 提缝，默认行为零变化）
//
// PATH/候选路径命中时 findViaUserShell/findViaBashWhich 两条 fallback 不可达；
// 提缝后直测。两者都 fork 登录 shell（~1s，只读）。断言双世界诚实：
// 有 yabai 的机器返回存在的路径，无 yabai 的环境返回 nil。

extension RunnerHarness {
    func runYabaiPathDiscoveryTests() {
        // A. 用户 shell 发现链：env bash -l 'echo $SHELL' → $SHELL -l 'which yabai'
        let viaShell = YabaiClient.findViaUserShell()
        check("yabaiPath: 用户 shell 发现链 nil 或存在路径",
              viaShell == nil || FileManager.default.fileExists(atPath: viaShell!))

        // B. bash -l which 兜底链
        let viaBash = YabaiClient.findViaBashWhich()
        check("yabaiPath: bash which 兜底链 nil 或存在路径",
              viaBash == nil || FileManager.default.fileExists(atPath: viaBash!))

        // C. 双链一致性：同一台机器两条链要么都失败要么都指向存在的 yabai
        // （路径可能不同——/opt/homebrew vs /usr/local，但 fileExists 语义一致）
        check("yabaiPath: 双链成败一致",
              (viaShell != nil) == (viaBash != nil))
    }
}
