import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerAutomationGuardTests.swift — B229：B 档 Controller 族第一批
// （提纯决策已有纯函数层，本批锁其 IO 门卫真身）。全只读：进程表扫描/LS 查询/
// 隔离 DB 偏好，不建窗不拉终端不投递。
// ①TerminalGridController.automationInstanceRefusal 守卫三态（真实 Terminal 实例/
//   未安装 allowNotRunning 放行/未安装拒绝链——KERN_PROCARGS2 进程扫描真身贯通）；
// ②SessionRestoreController.runAutoRestoreIfEnabled 双早退门（开关关/开但空快照库，
//   隔离 store 注入缝，永不落到真建窗 Task 分支）。

extension RunnerHarness {
    func runAutomationGuardTests() {
        // ===== TerminalGridController 自动化实例守卫 =====
        do {
            let grid = TerminalGridController.shared

            // 真实 Terminal.app（正在跑）→ 实例表非空且路径含 Terminal；守卫放行 nil
            let instances = TerminalGridController.terminalInstances(bundleID: "com.apple.Terminal")
            check("autoGuard: 真实 Terminal 进程扫描命中（KERN_PROCARGS2 通道）",
                  !instances.isEmpty && instances.allSatisfy { $0.pid > 1 })
            check("autoGuard: 守卫对运行中 Terminal 放行",
                  grid.automationInstanceRefusal(appBundleID: "com.apple.Terminal") == nil)

            // 未安装 bundle：allowNotRunning=false → 拒绝链消息；true → 「未安装」明确拒绝
            let bogus = "com.vibefocus.nonterminal.zz"
            let refusePlain = grid.automationInstanceRefusal(appBundleID: bogus)
            check("autoGuard: 未安装 + 不放行 → 拒绝非 nil",
                  refusePlain != nil && !refusePlain!.isEmpty)
            let refuseAllow = grid.automationInstanceRefusal(appBundleID: bogus, allowNotRunning: true)
            check("autoGuard: 未安装 + allowNotRunning → 仍拒绝（未安装≠未运行）",
                  refuseAllow?.contains("未安装") == true)

            // 已安装但未运行的已知终端（Terminal 编译环境常不在跑的可选项不可保证，
            // 改用「运行中→放行」已上锁；此分支只锁消息路由不含崩溃）
            check("autoGuard: 已知终端名映射命中（消息用友好名）",
                  TerminalSelectionResolver.knownNames["com.apple.Terminal"] != nil)
        }

        // ===== SessionRestoreController 自动恢复门（隔离 store，双早退） =====
        do {
            let dir = "/tmp/vibefocus-sarc-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let controller = SessionRestoreController(store: SessionRestoreStore(
                store: WindowStateStore(dbPath: dir + "/sarc.db")))

            // 门 1：开关关（默认）→ 立即返回，hasRunAutoRestoreThisLaunch 不置位
            let savedSwitch = UserDefaults.standard.object(forKey: TerminalGridPreferences.autoRestoreEnabledKey)
            defer {
                if let savedSwitch { UserDefaults.standard.set(savedSwitch, forKey: TerminalGridPreferences.autoRestoreEnabledKey) }
                else { UserDefaults.standard.removeObject(forKey: TerminalGridPreferences.autoRestoreEnabledKey) }
            }
            UserDefaults.standard.set(false, forKey: TerminalGridPreferences.autoRestoreEnabledKey)
            controller.runAutoRestoreIfEnabled()
            check("autoGuard: 开关关 → 早退且不置本轮已跑旗标",
                  controller.hasRunAutoRestoreThisLaunch == false)

            // 门 2：开关开 + 空快照库 → no snapshot 早退（不 spawn 建窗 Task）
            UserDefaults.standard.set(true, forKey: TerminalGridPreferences.autoRestoreEnabledKey)
            controller.runAutoRestoreIfEnabled()
            check("autoGuard: 开+空库 → no snapshot 早退",
                  controller.hasRunAutoRestoreThisLaunch == true)
            check("autoGuard: 空库 latest 为 nil（早退数据前提）",
                  controller.latestSnapshotID() == nil && controller.snapshotsForRefresh().isEmpty)
        }

        // ===== SessionRestoreController.bundleIdentifier(ofPID:) 只读解析 =====
        do {
            let controller = SessionRestoreController(store: SessionRestoreStore(
                store: WindowStateStore(dbPath: "/tmp/vibefocus-sarc-bid.db")))
            let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
            if let dockPID {
                check("autoGuard: pid→bundleID 解析 Dock 命中",
                      controller.bundleIdentifier(ofPID: dockPID) == "com.apple.dock")
            }
            check("autoGuard: 幽灵 pid → nil",
                  controller.bundleIdentifier(ofPID: 999_999_99) == nil)
        }
    }
}
