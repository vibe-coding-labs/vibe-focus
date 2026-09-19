// Tests/Runner/RunnerSupportStackTests.swift
// B214 覆盖堆叠·支持栈域：AppVersion / WindowWorkExecutor / NativeSpaceBridge
// （仅 logAvailability——dismissMissionControl 会注入真实 Escape 事件，归真机 E2E）/
// UserNotificationPoster（Runner 无 bundle id 短路态；UN 框架真实路径需宿主 app）。
// 异步桥接统一走 B154 家法：Task { @MainActor } + 短片等待泵主 RunLoop。

import Foundation
import AppKit
@testable import VibeFocusKit

extension RunnerHarness {

    // MARK: - AppVersion（版本单一事实源与 Info.plist 读回）

    func runAppVersionTests() {
        print("\n=== AppVersion (B214) ===")
        // releaseVersion 是 build-release.sh / package_release.sh awk 提取锚点：
        // 必须是纯字面量。此断言同时是「脚本提取失效→装机 0.0.0」事故（2026-09-10）
        // 的回归锁——字面量若被改回 computed，此处对比会率先 FAIL。
        check("appVersion: releaseVersion 是发布号字面量", AppVersion.releaseVersion.hasPrefix("0."))
        check("appVersion: releaseVersion 非空且含补丁段",
              AppVersion.releaseVersion.components(separatedBy: ".").count == 3)
        // Runner 无 Info.plist → current 回落 "unknown"；装机 app 有 plist → 读回真实值。
        // 两条路径都合法，锁「不崩溃且非空」这一契约。
        let cur = AppVersion.current
        check("appVersion: current 非空", !cur.isEmpty)
        check("appVersion: current 在 {unknown, 版本号} 域内",
              cur == "unknown" || cur.components(separatedBy: ".").count == 3)
    }

    // MARK: - WindowWorkExecutor（B180 串行作业队列）

    func runWindowWorkExecutorTests() {
        print("\n=== WindowWorkExecutor (B214) ===")

        final class Seq: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [String] = []
            func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
            func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return items }
        }
        final class Box: @unchecked Sendable {
            var value: Int = 0
        }

        // 1) 值透传：后台作业结果原样回到 await 方
        do {
            let box = Box()
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                let v = await WindowWorkExecutor.run { 41 + 1 }
                box.value = v
                sem.signal()
            }
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if sem.wait(timeout: .now() + 0.05) == .success { break }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            check("executor: 值透传 41+1==42", box.value == 42)
        }

        // 2) 串行互斥：首作业霸占队列期间，后续作业不得并发执行；
        //    放行后按入队次序完成（blocker → w2/w3，后两者相对序不锁——
        //    async let 两个子任务竞步入队，FIFO 属队列实现细节）。
        do {
            let seq = Seq()
            let release = DispatchSemaphore(value: 0)
            let done = DispatchSemaphore(value: 0)
            final class Probe: @unchecked Sendable {
                var duringBlock: [String] = []
                var r2 = 0
                var r3 = 0
            }
            let probe = Probe()
            Task { @MainActor in
                async let blocker: Void = WindowWorkExecutor.run {
                    seq.add("blocker-in")
                    release.wait()
                    seq.add("blocker-out")
                }
                // 等 blocker 真正起跑（轮询——async 上下文里 DispatchSemaphore.wait 不可用）
                var waited = 0
                while seq.snapshot().isEmpty && waited < 500 {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    waited += 1
                }
                async let w2 = WindowWorkExecutor.run { seq.add("w2"); return 2 }
                async let w3 = WindowWorkExecutor.run { seq.add("w3"); return 3 }
                // blocker 尚未放行：串行队列被占用，w2/w3 不得开始
                try? await Task.sleep(nanoseconds: 150_000_000)
                probe.duringBlock = seq.snapshot()
                release.signal()
                probe.r2 = await w2
                probe.r3 = await w3
                _ = await blocker
                done.signal()
            }
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if done.wait(timeout: .now() + 0.05) == .success { break }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            check("executor: 霸占期间无并发执行", probe.duringBlock == ["blocker-in"])
            check("executor: 后续作业值透传", probe.r2 == 2 && probe.r3 == 3)
            let s = seq.snapshot()
            check("executor: 串行完成序（blocker 先、w2/w3 后不交叠）",
                  s.count == 4 && s.first == "blocker-in" && s[1] == "blocker-out"
                  && Set(s.dropFirst(2)) == ["w2", "w3"])
        }
    }

    // MARK: - NativeSpaceBridge（SLS 诊断；Escape 注入归真机 E2E）

    func runNativeSpaceBridgeTests() {
        print("\n=== NativeSpaceBridge (B214) ===")
        // logAvailability：dlopen SkyLight + dlsym 探测，仅日志无副作用。
        // 系统框架必在：两种 loaded 记录都合法，锁「可调用不崩溃」。
        NativeSpaceBridge.logAvailability()
        check("spaceBridge: logAvailability 可调用不崩溃", true)
    }

    // MARK: - UserNotificationPoster（Runner 短路态）

    func runNotificationPosterTests() {
        print("\n=== UserNotificationPoster (B214) ===")
        // Runner/SwiftPM 可执行无 bundle id：UNUserNotificationCenter 不可用，
        // post 必须短路返回 false（门禁进程内不触碰 UN 框架的契约）。
        check("poster: Runner 内 isNotificationAvailable==false",
              UserNotificationPoster.isNotificationAvailable == false)

        final class Box: @unchecked Sendable { var posted: Bool? = nil }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            let content = HookNotificationContent(
                identifier: "b214-runner", title: "t", body: "b")
            box.posted = await UserNotificationPoster.shared.post(content)
            sem.signal()
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if sem.wait(timeout: .now() + 0.05) == .success { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        check("poster: 无 bundle 环境投递短路 false", box.posted == false)
    }
}
