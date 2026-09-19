// Tests/Runner/RunnerAXSelfHealTests.swift — AX 竞态自愈决策表 + 审计回读 + Doctor 副本盘点直测。
// 背景：同证书重装后 ~1s 内拉起的新进程约半数被 tccd 误判未授权且不自愈（2026-09-09/10
// 三次实证），AXSelfHeal.decide 决策表是自愈的唯一裁决点，本文件穷举锁死。

import Foundation
@testable import VibeFocusKit

extension RunnerHarness {
    func runAXSelfHealTests() {
        // ===== AXSelfHeal.decide：决策表穷举（v2：detached 看护自拉起，无 keepalive 依赖） =====
        check("heal: 已授权 → proceed（不看历史）",
              AXSelfHeal.decide(axTrusted: true, previousExitWasSelfHeal: false, isBundleInstall: true) == .proceedTrusted)
        check("heal: 已授权 + 上轮自愈 → proceed",
              AXSelfHeal.decide(axTrusted: true, previousExitWasSelfHeal: true, isBundleInstall: true) == .proceedTrusted)
        check("heal: 未授权 + 上轮非自愈 + bundle 安装 → relaunchSelf（用户态无 keepalive 也自愈）",
              AXSelfHeal.decide(axTrusted: false, previousExitWasSelfHeal: false, isBundleInstall: true) == .relaunchSelf)
        check("heal: 未授权 + 上轮自愈 → giveUp（防循环优先）",
              AXSelfHeal.decide(axTrusted: false, previousExitWasSelfHeal: true, isBundleInstall: true) == .giveUpPreviousHealFailed)
        check("heal: 未授权 + 非 bundle（裸二进制 dev）→ giveUp",
              AXSelfHeal.decide(axTrusted: false, previousExitWasSelfHeal: false, isBundleInstall: false) == .giveUpNoBundle)
        check("heal: 未授权 + 上轮自愈 + 非 bundle → giveUp 防循环优先",
              AXSelfHeal.decide(axTrusted: false, previousExitWasSelfHeal: true, isBundleInstall: false) == .giveUpPreviousHealFailed)
        check("heal: 防循环 reason 常量与审计写入侧一致",
              AXSelfHeal.exitReason == "ax-selfheal-relaunch")

        // ===== AXSelfHeal.relaunchScript：看护脚本构造（等死 → 退让 → open） =====
        let script = AXSelfHeal.relaunchScript(pid: 4242, bundlePath: "/Users/u/Applications/VibeFocus.app")
        check("watcher: 轮询本进程死亡（kill -0 pid）",
              script.contains("while kill -0 4242") && script.contains("sleep 0.2"))
        check("watcher: tccd 退让 3s 与 wrapper 同源",
              script.contains("sleep 3"))
        check("watcher: open 产物路径（带引号防空格）",
              script.contains("open '/Users/u/Applications/VibeFocus.app'"))

        // ===== AXSelfHeal.decideRuntimeFlip：运行期翻转决策表 =====
        check("runtime: true→false 且未自愈过 → healOnConfirm",
              AXSelfHeal.decideRuntimeFlip(nowTrusted: false, healAlreadyAttempted: false) == .healOnConfirm)
        check("runtime: true→false 但本进程已自愈过 → ignoreAlreadyHealed（防循环）",
              AXSelfHeal.decideRuntimeFlip(nowTrusted: false, healAlreadyAttempted: true) == .ignoreAlreadyHealed)
        check("runtime: false→true → ignoreFalseToTrue（授权恢复无需动作）",
              AXSelfHeal.decideRuntimeFlip(nowTrusted: true, healAlreadyAttempted: false) == .ignoreFalseToTrue)
        check("runtime: false→true 且已自愈过 → ignoreFalseToTrue",
              AXSelfHeal.decideRuntimeFlip(nowTrusted: true, healAlreadyAttempted: true) == .ignoreFalseToTrue)

        // ===== ExitJournal.lastExitReason(journalContents:)：上一个进程的退出原因 =====
        let lines = [
            ExitJournal.exitLine(pid: 11, at: "2026-09-10T00:00:00Z", reason: "sigterm-graceful", signal: nil, name: nil),
            ExitJournal.launchLine(pid: 12, at: "2026-09-10T00:00:01Z", exe: "/x/VibeFocus.app", exeMtimeEpoch: nil, exeInode: nil, bundleID: "com.openai.vibe-focus", version: "1.0", axTrusted: false),
            ExitJournal.exitLine(pid: 12, at: "2026-09-10T00:00:02Z", reason: AXSelfHeal.exitReason, signal: nil, name: nil),
            ExitJournal.launchLine(pid: 13, at: "2026-09-10T00:00:03Z", exe: "/x/VibeFocus.app", exeMtimeEpoch: nil, exeInode: nil, bundleID: "com.openai.vibe-focus", version: "1.0", axTrusted: false)
        ]
        let journal = lines.joined(separator: "\n")
        check("journal 回读: 取最后一条 exit 的 reason（自身 launch 不干扰）",
              ExitJournal.lastExitReason(journalContents: journal) == AXSelfHeal.exitReason)
        check("journal 回读: 无 exit 记录 → nil",
              ExitJournal.lastExitReason(journalContents: lines[3]) == nil)
        check("journal 回读: 空 journal → nil",
              ExitJournal.lastExitReason(journalContents: "") == nil)
        check("journal 回读: 坏行容错",
              ExitJournal.lastExitReason(journalContents: "not-json\n" + lines[0]) == "sigterm-graceful")

        // ===== Doctor.installInventoryLines：副本盘点排版与判定 =====
        let installed = Doctor.InstallCopyInfo(
            path: "/Users/u/Applications/VibeFocus.app", bundleID: "com.openai.vibe-focus",
            version: "1.2", signature: "VibeFocus Local Code Signing", isBackup: false)
        let backup = Doctor.InstallCopyInfo(
            path: "/Users/u/Applications/VibeFocus.app.backup-20260901", bundleID: "com.vibefocus.app",
            version: "0.9", signature: "adhoc", isBackup: true)
        let runningHere = Doctor.RunningInstanceInfo(pid: 100, bundleID: "com.openai.vibe-focus", path: installed.path)

        do {
            let out = Doctor.installInventoryLines(copies: [installed, backup], running: [runningHere])
            check("盘点: 单活体+单实例 → 无双版本判定",
                  out.contains { $0.contains("单份安装、单实例，无双版本") })
            check("盘点: 运行实例行带 pid",
                  out.contains { $0.contains("pid=100") && $0.contains("com.openai.vibe-focus") })
            check("盘点: 活体带证书签名标注",
                  out.contains { $0.contains(installed.path) && $0.contains("VibeFocus Local Code Signing") })
            check("盘点: 备份目录标注不拉起",
                  out.contains { $0.contains("备份目录") })
        }
        do {
            let second = Doctor.InstallCopyInfo(
                path: "/Applications/VibeFocus.app", bundleID: "com.openai.vibe-focus",
                version: "1.0", signature: "adhoc", isBackup: false)
            let out = Doctor.installInventoryLines(copies: [installed, second], running: [runningHere])
            check("盘点: 两份活体 → 双版本告警",
                  out.contains { $0.contains("疑似双版本") })
        }
        do {
            let other = Doctor.RunningInstanceInfo(pid: 101, bundleID: "com.openai.vibe-focus", path: "/tmp/other/VibeFocus.app")
            let out = Doctor.installInventoryLines(copies: [installed], running: [runningHere, other])
            check("盘点: 两个运行实例 → 多实例告警",
                  out.contains { $0.contains("多实例") })
        }
        do {
            let out = Doctor.installInventoryLines(copies: [], running: [])
            check("盘点: 空现场 → 无运行实例提示",
                  out.contains { $0.contains("当前无运行实例") })
        }
    }
}

