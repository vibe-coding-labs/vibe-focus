// Tests/Runner/RunnerSpoolDrainSeamTests.swift
// B232 覆盖堆叠·SpoolDrainer 提纯注入缝：processRunner 假 runner 零 ssh fork 直驱
// drain 生命周期（startDrain/finishDrain/tick/replayDeferred，B232 提纯转 internal）。
// 假 runner 记录调用；回灌走 ClaudeHookServer.shared.handleHookRequest 内存计数
// （坏 JSON 行→诚实 4xx，无窗口作业无 DB 写）。偏好全走 Runner 自有 defaults 域。

import Foundation
@testable import VibeFocusKit

extension RunnerHarness {

    func runSpoolDrainSeamTests() {
        print("\n=== SpoolDrainSeam (B232) ===")
        let drainer = RemoteSpoolDrainer.shared

        // 状态隔离：偏好与共享状态先存后还原
        let savedEnabled = ClaudeHookPreferences.isEnabled
        let savedHosts = UserDefaults.standard.string(forKey: RemoteSpoolHosts.hostsKey)
        defer {
            ClaudeHookPreferences.isEnabled = savedEnabled
            if let h = savedHosts { UserDefaults.standard.set(h, forKey: RemoteSpoolHosts.hostsKey) }
            else { UserDefaults.standard.removeObject(forKey: RemoteSpoolHosts.hostsKey) }
            drainer.inFlight = []
            drainer.pendingReplay = []
        }
        ClaudeHookPreferences.isEnabled = false

        func pump(_ seconds: TimeInterval = 5) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }
        // async 直调桥接：Task 派发 + 主 RunLoop 短片泵（B154 家法）
        func runDrainAsync(_ block: @escaping @Sendable () async -> Void) {
            Task { @MainActor in await block() }
            pump(1.0)
        }

        // 1) finishDrain 直驱：result nil → 超时/启动失败错误
        runDrainAsync { await drainer.finishDrain(host: "b232-nil", result: nil) }
        check("spoolSeam: nil 结果记超时错误",
              drainer.statuses["b232-nil"]?.lastError == "ssh 超时或启动失败"
              && drainer.statuses["b232-nil"]?.lastDrainAt != nil)

        // 2) finishDrain：exit 255 → stderr 进 lastError
        runDrainAsync { await drainer.finishDrain(host: "b232-255", result: (255, "", "Connection refused")) }
        check("spoolSeam: exit255 stderr 进 lastError",
              drainer.statuses["b232-255"]?.lastError == "Connection refused")

        // 3) finishDrain：正常 0 事件 → 清错误零回灌
        runDrainAsync { await drainer.finishDrain(host: "b232-empty", result: (0, "", "")) }
        check("spoolSeam: 空输出零事件无错误",
              drainer.statuses["b232-empty"]?.lastError == nil
              && drainer.statuses["b232-empty"]?.lastEventCount == 0)

        // 4) finishDrain：有事件但 hook 关 → 事件丢弃（lastEventCount 已记账）
        runDrainAsync { await drainer.finishDrain(host: "b232-dropped", result: (0, "{\"event\":\"Stop\"}\n", "")) }
        check("spoolSeam: hook 关时事件丢弃",
              drainer.statuses["b232-dropped"]?.lastEventCount == 1
              && drainer.pendingReplay.isEmpty)

        // 5) startDrain 注入缝：假 runner 记录调用并返回固定结果；
        //    nil 结果分支顺带触发 mux reset 第二次调用
        final class CallRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var calls: [(String, [String])] = []
            var result: (exitCode: Int32, stdout: String, stderr: String)? = (0, "", "")
            func record(_ exe: String, _ args: [String]) {
                lock.lock(); calls.append((exe, args)); lock.unlock()
            }
            func snapshot() -> [(String, [String])] {
                lock.lock(); defer { lock.unlock() }; return calls
            }
        }
        let recorder = CallRecorder()
        recorder.result = nil   // 触发 mux reset 分支
        drainer.processRunner = { exe, args, _ in
            recorder.record(exe, args)
            return recorder.result
        }
        defer { drainer.processRunner = { executable, arguments, timeout in
            RemoteSpoolDrainer.runProcess(executable: executable, arguments: arguments, timeout: timeout)
        } }
        drainer.startDrain(host: "b232-inject")
        pump(2)
        check("spoolSeam: 注入 runner 被 ssh 调用",
              recorder.snapshot().first?.0 == "/usr/bin/ssh")
        check("spoolSeam: nil 结果触发 mux reset 二调",
              recorder.snapshot().count == 2
              && recorder.snapshot()[1].1.first == "-o"
              && recorder.snapshot()[1].1.contains("exit"))
        check("spoolSeam: drain 完成 inFlight 清空", drainer.inFlight.isEmpty)
        check("spoolSeam: 状态落账", drainer.statuses["b232-inject"] != nil)

        // 6) tick：pendingReplay 优先消化（isEnabled=false → 积压诚实丢弃）
        drainer.pendingReplay = ["{bad json}", "{\"event\":\"Stop\"}"]
        RemoteSpoolHosts.saveHosts(["b232-should-not-ssh"], defaults: .standard)
        ClaudeHookPreferences.isEnabled = true
        let emptyRunner: SpoolProcessRunner = { _, _, _ in nil }
        drainer.processRunner = emptyRunner
        drainer.tick()
        pump(2)
        check("spoolSeam: 积压优先消化不再 ssh 拉取",
              recorder.snapshot().count == 2 && drainer.pendingReplay.isEmpty)
        RemoteSpoolHosts.saveHosts([], defaults: .standard)

        // 7) tick：空主机清单零 ssh 零 startDrain
        let callsBefore = recorder.snapshot().count
        drainer.tick()
        check("spoolSeam: 空主机清单零调用", recorder.snapshot().count == callsBefore)
    }
}
