import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerBStateSweepTests.swift — B300：B 态选靶扫尾批（豁免台账 B 态清单）。
// ①TerminalUsageTracker 合成 NSWorkspace 激活通知全链（真实观测域零真实激活——
//   通知直投 workspace 通知中心 + RunLoop 短片泵，B154 家法）；
// ②ShellRunner 幽灵可执行两入口 + 超时 terminate（/bin/sleep 30 + 1s 预算）；
// ③ClaudeSessionLocator 缺省 runner 参数路径（真实只读 fork，幽灵 tty/pid 确定性 nil）；
// ④ToggleEngine.displayCount（NSScreen 计数兜底）；
// ⑤SessionRestorePlanner.resolveSpace「工作区信息不可用」注记分支。

extension RunnerHarness {
    func runBStateSweepTests() {
        print("\n=== BStateSweep (B300) ===")

        // ===== A. ShellRunner 启动失败/超时 terminate =====
        do {
            check("bstate: ShellRunner 幽灵可执行（无 stdin）→ nil",
                  ShellRunner.run(executable: "/nonexistent/ghost-b300", arguments: ["x"]) == nil)
            check("bstate: ShellRunner 幽灵可执行（stdin 变体）→ nil",
                  ShellRunner.run(executable: "/nonexistent/ghost-b300", arguments: ["x"], stdin: "in") == nil)
            let start = Date()
            let timedOut = ShellRunner.run(executable: "/bin/sleep", arguments: ["30"], timeout: 1.0)
            let elapsed = Date().timeIntervalSince(start)
            check("bstate: 超时 terminate → nil", timedOut == nil)
            check("bstate: 超时预算生效（1s 预算 5s 内返回，不挂等 30s）", elapsed < 5.0)
            // stdin 变体超时（固定 commandTimeout 预算）→ terminate → nil
            check("bstate: stdin 变体超时 terminate → nil",
                  ShellRunner.run(executable: "/bin/sleep", arguments: ["30"], stdin: "x") == nil)
            // 退出后孙进程占住管道 >1s grace → drainGroup 超时分支（两入口）
            check("bstate: 孙进程占管道 grace 超时（无 stdin）→ nil",
                  ShellRunner.run(executable: "/bin/bash", arguments: ["-c", "/bin/sleep 30 &"], timeout: 5.0) == nil)
            check("bstate: 孙进程占管道 grace 超时（stdin 变体）→ nil",
                  ShellRunner.run(executable: "/bin/bash", arguments: ["-c", "/bin/sleep 30 &"], stdin: "x") == nil)
        }

        // ===== B. TerminalUsageTracker 合成激活通知（defaults 快照-还原 B84 家法）=====
        MainActor.assumeIsolated {
            let key = TerminalUsageTable.userDefaultsKey
            let saved = UserDefaults.standard.data(forKey: key)
            defer {
                if let saved { UserDefaults.standard.set(saved, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            UserDefaults.standard.removeObject(forKey: key)

            let tracker = TerminalUsageTracker(table: TerminalUsageTable())
            tracker.start()
            tracker.start() // 幂等：二次注册被守卫挡下
            let center = NSWorkspace.shared.notificationCenter
            func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }

            // 非终端 app 激活：真实运行中的非终端 bundleID → 守卫返回零记录
            let nonTerminal = NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier.map { !TerminalRegistry.isTerminalBundleID($0) } == true
            }
            if let app = nonTerminal {
                center.post(name: NSWorkspace.didActivateApplicationNotification,
                            object: nil,
                            userInfo: [NSWorkspace.applicationUserInfoKey: app])
                pump()
                check("bstate: 非终端激活零记录", tracker.table.entries.isEmpty)
            } else {
                check("bstate: 非终端激活零记录（环境无非终端 app，跳过）", true)
            }

            // 无 bundleID 激活（Runner 自身 CLI 无 bundle）→ bundleID=nil 守卫返回
            center.post(name: NSWorkspace.didActivateApplicationNotification,
                        object: nil,
                        userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
            pump()
            check("bstate: 无 bundleID 激活零记录", tracker.table.entries.isEmpty)

            // 真实终端激活：record+save 全链（计数 1 → defaults 落账可解码回读）
            let terminalApp = NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier.map { TerminalRegistry.isTerminalBundleID($0) } == true
            }
            if let term = terminalApp, let bundleID = term.bundleIdentifier {
                center.post(name: NSWorkspace.didActivateApplicationNotification,
                            object: nil,
                            userInfo: [NSWorkspace.applicationUserInfoKey: term])
                pump()
                check("bstate: 终端激活计数落账", tracker.table.entries[bundleID]?.count == 1)
                let persisted = TerminalUsageTable.decode(UserDefaults.standard.data(forKey: key) ?? Data())
                check("bstate: saveTable 落 defaults 且解码回读一致",
                      persisted?.entries[bundleID]?.count == 1)
            } else {
                check("bstate: 终端激活计数落账（环境无终端在跑，跳过）", true)
                check("bstate: saveTable 落 defaults 且解码回读一致（跳过）", true)
            }
        }

        // ===== C. ClaudeSessionLocator 缺省 runner 参数路径（真实只读 fork，幽灵输入 nil）=====
        do {
            check("bstate: claudePID 缺省 runner——幽灵 tty → nil",
                  ClaudeSessionLocator.claudePID(onTTY: "/dev/b300-nope") == nil)
            check("bstate: shellPID 缺省 runner——幽灵 tty → nil",
                  ClaudeSessionLocator.shellPID(onTTY: "/dev/b300-nope") == nil)
            check("bstate: workingDirectory 缺省 runner——幽灵 pid → nil",
                  ClaudeSessionLocator.workingDirectory(ofPID: 999_998) == nil)
            check("bstate: shellWorkingDirectory 缺省 runner——幽灵 tty → nil",
                  ClaudeSessionLocator.shellWorkingDirectory(onTTY: "/dev/b300-nope") == nil)
            check("bstate: locateSessionID 缺省 runner——幽灵 tty → nil",
                  ClaudeSessionLocator.locateSessionID(ttyPath: "/dev/b300-nope") == nil)
        }

        // ===== D. ToggleEngine.displayCount（NSScreen 计数兜底）=====
        do {
            let dir = NSTemporaryDirectory() + "vf-b300-tg-\(UUID().uuidString)"
            let engine = ToggleEngine(store: WindowStateStore(dbPath: dir + "/tg.db"))
            check("bstate: displayCount ≥ 1（NSScreen 计数兜底）", engine.displayCount >= 1)
        }

        // ===== E. Planner.resolveSpace「工作区信息不可用」注记分支 =====
        do {
            var notes: [String] = []
            let win = SessionWindowSnapshot(
                appBundleID: "com.apple.Terminal",
                frame: .zero, displayID: 1, yabaiDisplay: 1, yabaiSpace: 2,
                wasMinimized: false, panes: [])
            let resolution = SessionRestorePlanner.resolveSpace(
                window: win,
                targetDisplayID: 1,
                displayIDByYabaiIndex: [1: 1],
                existingSpaceIndices: [],
                visibleSpaceByYabaiDisplay: [:],
                notes: &notes)
            check("bstate: space 信息不可用 → yabaiSpace=nil + 注记",
                  resolution.yabaiSpace == nil
                  && notes.contains { $0.contains("工作区信息不可用") }
                  && notes.contains { $0.contains("已不存在") })
        }
    }
}