// MARK: - B229：spawnRelaunchWatcher 真实派生（产物脚本语义已锁，此处锁 spawn 契约与零残留）

extension RunnerHarness {
    func runWatcherSpawnTests() {
        // 夹具：短命 bash（0.4s 自然死亡）→ 看护等死轮询立刻通过 → 3s 退让 → open 一个
        // **不存在**的 bundle 路径（open CLI 对缺失路径仅 stderr 报错退出，零窗口零副作用）。
        // 看护全程 ~3.6s 后自然退出——测试尾段用 pgrep 验证零残留（进程清理纪律）。
        let stub = Process()
        stub.executableURL = URL(fileURLWithPath: "/bin/bash")
        stub.arguments = ["-c", "sleep 0.4"]
        try? stub.run()
        let stubPID = Int32(stub.processIdentifier)
        stub.waitUntilExit()
        check("watcherSpawn: 前置——夹具已死亡", stubPID > 0 && !stub.isRunning)

        let spawned = AXSelfHeal.spawnRelaunchWatcher(pid: stubPID, bundlePath: "/nonexistent-vf-selfheal-\(stubPID).app")
        check("watcherSpawn: detached 看护派生成功（返回 true）", spawned)

        // 等看护走完「等死→退让→open 失败」全程（0.2 轮询 + 3 退让 + 余量）
        Thread.sleep(forTimeInterval: 4.2)
        let residue = ShellRunner.run(executable: "/usr/bin/pgrep", arguments: ["-f", "kill -0 \(stubPID)"])
        check("watcherSpawn: 看护执行完自然退出零残留（open 缺失路径无副作用）",
              residue?.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}
