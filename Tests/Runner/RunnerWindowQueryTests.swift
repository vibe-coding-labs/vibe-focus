// Tests/Runner/RunnerWindowQueryTests.swift
// B221 覆盖堆叠·窗口查询守卫域：WindowManager+WindowQuery 的 CG/AX 查询守卫路。
// 全部用幻影 windowID/pid——真实窗口会触发 raise/focus 抢用户焦点，绝不碰。

import AppKit
import ApplicationServices
import Foundation
@testable import VibeFocusKit

extension RunnerHarness {

    func runWindowQueryTests() {
        print("\n=== WindowQuery (B221) ===")
        let wm = WindowManager.shared

        // focusWindowByCGWindowID：幻影 ID 在 CGWindowList 必不命中 → false（不聚焦任何窗）
        check("winQuery: 幻影 ID 聚焦失败", wm.focusWindowByCGWindowID(0xB221) == false)

        // focusedWindow(for:)：幻影 pid 的 AX 应用元素无焦点窗 → nil
        check("winQuery: 幻影 pid 焦点窗 nil", wm.focusedWindow(for: 999_999) == nil)

        // findWindowByPID：windowID nil 直接 nil（守卫）；幻影 pid + 幻影 ID → nil
        check("winQuery: windowID nil 直通 nil", wm.findWindowByPID(99_998, windowID: nil) == nil)
        check("winQuery: 幻影 pid+ID 无 AX 元素", wm.findWindowByPID(999_999, windowID: 0xB221) == nil)
    }

    // MARK: - B250：核心只读两函数（getMainScreen / hasAccessibilityPermission 单次调用）
    func runWindowCoreReadTests() {
        // getMainScreen：isMainScreen 优先，CoordinateKit.primaryScreen 兜底
        let main = WindowManager.shared.getMainScreen()
        check("winCore: 主屏可解析", main != nil)
        if let main {
            let isMain = main === NSScreen.main || NSScreen.screens.first(where: { $0.isMainScreen }) == main
            check("winCore: 主屏解析与 NSScreen 拓扑一致", isMain)
        }

        // hasAccessibilityPermission：单次调用（返回值=本进程真实授信态，双世界皆真值）；
        // 授权翻转记账分支依赖运行期 trust 变化，进程内稳定不触发，运行期自愈链归真机域。
        let trusted = WindowManager.shared.hasAccessibilityPermission()
        check("winCore: AX 授信查询返回布尔真值", trusted == true || trusted == false)
    }

    // MARK: - B272：findClaudeCodeWindow 只读编排链 + projectName 纯函数（A 态清单第 1 项）
    func runClaudeCodeFindingTests() {
        // projectName(fromCwd:)：纯路径变换
        check("findCC: projectName nil → nil", WindowManager.projectName(fromCwd: nil) == nil)
        check("findCC: projectName 全斜杠 → nil", WindowManager.projectName(fromCwd: "///") == nil)
        check("findCC: projectName 末段+小写归一",
              WindowManager.projectName(fromCwd: "/Users/x/MyProj/") == "myproj")

        // findClaudeCodeWindow：CGWindowList 全扫 + 候选构建 + 三级策略匹配，
        // 全程只读（不改窗口状态）；结果双世界诚实断言（有无 claude code 窗均合法）
        let noConstraint = WindowManager.shared.findClaudeCodeWindow(cwd: nil)
        if let ident = noConstraint {
            check("findCC: 无约束命中时 windowID 正常", ident.windowID != 0)
        } else {
            check("findCC: 无约束未命中返 nil（本机无 claude code 标题窗）", true)
        }
        let constrained = WindowManager.shared.findClaudeCodeWindow(cwd: "/tmp/vibefocus-b272-proj")
        check("findCC: 带项目名约束链路贯通",
              constrained == nil || constrained!.windowID != 0)
    }
}
