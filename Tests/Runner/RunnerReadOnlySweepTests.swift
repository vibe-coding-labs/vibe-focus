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

// MARK: - B299 追加：matchedWindowIdentity 两策略日志分支注入直测

extension RunnerHarness {
    func runFindingMatchedIdentityTests() {
        print("\n=== FindingMatchedIdentity (B299) ===")
        // 真实环境命中需 host-app 窗口标题恰含 cwd 项目名（不可控）；B299 提纯后
        // 注入候选表确定性打穿策略 1/2 两日志分支 + 身份构造编排。
        do {
            let wm = WindowManager()
            let host = WindowManager.WindowCandidate(
                windowID: 901, pid: 100_001, appName: "iTerm2",
                bundleIdentifier: "com.googlecode.iterm2", title: "vibe-focus-cov271 — zsh")
            let nonHost = WindowManager.WindowCandidate(
                windowID: 902, pid: 100_002, appName: "Safari",
                bundleIdentifier: "com.apple.Safari", title: "vibe-focus-cov271 in tab")
            let claudeTitle = WindowManager.WindowCandidate(
                windowID: 903, pid: 100_001, appName: "iTerm2",
                bundleIdentifier: nil, title: "Claude Code — session")
            let isHost = { (c: WindowManager.WindowCandidate) in c.appName == "iTerm2" }

            // 策略 1：host-app + 标题含 cwd 项目名（非 host 同标题窗不参战）
            let m1 = wm.matchedWindowIdentity(
                [nonHost, host], projectName: "vibe-focus-cov271", isHostApp: isHost,
                cgListMs: 3, startedAt: Date())
            check("finding: 策略1 hostApp+cwd 命中并构造身份",
                  m1?.windowID == 901 && m1?.appName == "iTerm2"
                  && m1?.title == "vibe-focus-cov271 — zsh")
            // projectName nil → 策略 1 不启用；标题无 "claude code" → 整体 nil（调用方回退前台）
            let noMatch = wm.matchedWindowIdentity(
                [host], projectName: nil, isHostApp: isHost, cgListMs: 1, startedAt: Date())
            check("finding: 无项目名且无 claude code 标题 → nil", noMatch == nil)
            // 策略 2：projectName nil 时 host-app 标题含 "claude code" 命中
            let m2 = wm.matchedWindowIdentity(
                [host, claudeTitle], projectName: nil, isHostApp: isHost,
                cgListMs: 2, startedAt: Date())
            check("finding: 策略2 hostApp+claudeCode 命中", m2?.windowID == 903)
            // 策略 1 优先于策略 2：projectName 与 claude code 标题同时可得时取策略 1
            let m3 = wm.matchedWindowIdentity(
                [claudeTitle, host], projectName: "vibe-focus-cov271", isHostApp: isHost,
                cgListMs: 2, startedAt: Date())
            check("finding: 策略1 优先于策略2", m3?.windowID == 901)
        }
    }
}
