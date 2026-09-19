import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerRemoteResolvedSweepTests.swift — B238 远程绑定 resolved 通道扫尾
// 靶：HookEventHandler.resolveRemoteBinding 的 resolved 成功分支（基线一直缺口的
// 主成功路）。选窗策略=Dock 进程的常驻窗口（进程永活、窗口最稳定），重挑 3 轮抗
// 快照竞态；绑定写 Runner 自有 defaults 域并快照还原，绝不触碰真机绑定表。
// （ShortcutRecorderButton.init?(coder:) 域留白：坏数据解码触发 NSException abort，
//  exit 134 实测——异常不抛只炸，测试通道不可达，需生产侧改可抛解码才有意义。）

extension RunnerHarness {
    func runRemoteResolvedSweepTests() {
        // 找 Dock 的在屏窗口（超稳候选；重挑 3 轮）
        let dockPID = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        var dockWindowID: UInt32?
        if let dockPID {
            for _ in 0..<3 {
                if let entry = cgWindowListAll().first(where: {
                    $0.ownerPID == dockPID && $0.isOnScreen && $0.windowID != 0 }) {
                    dockWindowID = entry.windowID
                    break
                }
            }
        }
        guard let windowID = dockWindowID else {
            check("remoteResolved A0: 未找到 Dock 窗口（环境异常跳过）", true)
            return
        }

        // 绑定写入 Runner defaults 域（快照/还原防污染）
        let d = UserDefaults.standard
        let savedBindings = d.object(forKey: "claudeHookRemoteBindings")
        defer {
            if let savedBindings { d.set(savedBindings, forKey: "claudeHookRemoteBindings") }
            else { d.removeObject(forKey: "claudeHookRemoteBindings") }
        }
        let payload = try? JSONSerialization.data(
            withJSONObject: ["ut100-dock": windowID], options: [.sortedKeys])
        d.set(String(data: payload!, encoding: .utf8)!, forKey: "claudeHookRemoteBindings")

        // label 命中 + findWindowByCGWindowID 命中 → resolved 身份
        let identity = HookEventHandler.shared.resolveRemoteBinding(
            label: "ut100-dock", sessionID: "s-ut100")
        check("remoteResolved A1: label→窗 resolved 返回绑定窗身份",
              identity?.windowID == windowID && identity?.pid == dockPID)

        // label 未命中 → nil（守卫分支伴随确认）
        check("remoteResolved A2: 未注册 label → nil",
              HookEventHandler.shared.resolveRemoteBinding(
                label: "ut100-absent-label", sessionID: "s-ut100") == nil)

    }
}
