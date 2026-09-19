// Tests/Runner/RunnerReadOnlySweepTests.swift
// B231 覆盖堆叠·只读清扫域：captureFocusedWindowIdentity（前台 AX 只读捕获——
// 不改焦点不激活任何 app）/ findClaudeCodeWindow（CGWindowList 只读扫描+策略匹配）/
// SettingsView.refreshInstallations（mdfind 只读扫描，@State 改的是结构体副本）。

import AppKit
import Foundation
@testable import VibeFocusKit

extension RunnerHarness {

    func runReadOnlySweepTests() {
        print("\n=== ReadOnlySweep (B231) ===")
        let wm = WindowManager.shared

        // captureFocusedWindowIdentity：读用户当前前台 app 的 AX 焦点窗——
        // 只读（AX 读不改焦点），结果可 nil 可有（前台非终端/无窗时 nil）
        let captured = wm.captureFocusedWindowIdentity()
        check("sweep: 前台身份捕获不崩溃（可 nil）", true)
        if let c = captured {
            check("sweep: 捕获身份 windowID 非零", c.windowID != 0)
        }

        // findClaudeCodeWindow：全窗口扫描+三级策略（nil cwd = 无项目名约束）——只读
        let foundNilCwd = wm.findClaudeCodeWindow(cwd: nil)
        check("sweep: Claude 窗扫描（nil cwd）不崩溃", true)
        _ = foundNilCwd
        let foundWithCwd = wm.findClaudeCodeWindow(cwd: "/tmp/b231-demo-project")
        check("sweep: Claude 窗扫描（带 cwd）不崩溃", true)
        _ = foundWithCwd

        // refreshInstallations：mdfind 只读扫安装副本；@State 写在结构体副本上
        let settingsView = SettingsView()
        settingsView.refreshInstallations()
        // 等后台 mdfind 完成后 isChecking 复位（结构体副本状态，纯观测）
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, settingsView.isCheckingInstallations {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        check("sweep: 安装扫描完成复位 isChecking", settingsView.isCheckingInstallations == false)
    }
}

// MARK: - B250 追加：makeIdentity 提缝直测（private→internal 仅可见性）

extension RunnerHarness {
    func runFindingMakeIdentityTests() {
        let wm = WindowManager.shared
        // 显式 bundleIdentifier 路径：五字段透传，不触 LaunchServices。
        let explicit = wm.makeIdentity(from: .init(
            windowID: 42, pid: getpid(), appName: "Terminal",
            bundleIdentifier: "com.apple.Terminal", title: "示例窗"))
        check("finding: makeIdentity 显式 bundleID 五字段透传",
              explicit.windowID == 42 && explicit.pid == getpid()
              && explicit.bundleIdentifier == "com.apple.Terminal"
              && explicit.appName == "Terminal" && explicit.title == "示例窗")
        // bundleIdentifier nil → NSRunningApplication(pid) LaunchServices 查询兜底；
        // 幽灵 pid 查询返回 nil → identity.bundleIdentifier 保持 nil。
        let ghost = wm.makeIdentity(from: .init(
            windowID: 43, pid: 999_999, appName: "ghost",
            bundleIdentifier: nil, title: "g"))
        check("finding: makeIdentity 幽灵 pid 兜底查询得 nil",
              ghost.bundleIdentifier == nil && ghost.windowID == 43)
    }
}
