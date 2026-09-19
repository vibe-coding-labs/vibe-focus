// Tests/Runner/RunnerSpoolDrainLifecycleTests.swift — RemoteSpoolDrainer 全生命周期封闭直测（B243）。
// processRunner 注入缝（B232）+ RemoteSpoolHosts/偏好全走 Runner 自有 defaults 域
//（save/restore）——零真实 ssh、零真实远程事件。锁定：applyPreferences 关闭态无轮询、
// drain 拉取→解析→预算回灌→deferred 顺延、tick 积压优先、超时 mux-reset、
// exit 255 不可达、空拉取。finishDrain 的回灌走 ClaudeHookServer.shared.handleHookRequest
// 未知 session 只读早退（B154 先例）。

import AppKit
import Foundation
@testable import VibeFocusKit

extension RunnerHarness {
    func runSpoolDrainLifecycleTests() {
        let drainer = RemoteSpoolDrainer.shared
        let savedEnabled = ClaudeHookPreferences.isEnabled
        let savedToken = ClaudeHookPreferences.authToken
        let savedHosts = RemoteSpoolHosts.loadHosts()
        let savedRunner = drainer.processRunner
        let savedAutoFocus = ClaudeHookPreferences.autoFocusOnSessionEnd
        defer {
            RemoteSpoolHosts.saveHosts([])
            ClaudeHookPreferences.isEnabled = false
            drainer.applyPreferences()   // 收尾：确保轮询定时器停掉（不留 2s 周期 ssh 隐患）
            drainer.processRunner = savedRunner
            drainer.pendingReplay = []
            drainer.inFlight = []
            RemoteSpoolHosts.saveHosts(savedHosts)
            ClaudeHookPreferences.authToken = savedToken
            ClaudeHookPreferences.autoFocusOnSessionEnd = savedAutoFocus
            ClaudeHookPreferences.isEnabled = savedEnabled
        }
        ClaudeHookPreferences.autoFocusOnSessionEnd = true  // SessionEnd 无绑定 → 只读早退（B154 先例）
        final class Counter: @unchecked Sendable { var value = 0; func inc() { value += 1 } }
        let cannedEvent: @Sendable (String) -> String = { sid in
            "{\"event\":\"SessionEnd\",\"session_id\":\"\(sid)\"}"
        }

        // A. 关闭态：applyPreferences 不建轮询定时器——drainNow 只跑手动一轮，
        //    泵过 2.5s（> pollInterval 2s）再无第二次调用（无定时器行为学证据）
        do {
            ClaudeHookPreferences.isEnabled = false
            RemoteSpoolHosts.saveHosts(["vf-fake-1"])
            let calls = Counter()
            drainer.processRunner = { _, _, _ in calls.inc(); return (exitCode: 0, stdout: "", stderr: "") }
            drainer.pendingReplay = []
            drainer.drainNow()
            RunLoop.main.run(until: Date().addingTimeInterval(2.5))
            check("spoolLC: 关闭态无轮询定时器（手动一轮后零再触发）", calls.value == 1)
        }

        // B. 开启态全生命周期：假 runner 返回 6 条事件（预算 4 + 顺延 2）
        do {
            ClaudeHookPreferences.isEnabled = true
            ClaudeHookPreferences.authToken = "vf-spool-token"
            let drainCalls = Counter()
            drainer.pendingReplay = []
            drainer.inFlight = []
            drainer.processRunner = { executable, arguments, _ in
                if executable == "/usr/bin/ssh", arguments.contains(where: { $0.contains("spool") }) {
                    drainCalls.inc()
                    let lines = (1...6).map { cannedEvent("vf-spool-\($0)") }
                    return (exitCode: 0, stdout: lines.joined(separator: "\n"), stderr: "")
                }
                return (exitCode: 0, stdout: "", stderr: "")
            }
            RemoteSpoolHosts.saveHosts(["vf-fake-1"])
            drainer.applyPreferences()
            drainer.drainNow()
            let deadline = Date().addingTimeInterval(5.0)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                if drainer.statuses["vf-fake-1"]?.lastEventCount == 6 { break }
            }
            check("spoolLC: 拉取 6 条事件解析入账", drainer.statuses["vf-fake-1"]?.lastEventCount == 6)
            check("spoolLC: exit 0 通路无错误置位", drainer.statuses["vf-fake-1"]?.lastError == nil)
            check("spoolLC: 超预算 2 条顺延 pendingReplay", drainer.pendingReplay.count == 2)
            check("spoolLC: drain 走假 runner（真实 ssh 零发起）", drainCalls.value >= 1)

            // C. tick 积压优先：pendingReplay 非空 → 只消化积压、零新 drain。
            //    摘掉主机防 2s 轮询定时器插枪（tick 的主机循环空转无害）。
            RemoteSpoolHosts.saveHosts([])
            drainCalls.value = 0
            drainer.tick()
            let replayDeadline = Date().addingTimeInterval(3.0)
            while Date() < replayDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                if drainer.pendingReplay.isEmpty { break }
            }
            check("spoolLC: tick 积压优先消化（回灌清空且零新 drain）",
                  drainer.pendingReplay.isEmpty && drainCalls.value == 0)
        }

        // D. 超时/启动失败：runner 返回 nil → 强制 mux reset + lastError 落账
        do {
            drainer.pendingReplay = []
            drainer.inFlight = []
            let sawDrain = Counter()
            let sawMuxReset = Counter()
            drainer.processRunner = { _, arguments, _ in
                if arguments.contains(where: { $0.contains("spool") }) { sawDrain.inc(); return nil }
                sawMuxReset.inc()
                return (exitCode: 0, stdout: "", stderr: "")
            }
            drainer.startDrain(host: "vf-fake-2")
            let muxDeadline = Date().addingTimeInterval(3.0)
            while Date() < muxDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                if sawMuxReset.value >= 1, drainer.inFlight.isEmpty { break }
            }
            check("spoolLC: drain nil → mux reset 触发 + 状态报「超时/启动失败」",
                  sawDrain.value >= 1 && sawMuxReset.value >= 1
                  && drainer.statuses["vf-fake-2"]?.lastError == "ssh 超时或启动失败")
        }

        // E. exit 255 不可达：stderr 落 lastError
        do {
            drainer.processRunner = { _, _, _ in
                (exitCode: 255, stdout: "", stderr: "ssh: connect to host vf-fake-3 port 22 failed")
            }
            drainer.startDrain(host: "vf-fake-3")
            let unDeadline = Date().addingTimeInterval(3.0)
            while Date() < unDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                if drainer.statuses["vf-fake-3"]?.lastError != nil { break }
            }
            check("spoolLC: exit 255 → stderr 落 lastError（不可达如实记账）",
                  drainer.statuses["vf-fake-3"]?.lastError?.contains("connect to host") == true)
        }

        // F. 空拉取：exit 0 无事件 → lastEventCount 0、无错误
        do {
            drainer.processRunner = { _, _, _ in (exitCode: 0, stdout: "", stderr: "") }
            drainer.startDrain(host: "vf-fake-4")
            let emptyDeadline = Date().addingTimeInterval(3.0)
            while Date() < emptyDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                if drainer.statuses["vf-fake-4"]?.lastDrainAt != nil { break }
            }
            check("spoolLC: 空拉取 → 计数 0 且无错误", drainer.statuses["vf-fake-4"]?.lastEventCount == 0)
        }
    }
}
