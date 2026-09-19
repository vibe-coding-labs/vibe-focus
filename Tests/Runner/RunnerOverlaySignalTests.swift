// Tests/Runner/RunnerOverlaySignalTests.swift — ScreenOverlayManager 信号链实例接线直测（B234）。
// 决策纯表（OverlayRefreshPolicy.forceRefreshDecision/isDuplicateForceTrigger）已有穷尽锁定；
// 本文件锁的是**实例接线**：SIGUSR1 派发源端到端、去重→broadcastOnly（只发广播不重活）、
// 新触发→refreshAndBroadcast（时间戳推进+缓存清理+广播）、挂起语义（B175：挂起不吞事件刷新）、
// follow-up 空表契约（follow-up 已删除的演进锚）、toggle 后防抖调度与取消。
// 真实副作用边界：refreshSpaceIndices(force:) 在本机做只读 yabai 查询（~0.2s/次），
// 全程不创建 overlay 窗口（runner 进程 overlayWindows 为空）。

import AppKit
import Foundation
@testable import VibeFocusKit

extension RunnerHarness {
    func runOverlaySignalTests() {
        let shared = ScreenOverlayManager.shared
        // 共享实例构造即安装 SIGUSR1 派发源（setupSignalHandler）。
        // ⚠️ 必须先触碰 shared：访问静态 signalSource 不会触发 shared 的懒初始化。
        check("overlaySignal: SIGUSR1 派发源已安装",
              ScreenOverlayManager.signalSource != nil)
        let center = NotificationCenter.default
        let name = Notification.Name.vibefocusSpaceStateMayHaveChanged
        // 计数盒：observer 闭包 @Sendable，可变局部捕获会触发并发告警（门禁零警告红线）
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        let observer = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            counter.value += 1
        }
        defer { center.removeObserver(observer) }

        // A. 去重→broadcastOnly：时间戳新鲜（内部可写）→ 只发广播，不动时间戳/缓存。
        //    伪造缓存哨兵（真实 UUID 不可能复现）验证「免重活」——缓存未被清理。
        let sentinel1 = UUID()
        shared.screenSpaceCache[sentinel1] = (screenIndex: 9, yabaiDisplayIndex: 9, spaceIndex: 9)
        shared.lastQueryTimes[sentinel1] = Date()
        shared.lastForceRefreshTriggerAt = Date()
        let beforeDup = shared.lastForceRefreshTriggerAt
        counter.value = 0
        shared.triggerForceRefresh(reason: "vf-test-duplicate")
        check("overlaySignal: 去重触发只发广播（通知计数 1）", counter.value == 1)
        check("overlaySignal: 去重触发不推进时间戳", shared.lastForceRefreshTriggerAt == beforeDup)
        check("overlaySignal: 去重触发不清缓存（哨兵存活）",
              shared.screenSpaceCache[sentinel1] != nil && shared.lastQueryTimes[sentinel1] != nil)

        // B. 新触发→refreshAndBroadcast：时间戳推进 + 缓存清理（哨兵消失；真实查询
        //    可能回填新条目，但伪造 UUID 不会回来）+ 广播发出。真实 yabai 只读查询 ~0.2s。
        shared.lastForceRefreshTriggerAt = .distantPast
        counter.value = 0
        shared.triggerForceRefresh(reason: "vf-test-fresh")
        check("overlaySignal: 新触发发广播", counter.value == 1)
        check("overlaySignal: 新触发推进时间戳",
              shared.lastForceRefreshTriggerAt > beforeDup)
        check("overlaySignal: 新触发清缓存（伪造哨兵消失）",
              shared.screenSpaceCache[sentinel1] == nil && shared.lastQueryTimes[sentinel1] == nil)

        // C. 挂起语义（B175）：挂起 + 新触发仍走 refreshAndBroadcast（挂起只治理兜底
        //    Timer，不吞事件刷新——角标停格 7.2s 事故的防回退锚）。真实查询 ~0.2s。
        let savedSuspended = shared.automaticRefreshSuspended
        shared.automaticRefreshSuspended = true
        shared.lastForceRefreshTriggerAt = .distantPast
        let sentinel2 = UUID()
        shared.screenSpaceCache[sentinel2] = (screenIndex: 8, yabaiDisplayIndex: 8, spaceIndex: 8)
        counter.value = 0
        shared.triggerForceRefresh(reason: "vf-test-suspended-fresh")
        check("overlaySignal: 挂起不吞事件刷新（仍 refreshAndBroadcast）",
              counter.value == 1 && shared.lastForceRefreshTriggerAt > .distantPast
              && shared.screenSpaceCache[sentinel2] == nil)
        shared.automaticRefreshSuspended = savedSuspended

        // D. SIGUSR1 端到端=诚实留白（生产观察归口）：独立探针实证（2026-09-19，
        //    macOS 15 arm64，解释执行与 swiftc 编译二进制一致）GCD DispatchSourceSignal
        //    在 CLI 进程内 raise 后不投递（主队列/全局队列、屏蔽解除后均不 fire；
        //    同进程主队列 async 块照常投递=泵机制无损）——生产 app 真实工作
        //    （yabai space_changed → SIGUSR1 → refresh 日志链实证），结构性不可达
        //    归生产观察。事件闭包体（log + triggerForceRefresh("sigusr1")）的两半
        //    均已被 A~C 分支直测覆盖。

        // E. follow-up 空表契约：follow-up 刷新已删除（真机实测从未纠正过结果，
        //    切屏 yabai fork 2→1）——调度后 pending 必须保持空；cancel 对空表安全。
        shared.scheduleSignalFollowUpRefreshes()
        check("overlaySignal: follow-up 空表契约（调度后 pending 为空）",
              shared.pendingSignalRefreshWorkItems.isEmpty)
        shared.cancelPendingSignalRefreshes()
        check("overlaySignal: cancel 空表安全", shared.pendingSignalRefreshWorkItems.isEmpty)

        // F. toggle 后防抖调度与取消：0.3s 后才 fire；取消后泵过窗口也不 fire
        //    （时间戳不推进=零 yabai fork 的防回归锚）。
        shared.lastForceRefreshTriggerAt = .distantPast
        let tBeforeSchedule = shared.lastForceRefreshTriggerAt
        shared.schedulePostToggleRefresh(reason: "vf-test-debounce")
        check("overlaySignal: 防抖 work item 已挂起",
              shared.pendingPostToggleRefreshWorkItem != nil)
        shared.pendingPostToggleRefreshWorkItem?.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        check("overlaySignal: 取消后防抖不 fire（时间戳未推进=零 fork）",
              shared.lastForceRefreshTriggerAt == tBeforeSchedule)

        // 收尾：restore 触发时间戳语义（下一次真实信号不被测试期时间戳抑制）。
        shared.lastForceRefreshTriggerAt = .distantPast
    }
}
