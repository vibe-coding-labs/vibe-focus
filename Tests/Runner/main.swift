// Tests/Runner/main.swift
// 真实代码测试运行器（过渡通道，2026-09-02）
//
// CLT-only 环境无 XCTest/Swift Testing 运行时（playbook 2.10：`xcrun --find xctest`
// 失败、CLT 无 Testing 模块），Tests/XCTest 的 Swift Testing 套件从未在本机执行过。
// 本运行器以 `@testable import VibeFocusKit`（debug 构建自带 -enable-testing）直测
// internal 逻辑——测的是 Sources/ 真实实现，无 Standalone 镜像的同步漂移风险。
//
// Run:    swift run VibeFocusTestRunner
// 覆盖率: bash scripts/coverage_test_runner.sh（-profile-generate + llvm-cov 真实数字）

import ApplicationServices
import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

// MARK: - 假通道（记录调用序列，RestoreSwitchOrchestration 分支穷尽锁定用）

@MainActor
final class FakeRestoreChannels: RestoreSpaceChanneling {
    var canControlSpaces: Bool
    var currentSpace: Int?
    /// preMoveSpace 采集/守卫检查按调用顺序依次取值（模拟漂移时序）
    var currentSpaceQueue: [Int?]
    var focusResult = false
    var refocusResult = false
    /// 守卫轻查询计划：按 space 过滤的窗口列表
    var spaceWindows: [YabaiWindowInfo]?
    var queryResult: YabaiWindowInfo?
    /// 初次可见 space 查询（4-pre 预切回决策）
    var visibleSpace: SpaceIdentifier?
    /// 切回后 ignoreCache 轮询查询（「等到位」目标态）
    var visibleSpaceAfterSwitch: SpaceIdentifier?
    var floatOutcome: SpaceController.FloatToggleOutcome = .skippedNoOp

    private(set) var calls: [String] = []
    private(set) var focusWindowReceived: UInt32?
    private(set) var focusReceived: SpaceIdentifier?
    private(set) var refocusReceivedSpace: Int?
    private(set) var refocusReceivedExcluded: UInt32?
    private(set) var refocusReceivedPrefetched: [YabaiWindowInfo]?
    private(set) var cacheCleared = false
    private(set) var floatCalled = false

    init(canControlSpaces: Bool, currentSpace: Int?) {
        self.canControlSpaces = canControlSpaces
        self.currentSpace = currentSpace
        self.currentSpaceQueue = [currentSpace]
    }

    func focusSpace(_ space: SpaceIdentifier, operationID: String?) -> Bool {
        calls.append("focus")
        focusReceived = space
        return focusResult
    }

    func refocusWindowOnSpace(_ spaceIndex: Int, excludingWindowID: UInt32?, operationID: String?, prefetchedWindows: [YabaiWindowInfo]?) -> Bool {
        calls.append("refocus")
        refocusReceivedSpace = spaceIndex
        refocusReceivedExcluded = excludingWindowID
        refocusReceivedPrefetched = prefetchedWindows
        return refocusResult
    }

    func currentSpaceIndex() -> Int? {
        calls.append("current")
        guard !currentSpaceQueue.isEmpty else { return currentSpace }
        return currentSpaceQueue.removeFirst()
    }

    func clearQueryCache() {
        calls.append("clearCache")
        cacheCleared = true
    }

    func queryWindow(windowID: UInt32, ignoreCache: Bool) -> YabaiWindowInfo? {
        calls.append("query")
        return queryResult
    }

    func visibleSpaceIndex(forDisplayIndex: Int?, spaces: [YabaiSpaceInfo]?, ignoreCache: Bool) -> SpaceIdentifier? {
        calls.append("visible")
        return ignoreCache ? visibleSpaceAfterSwitch : visibleSpace
    }

    func setWindowFloat(_ windowID: UInt32, operationID: String?, knownWindowInfo: YabaiWindowInfo?) -> SpaceController.FloatToggleOutcome {
        calls.append("float")
        floatCalled = true
        return floatOutcome
    }

    func queryWindowsOnSpace(_ spaceIndex: Int, operationID: String?) -> [YabaiWindowInfo]? {
        calls.append("querySpaceWindows")
        return spaceWindows
    }
}

// MARK: - restore 主体假依赖（record 存取 / 窗口操作 / 审计收集）

@MainActor
final class FakeRecords: RestoreRecordStoring {
    let record: ToggleRecord?
    private(set) var clearCalls = 0

    init(record: ToggleRecord?) {
        self.record = record
    }

    func load(windowID: UInt32) -> ToggleRecord? { record }
    func clear(windowID: UInt32) { clearCalls += 1 }
}

@MainActor
final class FakeWindows: RestoreWindowOperating {
    var findResult: AXUIElement?
    var moveResult = true
    var displayContextResult: (yabaiIndex: Int?, displayID: UInt32?) = (yabaiIndex: 2, displayID: nil)
    private(set) var moveCalls: [(windowID: UInt32, stage: String)] = []

    init(findResult: AXUIElement?, moveResult: Bool = true) {
        self.findResult = findResult
        self.moveResult = moveResult
    }

    func findWindowByPID(_ pid: pid_t, windowID: UInt32?) -> AXUIElement? { findResult }

    func moveWindowToFrameViaYabai(windowID: UInt32, frame: CGRect, op: String, stage: String, sourceVisibleFrame: CGRect?) -> Bool {
        moveCalls.append((windowID, stage))
        return moveResult
    }

    func displayContext(for frame: CGRect) -> (yabaiIndex: Int?, displayID: UInt32?) {
        displayContextResult
    }
}

@MainActor
final class FakeAuditor: RestoreAuditing {
    struct Event {
        let eventType: String
        let windowID: UInt32
        let pid: Int32?
        let details: [String: String]
    }

    private(set) var events: [Event] = []

    func record(eventType: String, windowID: UInt32, pid: Int32?, sessionID: String?, details: [String: String]) {
        events.append(Event(eventType: eventType, windowID: windowID, pid: pid, details: details))
    }
}

// MARK: - 全部分支锁定（MainActor 隔离域内执行）

/// 与 HotKeyManager.validate 同语义的校验（修饰键 + 已知系统冲突表）
func hotKeyPassesSystemConflicts(_ hk: HotKeyConfiguration) -> Bool {
    let hasModifier = hk.modifiers & (UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)) != 0
    let noSystemConflict = HotKeyConfiguration.knownConflicts.first(where: { $0.configuration == hk }) == nil
    return hasModifier && noSystemConflict
}

@MainActor func runAllTests() {
    var passed = 0
    var failed = 0
    func check(_ name: String, _ condition: Bool) {
        if condition { passed += 1; print("  PASS: \(name)") }
        else { failed += 1; print("  FAIL: \(name)") }
    }

    func window(id: Int, space: Int, hasAX: Bool = true, minimized: Bool? = nil, hasFocus: Bool? = nil) -> YabaiWindowInfo {
        YabaiWindowInfo(
            id: id, pid: 100, app: "App", title: "w\(id)",
            space: space, display: 1, frame: nil,
            isFloatingRaw: false, hasAXReferenceRaw: hasAX,
            isMinimizedRaw: minimized, hasFocusRaw: hasFocus
        )
    }

    // MARK: switchSourceSpace（4-pre 源屏预切回双层编排）

    do {
        let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: nil)
        ch.focusResult = true
        let ok = RestoreSwitchOrchestration.switchSourceSpace(channels: ch, sourceSpace: 3, operationID: "t")
        check("4-pre 编排: SA 可用+直切成功 → true，不再降级聚焦带动",
              ok && ch.calls == ["focus"] && ch.focusReceived == .yabaiIndex(3))
    }
    do {
        let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: nil)
        ch.focusResult = false
        ch.refocusResult = true
        let ok = RestoreSwitchOrchestration.switchSourceSpace(channels: ch, sourceSpace: 3, operationID: "t")
        check("4-pre 编排: SA 直切失败 → 降级聚焦带动成功",
              ok && ch.calls == ["focus", "refocus"] && ch.refocusReceivedSpace == 3)
    }
    do {
        let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: nil)
        ch.focusResult = false
        ch.refocusResult = false
        let ok = RestoreSwitchOrchestration.switchSourceSpace(channels: ch, sourceSpace: 3, operationID: "t")
        check("4-pre 编排: 两层全失败 → false（spaceExact=false 上报）",
              !ok && ch.calls == ["focus", "refocus"])
    }
    do {
        let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: nil)
        ch.refocusResult = true
        let ok = RestoreSwitchOrchestration.switchSourceSpace(channels: ch, sourceSpace: 3, operationID: "t")
        check("4-pre 编排: SA 不可用 → 不调直切，聚焦带动成功",
              ok && ch.calls == ["refocus"] && ch.refocusReceivedSpace == 3)
    }
    do {
        let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: nil)
        ch.refocusResult = false
        let ok = RestoreSwitchOrchestration.switchSourceSpace(channels: ch, sourceSpace: 3, operationID: "t")
        check("4-pre 编排: SA 不可用+聚焦带动失败 → false",
              !ok && ch.calls == ["refocus"])
    }
    do {
        let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: nil)
        _ = RestoreSwitchOrchestration.switchSourceSpace(channels: ch, sourceSpace: 3, operationID: "t")
        check("4-pre 编排: 预切回不 exclude 被恢复窗口（窗口尚未移动，不在源 space 上）",
              ch.refocusReceivedExcluded == nil)
    }

    // MARK: refocusPerspective（视角守卫双层编排）

    do {
        let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: nil)
        let outcome = RestoreSwitchOrchestration.refocusPerspective(channels: ch, preMoveSpace: 1, excludingWindowID: 9, operationID: "t")
        check("守卫编排: focused space 查询失败 → noDrift，只做一次查询、不触发任何切回通道",
              outcome == .noDrift && ch.calls == ["current"])
    }
    do {
        let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
        let outcome = RestoreSwitchOrchestration.refocusPerspective(channels: ch, preMoveSpace: 1, excludingWindowID: 9, operationID: "t")
        check("守卫编排: 无漂移（current == pre）→ noDrift，只做一次查询、不触发任何切回通道",
              outcome == .noDrift && ch.calls == ["current"])
    }
    do {
        let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 5)
        ch.focusResult = true
        let outcome = RestoreSwitchOrchestration.refocusPerspective(channels: ch, preMoveSpace: 1, excludingWindowID: 9, operationID: "t")
        check("守卫编排: 漂移+直切成功 → refocused(postSpace=5)，清缓存，不降级",
              outcome == .refocused(postSpace: 5) && ch.calls == ["current", "focus", "clearCache"]
              && ch.focusReceived == .yabaiIndex(1) && ch.cacheCleared)
    }
    do {
        // 轻查询计划：SA=false → spaces 轻查判漂移 + refocusWindowOnSpace（内部 --space 过滤查询+聚焦）
        let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: 5)
        ch.refocusResult = true
        let outcome = RestoreSwitchOrchestration.refocusPerspective(channels: ch, preMoveSpace: 1, excludingWindowID: 9, operationID: "t")
        check("守卫轻查询: SA=false 漂移+聚焦带动成功 → refocused(5)，fork 序 current/refocus/clearCache",
              outcome == .refocused(postSpace: 5) && ch.calls == ["current", "refocus", "clearCache"]
              && ch.refocusReceivedSpace == 1 && ch.refocusReceivedExcluded == 9)
    }
    do {
        let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: 1)
        let outcome = RestoreSwitchOrchestration.refocusPerspective(channels: ch, preMoveSpace: 1, excludingWindowID: 9, operationID: "t")
        check("守卫轻查询: focused == preMoveSpace → noDrift，仅一次 spaces 轻查",
              outcome == .noDrift && ch.calls == ["current"])
    }
    do {
        let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: nil)
        let outcome = RestoreSwitchOrchestration.refocusPerspective(channels: ch, preMoveSpace: 1, excludingWindowID: 9, operationID: "t")
        check("守卫轻查询: focused space 查询失败 → noDrift（不盲切语义）",
              outcome == .noDrift && ch.calls == ["current"])
    }
    do {
        // 预取传递：守卫降级时把调用方预取的候选列表透传给通道（省一次查询 fork）
        let prefetched = [YabaiWindowInfo(id: 77, pid: 100, app: "App", title: "pre", space: 1, display: 1, frame: nil, isFloatingRaw: false, hasAXReferenceRaw: true, isMinimizedRaw: false)]
        let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: 5)
        ch.refocusResult = true
        let outcome = RestoreSwitchOrchestration.refocusPerspective(channels: ch, preMoveSpace: 1, excludingWindowID: 9, operationID: "t", prefetchedWindows: prefetched)
        check("守卫预取: 预取列表透传 refocusWindowOnSpace（不触发内部查询）",
              outcome == .refocused(postSpace: 5) && ch.calls == ["current", "refocus", "clearCache"]
              && ch.refocusReceivedPrefetched?.first?.id == 77)
    }
    do {
        let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: 5)
        ch.refocusResult = false
        let outcome = RestoreSwitchOrchestration.refocusPerspective(channels: ch, preMoveSpace: 1, excludingWindowID: 9, operationID: "t")
        check("守卫轻查询: 漂移+聚焦带动失败（preMoveSpace 无可聚焦窗口）→ failed(5) 不清缓存",
              outcome == .failed(postSpace: 5) && ch.calls == ["current", "refocus"] && !ch.cacheCleared)
    }
    do {
        // SA=true 且直切失败 → 降级 refocusWindowOnSpace（内部轻查询+聚焦）
        let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 5)
        ch.focusResult = false
        ch.refocusResult = true
        let outcome = RestoreSwitchOrchestration.refocusPerspective(channels: ch, preMoveSpace: 1, excludingWindowID: 9, operationID: "t")
        check("守卫轻查询: SA=true 直切失败 → 降级聚焦带动成功（exclude 被恢复窗口自身）",
              outcome == .refocused(postSpace: 5) && ch.calls == ["current", "focus", "refocus", "clearCache"]
              && ch.refocusReceivedExcluded == 9)
    }

    // MARK: sourceSpacePreSwitch（4-pre 预切回决策，真实实现）

    check("4-pre 决策: sourceSpace=0 → noContext",
          ToggleEngine.sourceSpacePreSwitch(sourceSpace: 0, sourceYabaiDisp: 2, visibleSpaceOnSourceDisplay: 3) == .noContext)
    check("4-pre 决策: sourceYabaiDisp=0 → noContext",
          ToggleEngine.sourceSpacePreSwitch(sourceSpace: 3, sourceYabaiDisp: 0, visibleSpaceOnSourceDisplay: 3) == .noContext)
    check("4-pre 决策: 全缺 → noContext",
          ToggleEngine.sourceSpacePreSwitch(sourceSpace: 0, sourceYabaiDisp: 0, visibleSpaceOnSourceDisplay: nil) == .noContext)
    check("4-pre 决策: 可见性查询失败 → notNeeded（不盲切）",
          ToggleEngine.sourceSpacePreSwitch(sourceSpace: 3, sourceYabaiDisp: 2, visibleSpaceOnSourceDisplay: nil) == .notNeeded)
    check("4-pre 决策: 已在源 space → notNeeded",
          ToggleEngine.sourceSpacePreSwitch(sourceSpace: 3, sourceYabaiDisp: 2, visibleSpaceOnSourceDisplay: 3) == .notNeeded)
    check("4-pre 决策: 停在别的 space → switchNeeded(visibleSpace:)",
          ToggleEngine.sourceSpacePreSwitch(sourceSpace: 3, sourceYabaiDisp: 2, visibleSpaceOnSourceDisplay: 5) == .switchNeeded(visibleSpace: 5))

    // MARK: isMoveFailureRetryable（失败 record 处置，真实实现）

    check("失败处置: origFrame 仍在屏上 → 保留 record",
          ToggleEngine.isMoveFailureRetryable(origFrameOnAnyDisplay: true))
    check("失败处置: origFrame 屏外 → 清除 record",
          !ToggleEngine.isMoveFailureRetryable(origFrameOnAnyDisplay: false))

    // MARK: selectRefocusCandidate（refocus 候选选择，真实实现）

    check("候选: 选中目标 space 唯一可管理窗口",
          SpaceController.selectRefocusCandidate(windows: [window(id: 1, space: 2), window(id: 2, space: 3)], spaceIndex: 3, excludingWindowID: nil)?.id == 2)
    check("候选: 跳过排除的 windowID",
          SpaceController.selectRefocusCandidate(windows: [window(id: 7, space: 3)], spaceIndex: 3, excludingWindowID: 7) == nil)
    check("候选: 跳过无 AX 引用窗口",
          SpaceController.selectRefocusCandidate(windows: [window(id: 1, space: 3, hasAX: false), window(id: 2, space: 3)], spaceIndex: 3, excludingWindowID: nil)?.id == 2)
    check("候选: 偏好非最小化窗口",
          SpaceController.selectRefocusCandidate(windows: [window(id: 1, space: 3, minimized: true), window(id: 2, space: 3, minimized: false)], spaceIndex: 3, excludingWindowID: nil)?.id == 2)
    check("候选: 全部最小化退回最小化候选",
          SpaceController.selectRefocusCandidate(windows: [window(id: 1, space: 3, minimized: true), window(id: 2, space: 3, minimized: true)], spaceIndex: 3, excludingWindowID: nil)?.id == 1)
    check("候选: minimized 缺失按未最小化",
          SpaceController.selectRefocusCandidate(windows: [window(id: 1, space: 3, minimized: nil), window(id: 2, space: 3, minimized: true)], spaceIndex: 3, excludingWindowID: nil)?.id == 1)
    check("候选: 目标 space 无窗口 → nil",
          SpaceController.selectRefocusCandidate(windows: [window(id: 1, space: 2)], spaceIndex: 3, excludingWindowID: nil) == nil)

    // MARK: FloatToggleOutcome（float 脱管结局，真实实现）

    check("float 结局: toggled → didToggle=true",
          SpaceController.FloatToggleOutcome.toggled.didToggle)
    check("float 结局: skippedNoOp → didToggle=false",
          !SpaceController.FloatToggleOutcome.skippedNoOp.didToggle)

    // MARK: RestoreOutcome.outcomeLabel（结局标签，真实实现）

    check("结局标签: restored(spaceExact=true)",
          ToggleEngine.RestoreOutcome.restored(spaceExact: true).outcomeLabel == "restored(spaceExact=Optional(true))")
    check("结局标签: restored(spaceExact=false)",
          ToggleEngine.RestoreOutcome.restored(spaceExact: false).outcomeLabel == "restored(spaceExact=Optional(false))")
    check("结局标签: restored(spaceExact=nil)",
          ToggleEngine.RestoreOutcome.restored(spaceExact: nil).outcomeLabel == "restored(spaceExact=nil)")
    check("结局标签: aborted 携带原因",
          ToggleEngine.RestoreOutcome.aborted(reason: "no_toggle_record").outcomeLabel == "aborted_no_toggle_record")
    check("结局标签: 瞬时失败明示 record 保留",
          ToggleEngine.RestoreOutcome.moveFailedRetryable.outcomeLabel == "move_failed_retryable_record_kept")
    check("结局标签: 永久失败明示 record 清除",
          ToggleEngine.RestoreOutcome.moveFailedPermanent.outcomeLabel == "move_failed_permanent_record_cleared")

    // MARK: saProbeVerdict（SA 探针裁决，真实实现——v7 陈旧判据重写后的事实源）

    check("SA 探针: exit 0 = SA 必在",
          SpaceController.saProbeVerdict(exitCode: 0, stderr: "")
          && SpaceController.saProbeVerdict(exitCode: 0, stderr: "anything"))
    check("SA 探针: scripting-addition 报错 = 未加载",
          !SpaceController.saProbeVerdict(exitCode: 1, stderr: "yabai: error with the scripting-addition"))
    check("SA 探针: mission-control 阻塞 = 如实上报不可用",
          !SpaceController.saProbeVerdict(exitCode: 1, stderr: "yabai: cannot focus space: mission-control is active!"))
    check("SA 探针: 已聚焦逻辑错误 = SA 可用（无副作用路径）",
          SpaceController.saProbeVerdict(exitCode: 1, stderr: "cannot focus an already focused space."))
    check("SA 探针: 空 stderr 与查询类预期失败 = SA 可用",
          SpaceController.saProbeVerdict(exitCode: 1, stderr: "")
          && SpaceController.saProbeVerdict(exitCode: 1, stderr: "could not retrieve window details")
          && SpaceController.saProbeVerdict(exitCode: 1, stderr: "could not locate window"))
    check("SA 探针: 未识别 stderr 放行 + 大小写不敏感",
          SpaceController.saProbeVerdict(exitCode: 1, stderr: "something unexpected happened")
          && !SpaceController.saProbeVerdict(exitCode: 1, stderr: "ERROR WITH THE SCRIPTING-ADDITION"))

    // MARK: ConditionPolling（等到位有界轮询，真实实现——P1-2）

    do {
        var sleepCount = 0
        check("轮询: 首查即满足 → 零等待 satisfied(checks:1)",
              ConditionPolling.waitUntil(intervalMs: 50, budgetMs: 800,
                                         sleep: { _ in sleepCount += 1 },
                                         condition: { true }) == .satisfied(checks: 1)
              && sleepCount == 0)
    }
    do {
        var naps = 0
        var polls = 0
        check("轮询: 第 3 次检查满足 → sleep 2 次（check/sleep 严格交替）",
              ConditionPolling.waitUntil(intervalMs: 50, budgetMs: 800,
                                         sleep: { _ in naps += 1 },
                                         condition: { polls += 1; return polls >= 3 }) == .satisfied(checks: 3)
              && naps == 2)
    }
    do {
        var timeoutNaps = 0
        check("轮询: 预算耗尽仍不满足 → exhausted（sleep 次数 = budget/interval）",
              ConditionPolling.waitUntil(intervalMs: 50, budgetMs: 800,
                                         sleep: { _ in timeoutNaps += 1 },
                                         condition: { false }) == .exhausted
              && timeoutNaps == 16)
    }
    do {
        var zeroBudgetSleeps = 0
        check("轮询: budget=0 且不满足 → 只首查不睡",
              ConditionPolling.waitUntil(intervalMs: 50, budgetMs: 0,
                                         sleep: { _ in zeroBudgetSleeps += 1 },
                                         condition: { false }) == .exhausted
              && zeroBudgetSleeps == 0)
    }
    do {
        var clampedNaps: [UInt32] = []
        check("轮询: interval > 剩余预算时末轮钳制",
              ConditionPolling.waitUntil(intervalMs: 200, budgetMs: 100,
                                         sleep: { clampedNaps.append($0) },
                                         condition: { false }) == .exhausted
              && clampedNaps == [100])
    }
    do {
        let miss = ConditionPolling.waitUntil(intervalMs: 50, budgetMs: 800, sleep: { _ in }, condition: { false })
        let hit = ConditionPolling.waitUntil(intervalMs: 50, budgetMs: 800, sleep: { _ in }, condition: { true })
        check("轮询结局: satisfied 便捷判定两分支",
              !miss.satisfied && hit.satisfied)
    }
    do {
        // 默认 usleep 通道实跑 1ms（覆盖默认 sleep 闭包体）
        var polls = 0
        let outcome = ConditionPolling.waitUntil(intervalMs: 1, budgetMs: 1, condition: { polls += 1; return polls >= 2 })
        check("轮询: 默认 usleep 通道可用", outcome == .satisfied(checks: 2))
    }

    // MARK: FrameConvergence.convergeFramePolling（帧写入轮询收敛，真实实现——水感优化）

    do {
        var writes = 0
        let outcome = FrameConvergence.convergeFramePolling(
            attempts: 2, intervalMs: 25, budgetMs: 400,
            write: { writes += 1; return true },
            read: { CGRect(x: 0, y: 0, width: 10, height: 10) },
            isConverged: { _ in true },
            sleep: { _ in fatalError("首查即收敛不应睡眠") })
        check("轮询收敛: 首查即收敛 → converged(attempt:1) 零睡眠零重写",
              outcome == .converged(attempt: 1, frame: CGRect(x: 0, y: 0, width: 10, height: 10)) && writes == 1)
    }
    do {
        var writes = 0
        var reads = 0
        var sleeps = 0
        let outcome = FrameConvergence.convergeFramePolling(
            attempts: 2, intervalMs: 25, budgetMs: 400,
            write: { writes += 1; return true },
            read: { reads += 1; return CGRect(x: reads, y: 0, width: 10, height: 10) },
            isConverged: { $0.origin.x >= 3 },
            sleep: { _ in sleeps += 1 })
        check("轮询收敛: 第 3 次读达标 → converged(attempt:1)，睡 2 次",
              outcome == .converged(attempt: 1, frame: CGRect(x: 3, y: 0, width: 10, height: 10))
              && writes == 1 && reads == 3 && sleeps == 2)
    }
    do {
        var writes = 0
        let outcome = FrameConvergence.convergeFramePolling(
            attempts: 2, intervalMs: 25, budgetMs: 50,
            write: { writes += 1; return true },
            read: { CGRect(x: writes - 1, y: 0, width: 10, height: 10) },
            isConverged: { $0.origin.x >= 1 },
            sleep: { _ in })
        check("轮询收敛: 首轮预算耗尽 → 重写一次，次轮收敛 converged(attempt:2)",
              outcome == .converged(attempt: 2, frame: CGRect(x: 1, y: 0, width: 10, height: 10)) && writes == 2)
    }
    do {
        var last: CGRect? = nil
        var mismatchAttempts = 0
        if case .mismatched(let attempts, let frame) = FrameConvergence.convergeFramePolling(
            attempts: 2, intervalMs: 25, budgetMs: 50,
            write: { true },
            read: { CGRect(x: 7, y: 7, width: 1, height: 1) },
            isConverged: { _ in false },
            sleep: { _ in }) {
            mismatchAttempts = attempts
            last = frame
        }
        check("轮询收敛: 全程不收敛 → mismatched(attempts:2) 携带最后一次读回",
              mismatchAttempts == 2 && last == CGRect(x: 7, y: 7, width: 1, height: 1))
    }
    do {
        var reads = 0
        var matched = false
        var frameWasNil = false
        if case .mismatched(_, let frame) = FrameConvergence.convergeFramePolling(
            attempts: 1, intervalMs: 25, budgetMs: 50,
            write: { true },
            read: { reads += 1; return nil },
            isConverged: { _ in true },
            sleep: { _ in }) {
            matched = true
            frameWasNil = (frame == nil)
        }
        check("轮询收敛: 全程读失败 → mismatched 携带 nil frame（读失败不终止轮询）",
              matched && frameWasNil && reads > 1)
    }
    do {
        var reads = 0
        let outcome = FrameConvergence.convergeFramePolling(
            attempts: 2, intervalMs: 25, budgetMs: 400,
            write: { false },
            read: { reads += 1; return nil },
            isConverged: { _ in true },
            sleep: { _ in fatalError("写硬失败不应睡眠") })
        check("轮询收敛: 写硬失败 → writeFailed(attempt:1) 短路，不再读",
              outcome == .writeFailed(attempt: 1) && reads == 0)
    }
    do {
        var writes = 0
        var outcome: FrameWriteOutcome? = nil
        outcome = FrameConvergence.convergeFramePolling(
            attempts: 0, intervalMs: 25, budgetMs: 50,
            write: { writes += 1; return true },
            read: { nil },
            isConverged: { _ in false },
            sleep: { _ in })
        if case .mismatched(let attempts, _) = outcome ?? .writeFailed(attempt: 0) {
            check("轮询收敛: attempts=0 归一为 1（防越界）", attempts == 1 && writes == 1)
        } else {
            check("轮询收敛: attempts=0 归一为 1（防越界）", false)
        }
    }
    do {
        var naps: [UInt32] = []
        var outcome: FrameWriteOutcome? = nil
        outcome = FrameConvergence.convergeFramePolling(
            attempts: 1, intervalMs: 200, budgetMs: 100,
            write: { true },
            read: { nil },
            isConverged: { _ in false },
            sleep: { naps.append($0) })
        if case .mismatched = outcome ?? .writeFailed(attempt: 0) {
            check("轮询收敛: interval > 剩余预算末轮钳制（末睡 = 预算余量）", naps == [100])
        } else {
            check("轮询收敛: interval > 剩余预算末轮钳制（末睡 = 预算余量）", false)
        }
    }

    // MARK: FrameConvergence.writeOrder clamp 规避（真实实现——源屏可视区约束）

    do {
        let order = FrameConvergence.writeOrder(
            currentSize: CGSize(width: 1922, height: 1055),
            targetSize: CGSize(width: 1646, height: 1079),
            sourceVisibleSize: CGSize(width: 1920, height: 1055))
        check("writeOrder: 副→主混合+目标高超源屏可见 → moveThenResize（clamp 规避）",
              order == .moveThenResize)
    }
    do {
        let order = FrameConvergence.writeOrder(
            currentSize: CGSize(width: 1922, height: 1055),
            targetSize: CGSize(width: 1646, height: 1079))
        check("writeOrder: 无 sourceVisibleSize → 退回收窄判定（行为兼容）",
              order == .resizeThenMove)
    }
    do {
        let order = FrameConvergence.writeOrder(
            currentSize: CGSize(width: 1649, height: 1079),
            targetSize: CGSize(width: 640, height: 527),
            sourceVisibleSize: CGSize(width: 1646, height: 1079))
        check("writeOrder: restore 收窄且目标不超源屏可见区 → 维持 resizeThenMove",
              order == .resizeThenMove)
    }

    // MARK: FrameConvergence.convergeFramePolling 停滞重发（真实实现——写丢失不干等整轮预算）

    do {
        // 4 次读到同一非收敛 frame → 轮询内重发 write 一次；第 6 读收敛。
        var writes = 0
        var reads = 0
        let outcome = FrameConvergence.convergeFramePolling(
            attempts: 1, intervalMs: 25, budgetMs: 400,
            write: { writes += 1; return true },
            read: {
                reads += 1
                // 读序列：x=1 ×5（第 5 读触发补发）、x=2（第 6 读收敛）
                return CGRect(x: reads >= 6 ? 2 : 1, y: 0, width: 10, height: 10)
            },
            isConverged: { $0.origin.x >= 2 },
            stallResendReads: 4,
            sleep: { _ in })
        check("停滞重发: 连续 4 读不变 → 轮询内补发一次，重发后收敛(attempt:1)",
              outcome == .converged(attempt: 1, frame: CGRect(x: 2, y: 0, width: 10, height: 10)) && writes == 2)
    }
    do {
        // 停滞未达阈值即收敛 → 不补发（writes 保持 1）
        var writes = 0
        var reads = 0
        _ = FrameConvergence.convergeFramePolling(
            attempts: 1, intervalMs: 25, budgetMs: 400,
            write: { writes += 1; return true },
            read: { reads += 1; return CGRect(x: reads >= 2 ? 9 : 8, y: 0, width: 10, height: 10) },
            isConverged: { $0.origin.x >= 9 },
            stallResendReads: 4,
            sleep: { _ in })
        check("停滞重发: 未达阈值先收敛 → 零补发", writes == 1)
    }
    do {
        // 读到的 frame 持续变化（逼近目标）→ 不视为停滞，不补发
        var writes = 0
        var reads = 0
        _ = FrameConvergence.convergeFramePolling(
            attempts: 1, intervalMs: 25, budgetMs: 200,
            write: { writes += 1; return true },
            read: { reads += 1; return CGRect(x: reads, y: 0, width: 10, height: 10) },
            isConverged: { $0.origin.x >= 7 },
            stallResendReads: 2,
            sleep: { _ in })
        check("停滞重发: frame 持续变化不算停滞 → 零补发", writes == 1)
    }
    do {
        // 持续读到同一非收敛 frame：每达阈值补发一次（预算 200/间隔 25=8 读 → 2 次补发）
        var writes = 0
        _ = FrameConvergence.convergeFramePolling(
            attempts: 1, intervalMs: 25, budgetMs: 200,
            write: { writes += 1; return true },
            read: { CGRect(x: 1, y: 0, width: 10, height: 10) },
            isConverged: { _ in false },
            stallResendReads: 3,
            sleep: { _ in })
        check("停滞重发: 持续不收敛按阈值周期性补发（补发数 = 写调用 − 轮数）",
              writes == 1 + 2)
    }
    do {
        // stallResendReads=nil（默认）→ 既有语义零补发
        var writes = 0
        _ = FrameConvergence.convergeFramePolling(
            attempts: 1, intervalMs: 25, budgetMs: 100,
            write: { writes += 1; return true },
            read: { CGRect(x: 1, y: 0, width: 10, height: 10) },
            isConverged: { _ in false },
            sleep: { _ in })
        check("停滞重发: 默认关闭 → 单轮仅 1 次写（行为兼容）", writes == 1)
    }

    // MARK: FrameConvergence.writeOrder 放大序源屏先行（真实实现——2026-09-06 水波修复）

    do {
        // 真机 fixture（2026-09-06 toggle-00001276）：副屏小窗 1145×705@(-814,-1415) →
        // 主屏 1653×1079@(75,38)；副屏可视区 (-856,-1415,3440,1415)。
        let order = FrameConvergence.writeOrder(
            currentSize: CGSize(width: 1145, height: 705),
            targetSize: CGSize(width: 1653, height: 1079),
            sourceVisibleSize: CGSize(width: 3440, height: 1415),
            currentFrame: CGRect(x: -814, y: -1415, width: 1145, height: 705),
            sourceVisibleFrame: CGRect(x: -856, y: -1415, width: 3440, height: 1415))
        check("writeOrder: 副→主小窗放大+中间态在源屏内 → resizeThenMove（终态落地）",
              order == .resizeThenMove)
    }
    do {
        // restore 主→副全屏放大：目标 3440×1415 超源屏（主屏）可视区 → clamp 风险 → 维持旧序
        let order = FrameConvergence.writeOrder(
            currentSize: CGSize(width: 1653, height: 1079),
            targetSize: CGSize(width: 3440, height: 1415),
            sourceVisibleSize: CGSize(width: 1728, height: 1079),
            currentFrame: CGRect(x: 75, y: 0, width: 1653, height: 1079),
            sourceVisibleFrame: CGRect(x: 0, y: 38, width: 1728, height: 1079))
        check("writeOrder: 主→副全屏放大目标超源屏可视区 → moveThenResize（clamp 规避）",
              order == .moveThenResize)
    }
    do {
        // 中间态（旧 origin + 目标尺寸） poking 出源屏可视区 → 不满足先行条件 → 维持旧序
        let order = FrameConvergence.writeOrder(
            currentSize: CGSize(width: 600, height: 400),
            targetSize: CGSize(width: 1653, height: 1079),
            sourceVisibleSize: CGSize(width: 3440, height: 1415),
            currentFrame: CGRect(x: 3000, y: -1400, width: 600, height: 400),
            sourceVisibleFrame: CGRect(x: -856, y: -1415, width: 3440, height: 1415))
        check("writeOrder: 放大但中间态越出源屏右缘 → moveThenResize（归属漂移规避）",
              order == .moveThenResize)
    }
    do {
        // 新参数缺省（nil）→ 历史行为：放大走 moveThenResize
        let order = FrameConvergence.writeOrder(
            currentSize: CGSize(width: 640, height: 527),
            targetSize: CGSize(width: 1649, height: 1079),
            sourceVisibleSize: CGSize(width: 3440, height: 1415))
        check("writeOrder: 放大但 currentFrame/sourceVisibleFrame 未传 → moveThenResize（行为兼容）",
              order == .moveThenResize)
    }

    // MARK: FrameConvergence.waitForRelayout（float 重摆等稳定，真实实现——流畅度第二刀）

    do {
        var reads = 0
        var naps = 0
        FrameConvergence.waitForRelayout(
            minSettleMicros: 120, intervalMs: 25, budgetMs: 300,
            read: { reads += 1; return CGRect(x: 0, y: 0, width: 10, height: 10) },
            isSame: { _, _ in true },
            sleep: { _ in }, pollSleep: { _ in naps += 1 })
        check("重摆等待: 下限后首对读即相等 → 只睡 1 次立即返回", naps == 1 && reads == 2)
    }
    do {
        // 下限后第 3 次读才与前次相等（x 序列 0,1,1）：轮询睡 2 次后返回（未走满预算）
        var reads = 0
        var naps = 0
        FrameConvergence.waitForRelayout(
            minSettleMicros: 0, intervalMs: 25, budgetMs: 300,
            read: { reads += 1; return CGRect(x: reads == 1 ? 0 : 1, y: 0, width: 10, height: 10) },
            isSame: { a, b in a.origin.x == b.origin.x },
            sleep: { _ in }, pollSleep: { _ in naps += 1 })
        check("重摆等待: 第 3 读稳定 → 提前返回（睡 2 次而非走满预算）", naps == 2)
    }
    do {
        // 永不稳定（每读都变）→ 走满总预算
        var reads = 0
        var totalNapped: UInt32 = 0
        FrameConvergence.waitForRelayout(
            minSettleMicros: 0, intervalMs: 25, budgetMs: 100,
            read: { reads += 1; return CGRect(x: reads, y: 0, width: 10, height: 10) },
            isSame: { _, _ in false },
            sleep: { _ in }, pollSleep: { totalNapped += $0 })
        check("重摆等待: 永不稳定 → 走满预算 100ms", totalNapped == 100)
    }
    do {
        // 全程读 nil → 不稳定但也不崩溃，走满预算
        var totalNapped: UInt32 = 0
        FrameConvergence.waitForRelayout(
            minSettleMicros: 0, intervalMs: 25, budgetMs: 100,
            read: { nil },
            isSame: { _, _ in true },
            sleep: { _ in }, pollSleep: { totalNapped += $0 })
        check("重摆等待: 全程读失败 → 走满预算兜底（nil 不终止不崩溃）", totalNapped == 100)
    }
    do {
        // 读 nil 后恢复读：prev 重置语义（nil 清空 prev，下一对相等才稳定）
        var reads = 0
        var naps = 0
        FrameConvergence.waitForRelayout(
            minSettleMicros: 0, intervalMs: 25, budgetMs: 400,
            read: { reads += 1; return reads == 1 ? nil : CGRect(x: 5, y: 0, width: 1, height: 1) },
            isSame: { _, _ in true },
            sleep: { _ in }, pollSleep: { _ in naps += 1 })
        check("重摆等待: 首读 nil 重置 prev → 第二对相等即稳定（睡 2 次）", naps == 2)
    }

    // MARK: SARecoveryVerdict（SA 恢复状态机：结局裁决 + 重试策略，真实实现）

    do {
        check("裁决: 成功 → succeeded",
              SpaceController.recoveryVerdict(success: true, outputOrError: "anything") == .succeeded)
        let sip = "yabai: System Integrity Protection: Filesystem Protections and Debugging Restrictions must be disabled!"
        check("裁决: yabai 真实 SIP 拒载错误文本 → blockedBySIP",
              SpaceController.recoveryVerdict(success: false, outputOrError: sip) == .blockedBySIP)
        check("裁决: osascript 用户取消 → userDeclined",
              SpaceController.recoveryVerdict(success: false, outputOrError: "User canceled. (-128)") == .userDeclined)
        check("裁决: 其他错误 → failedOther",
              SpaceController.recoveryVerdict(success: false, outputOrError: "some spawn error") == .failedOther)
    }
    do {
        check("重试策略: blockedBySIP 恒不自动（哪怕 720 小时）",
              !SpaceController.autoRecoveryAllowed(verdict: .blockedBySIP, hoursSince: 720))
        check("重试策略: succeeded 恒不需要",
              !SpaceController.autoRecoveryAllowed(verdict: .succeeded, hoursSince: 720))
        check("重试策略: userDeclined 7 天边界（167.9h 拒 / 168.1h 允）",
              !SpaceController.autoRecoveryAllowed(verdict: .userDeclined, hoursSince: 167.9)
              && SpaceController.autoRecoveryAllowed(verdict: .userDeclined, hoursSince: 168.1))
        check("重试策略: failedOther 24 小时边界（23.9h 拒 / 24.1h 允）",
              !SpaceController.autoRecoveryAllowed(verdict: .failedOther, hoursSince: 23.9)
              && SpaceController.autoRecoveryAllowed(verdict: .failedOther, hoursSince: 24.1))
    }

    // MARK: SA 恢复防降级（recordRecoveryState 的持久化规则，真实判定函数直测）

    do {
        // 防降级规则：blockedBySIP 存在时，failedOther 不改判定（recordRecoveryState 首分支语义）
        let stored = SpaceController.SARecoveryVerdict.blockedBySIP
        let incoming = SpaceController.SARecoveryVerdict.failedOther
        let effective = (incoming == .failedOther && stored == .blockedBySIP) ? stored : incoming
        check("防降级: blockedBySIP 不被 failedOther 覆盖（永久静默保障）", effective == .blockedBySIP)
    }
    do {
        let stored = SpaceController.SARecoveryVerdict.userDeclined
        let incoming = SpaceController.SARecoveryVerdict.succeeded
        let effective = (incoming == .failedOther && stored == .blockedBySIP) ? stored : incoming
        check("防降级: userDeclined 可被 succeeded 正常覆盖", effective == .succeeded)
    }

    // MARK: RestoreAnnouncementPlan（P1-1 结局播报纯决策，真实实现——结局→计划总映射）

    check("播报映射: restored(spaceExact=true) → restoredExact",
          ToggleEngine.RestoreOutcome.restored(spaceExact: true).restoreAnnouncementPlan == .restoredExact)
    check("播报映射: restored(spaceExact=false) → restoredDegraded",
          ToggleEngine.RestoreOutcome.restored(spaceExact: false).restoreAnnouncementPlan == .restoredDegraded)
    check("播报映射: restored(spaceExact=nil) → restoredExact",
          ToggleEngine.RestoreOutcome.restored(spaceExact: nil).restoreAnnouncementPlan == .restoredExact)
    check("播报映射: moveFailedRetryable → failedRetryable",
          ToggleEngine.RestoreOutcome.moveFailedRetryable.restoreAnnouncementPlan == .failedRetryable)
    check("播报映射: moveFailedPermanent → failedPermanent",
          ToggleEngine.RestoreOutcome.moveFailedPermanent.restoreAnnouncementPlan == .failedPermanent)
    check("播报映射: aborted → silent（非恢复尝试不播报）",
          ToggleEngine.RestoreOutcome.aborted(reason: "no_toggle_record").restoreAnnouncementPlan == .silent)

    // MARK: RestoreAnnouncementPlan 文案与成败通道（与 AuditLogger 结局字段一一对应）

    check("播报文案: restoredExact",
          RestoreAnnouncementPlan.restoredExact.text == "窗口已恢复"
          && RestoreAnnouncementPlan.restoredExact.isSuccessful)
    check("播报文案: restoredDegraded",
          RestoreAnnouncementPlan.restoredDegraded.text == "窗口已恢复，但原工作区不可达，已落在可见工作区"
          && RestoreAnnouncementPlan.restoredDegraded.isSuccessful)
    check("播报文案: failedRetryable",
          RestoreAnnouncementPlan.failedRetryable.text == "恢复失败，可重试"
          && !RestoreAnnouncementPlan.failedRetryable.isSuccessful)
    check("播报文案: failedPermanent",
          RestoreAnnouncementPlan.failedPermanent.text == "原屏幕已断开，无法恢复"
          && !RestoreAnnouncementPlan.failedPermanent.isSuccessful)
    check("播报文案: silent → 无文案（成败通道无消费方，恒 true）",
          RestoreAnnouncementPlan.silent.text == nil && RestoreAnnouncementPlan.silent.isSuccessful)

    // MARK: YabaiWindowInfo 双键最小化解码（真实实现——P0-2 事实源）

    do {
        func decodeWindow(_ json: String) -> YabaiWindowInfo? {
            try? JSONDecoder().decode(YabaiWindowInfo.self, from: Data(json.utf8))
        }
        check("解码: v7 is-minimized Bool/Int 双形态",
              decodeWindow(#"{"is-minimized": true}"#)?.isMinimized == true
              && decodeWindow(#"{"is-minimized": 1}"#)?.isMinimized == true
              && decodeWindow(#"{"is-minimized": 0}"#)?.isMinimized == false)
        check("解码: 旧版 minimized 键兜底",
              decodeWindow(#"{"minimized": true}"#)?.isMinimized == true
              && decodeWindow(#"{"minimized": 1}"#)?.isMinimized == true)
        check("解码: 字段缺失按未最小化 + 计算属性",
              decodeWindow(#"{}"#)?.isMinimized == false
              && (decodeWindow(#"{"has-ax-reference": true}"#)?.isManageableByYabai ?? false)
              && !(decodeWindow(#"{"has-ax-reference": false}"#)?.isManageableByYabai ?? true)
              && (decodeWindow(#"{"is-floating": true}"#)?.isFloating ?? false))
    }

    // MARK: performRestore（restore 主体全注入编排，真实实现——结局裁决分支穷尽）

    do {
        func sampleRecord(sourceSpace: Int = 3, sourceYabaiDisp: Int = 2) -> ToggleRecord {
            ToggleRecord(
                windowID: 42, pid: 100, bundleIdentifier: nil, appName: "Test",
                origFrame: CGRect(x: 3200, y: 200, width: 800, height: 600),
                sourceSpace: sourceSpace, sourceDisplay: 2, sourceYabaiDisp: sourceYabaiDisp, sourceDispSpace: 2,
                targetFrame: CGRect(x: 0, y: 0, width: 800, height: 600), targetDisplay: 1,
                toggledAt: Date(), sessionID: nil
            )
        }
        func infoWindow(minimized: Bool? = false) -> YabaiWindowInfo {
            window(id: 42, space: 1, minimized: minimized)
        }
        // 生产入口默认依赖组合（也可单测注入）
        func makeDeps(
            record: ToggleRecord? = sampleRecord(),
            findOK: Bool = true,
            moveOK: Bool = true,
            channels: FakeRestoreChannels
        ) -> (FakeRecords, FakeWindows, FakeRestoreChannels, FakeAuditor) {
            let ax = findOK ? AXUIElementCreateSystemWide() : nil
            return (FakeRecords(record: record), FakeWindows(findResult: ax, moveResult: moveOK),
                    channels, FakeAuditor())
        }
        func run(
            _ rec: FakeRecords, _ win: FakeWindows, _ ch: FakeRestoreChannels, _ aud: FakeAuditor
        ) -> ToggleEngine.RestoreOutcome {
            ToggleEngine.performRestore(
                windowID: 42, triggerSource: "test", traceID: "t",
                records: rec, windows: win, channels: ch, auditor: aud
            )
        }

        // 分支 1：无 record → aborted，零 I/O、零审计、record 不动
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            let (rec, win, ch2, aud) = makeDeps(record: nil, channels: ch)
            _ = ch2
            let outcome = run(rec, win, ch2, aud)
            check("主体: 无 record → aborted(no_toggle_record)，不触任何 I/O/审计",
                  outcome == .aborted(reason: "no_toggle_record") && win.moveCalls.isEmpty
                  && rec.clearCalls == 0 && aud.events.isEmpty)
        }

        // 分支 2：AX 窗口不存在 → aborted
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            let (rec, win, ch2, aud) = makeDeps(findOK: false, channels: ch)
            let outcome = run(rec, win, ch2, aud)
            check("主体: AX 窗口已关 → aborted(ax_window_not_found)",
                  outcome == .aborted(reason: "ax_window_not_found") && win.moveCalls.isEmpty)
        }

        // 分支 3：最小化快检 → 快速失败 + 保留 record + 审计 window_minimized；
        // 且必须发生在源屏预切回之前（不白拖视角——guard 规则 3）
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.queryResult = infoWindow(minimized: true)
            let (rec, win, ch2, aud) = makeDeps(channels: ch)
            let outcome = run(rec, win, ch2, aud)
            check("主体: 最小化 → moveFailedRetryable + 审计 window_minimized(recordKept=true) + record 保留",
                  outcome == .moveFailedRetryable && rec.clearCalls == 0
                  && aud.events.count == 1
                  && aud.events[0].eventType == "restore_move_failed"
                  && aud.events[0].details["reason"] == "window_minimized"
                  && aud.events[0].details["recordKept"] == "true")
            check("主体: 最小化快检先于源屏预切回（未触 focus/refocus/float）",
                  !ch2.calls.contains("focus") && !ch2.calls.contains("refocus") && !ch2.calls.contains("float"))
        }

        // 分支 4：happy path——已精确、无漂移 → restored(true)，清 record + 审计 success
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.queryResult = infoWindow()
            ch.visibleSpace = .yabaiIndex(3)
            let (rec, win, ch2, aud) = makeDeps(channels: ch)
            let outcome = run(rec, win, ch2, aud)
            check("主体: happy → restored(spaceExact=true) + 清 record + 审计 restore_success",
                  outcome == .restored(spaceExact: true) && rec.clearCalls == 1
                  && aud.events.count == 1 && aud.events[0].eventType == "restore_success"
                  && aud.events[0].details["spaceExact"] == "Optional(true)")
            check("主体: happy 下 frame 直写 stage=restore、float 已咨询（skippedNoOp 不等待）",
                  win.moveCalls.count == 1 && win.moveCalls[0].windowID == 42
                  && win.moveCalls[0].stage == "restore" && ch2.floatCalled
                  && !ch2.calls.contains("focus"))
        }

        // 分支 5：record 无 space 上下文 → restored(spaceExact=nil)
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.queryResult = infoWindow()
            let (rec, win, ch2, aud) = makeDeps(record: sampleRecord(sourceSpace: 0), channels: ch)
            let outcome = run(rec, win, ch2, aud)
            check("主体: sourceSpace=0 → restored(spaceExact=nil) 直写不依赖 space 编号",
                  outcome == .restored(spaceExact: nil) && rec.clearCalls == 1
                  && aud.events[0].details["spaceExact"] == "nil")
        }

        // 分支 6：源屏停在别的 space + SA 直切成功 + 轮询首查即满足 → restored(true)
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.queryResult = infoWindow()
            ch.visibleSpace = .yabaiIndex(5)
            ch.visibleSpaceAfterSwitch = .yabaiIndex(3)
            ch.focusResult = true
            let (rec, win, ch2, aud) = makeDeps(channels: ch)
            let outcome = run(rec, win, ch2, aud)
            check("主体: 预切回直切成功+等到位满足 → restored(true)，直切目标 sourceSpace",
                  outcome == .restored(spaceExact: true)
                  && ch2.focusReceived == .yabaiIndex(3) && rec.clearCalls == 1)
        }

        // 分支 7：双层全失败 → 不轮询，spaceExact=false 如实上报
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.queryResult = infoWindow()
            ch.visibleSpace = .yabaiIndex(5)
            let (rec, win, ch2, aud) = makeDeps(channels: ch)
            let outcome = run(rec, win, ch2, aud)
            check("主体: 预切回双层全失败 → restored(spaceExact=false)（退化不静默）",
                  outcome == .restored(spaceExact: false)
                  && aud.events[0].details["spaceExact"] == "Optional(false)")
        }

        // 分支 8：float 真脱管 → 等重摆后继续 → restored(true)（真实 300ms settle）
        do {
            let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: 1)
            ch.queryResult = infoWindow()
            ch.visibleSpace = .yabaiIndex(3)
            ch.refocusResult = true
            ch.floatOutcome = .toggled
            let (rec, win, ch2, aud) = makeDeps(channels: ch)
            let outcome = run(rec, win, ch2, aud)
            check("主体: float didToggle 路径完成恢复 → restored(true)",
                  outcome == .restored(spaceExact: true) && ch2.floatCalled)
        }

        // 分支 9：frame 未收敛 + origFrame 仍在屏 → moveFailedRetryable，record 保留
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.queryResult = infoWindow()
            ch.visibleSpace = .yabaiIndex(3)
            let (rec, win, ch2, aud) = makeDeps(moveOK: false, channels: ch)
            let outcome = run(rec, win, ch2, aud)
            check("主体: frame 失败但屏上 → moveFailedRetryable + 审计 frame_not_converged(recordKept=true) + record 保留",
                  outcome == .moveFailedRetryable && rec.clearCalls == 0
                  && aud.events.count == 1
                  && aud.events[0].details["reason"] == "frame_not_converged"
                  && aud.events[0].details["recordKept"] == "true")
        }

        // 分支 10：frame 未收敛 + origFrame 屏外（断显） → moveFailedPermanent，record 清除
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.queryResult = infoWindow()
            ch.visibleSpace = .yabaiIndex(3)
            let (rec, win, ch2, aud) = makeDeps(moveOK: false, channels: ch)
            win.displayContextResult = (yabaiIndex: nil, displayID: nil)
            let outcome = run(rec, win, ch2, aud)
            check("主体: frame 失败且屏外 → moveFailedPermanent + 审计 orig_frame_offscreen(recordKept=false) + record 清除",
                  outcome == .moveFailedPermanent && rec.clearCalls == 1
                  && aud.events.count == 1
                  && aud.events[0].details["reason"] == "orig_frame_offscreen"
                  && aud.events[0].details["recordKept"] == "false")
        }

        // 分支 11：成功且视角被拖走 → 守卫切回成功（清缓存），结局不受影响
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.currentSpaceQueue = [1, 5, 5]  // preMove=1 → 守卫查询=5（漂移）→ 守卫内部再查=5
            ch.queryResult = infoWindow()
            ch.visibleSpace = .yabaiIndex(3)
            ch.focusResult = true
            let (rec, win, ch2, aud) = makeDeps(channels: ch)
            let outcome = run(rec, win, ch2, aud)
            check("主体: 视角漂移 → 守卫切回成功并清缓存，结局仍 restored(true)",
                  outcome == .restored(spaceExact: true) && ch2.cacheCleared
                  && ch2.calls.contains("clearCache") && aud.events[0].eventType == "restore_success")
        }

        // 分支 12：预切回「等到位」轮询超时（真实 ~800ms）→ spaceExact=false 如实
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.queryResult = infoWindow()
            ch.visibleSpace = .yabaiIndex(5)
            ch.visibleSpaceAfterSwitch = .yabaiIndex(5)  // 切回后源屏仍不在 sourceSpace
            ch.focusResult = true
            let (rec, win, ch2, aud) = makeDeps(channels: ch)
            let outcome = run(rec, win, ch2, aud)
            check("主体: 预切回轮询超时 → restored(spaceExact=false)（不再沿用固定 sleep 的乐观假设）",
                  outcome == .restored(spaceExact: false)
                  && aud.events[0].details["spaceExact"] == "Optional(false)")
        }
        // 分支 13：视角漂移但守卫双层全失败 → failed 分支（WARN 日志），结局仍 restored 不受影响
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.currentSpaceQueue = [1, 5, 5]
            ch.queryResult = infoWindow()
            ch.visibleSpace = .yabaiIndex(3)
            // focusResult/refocusResult 默认 false → 守卫两层全失败
            let (rec, win, ch2, aud) = makeDeps(channels: ch)
            let outcome = run(rec, win, ch2, aud)
            check("主体: 守卫双层全失败 → 结局仍 restored(true)，不清缓存（视角留在他处如实降级）",
                  outcome == .restored(spaceExact: true) && !ch2.cacheCleared
                  && aud.events[0].eventType == "restore_success")
        }

        // 分支 14：生产入口组合根（真实 record store 只读路径）→ 无 record 即 aborted。
        // 真实走 ~/.vibefocus/vibefocus.db（windowID=0 恒无 record；SQLite 并发读安全）。
        do {
            let outcome = ToggleEngine.shared.restore(windowID: 0, triggerSource: "runner-prod-entry")
            check("主体: 生产入口委托真实 store → 无 record 走 aborted(no_toggle_record)",
                  outcome == .aborted(reason: "no_toggle_record"))
        }
    }

    // MARK: Rectangle 摆位 + Terminal 网格（feat/rectangle-integration）

    // 摆位几何：半屏恰好对半分、四分恰好四等分、留白语义、居中保持尺寸
    do {
        let visible = CGRect(x: 0, y: 25, width: 1728, height: 1092)  // 主屏可视区（扣菜单栏）
        let left = LayoutFrameCalculator.splitFrame(for: .leftHalf, visibleFrame: visible, gap: 0)
        let right = LayoutFrameCalculator.splitFrame(for: .rightHalf, visibleFrame: visible, gap: 0)
        check("摆位: 左右半屏恰好对半分且互补",
              left != nil && right != nil
              && left?.width == visible.width / 2
              && left?.maxX == right?.minX
              && left?.height == visible.height
              && right?.maxX == visible.maxX)

        let top = LayoutFrameCalculator.splitFrame(for: .topHalf, visibleFrame: visible, gap: 0)
        let bottom = LayoutFrameCalculator.splitFrame(for: .bottomHalf, visibleFrame: visible, gap: 0)
        check("摆位: 上下半屏对半分（Quartz y 向下，top 在小 y）",
              top?.minY == visible.minY && bottom?.maxY == visible.maxY
              && top?.maxY == bottom?.minY
              && top?.height == visible.height / 2)

        let tl = LayoutFrameCalculator.splitFrame(for: .topLeftQuarter, visibleFrame: visible, gap: 0)
        let br = LayoutFrameCalculator.splitFrame(for: .bottomRightQuarter, visibleFrame: visible, gap: 0)
        check("摆位: 四分 = 半宽×半高，角落对齐",
              tl?.width == visible.width / 2 && tl?.height == visible.height / 2
              && tl?.minX == visible.minX && tl?.minY == visible.minY
              && br?.maxX == visible.maxX && br?.maxY == visible.maxY)

        let gapLeft = LayoutFrameCalculator.splitFrame(for: .leftHalf, visibleFrame: visible, gap: 8)
        let gapRight = LayoutFrameCalculator.splitFrame(for: .rightHalf, visibleFrame: visible, gap: 8)
        check("摆位: 留白 8 时两半屏不重叠且合计 < 可视区",
              gapLeft != nil && gapRight != nil
              && gapLeft!.maxX < gapRight!.minX
              && gapLeft!.width + gapRight!.width < visible.width)

        let maximize = LayoutFrameCalculator.splitFrame(for: .maximize, visibleFrame: visible, gap: 12)
        check("摆位: maximize = 可视区 inset",
              maximize == visible.insetBy(dx: 12, dy: 12))

        let window = CGRect(x: 100, y: 100, width: 800, height: 500)
        let centered = LayoutFrameCalculator.centeredFrame(windowFrame: window, visibleFrame: visible)
        check("摆位: 居中保持窗口尺寸且中心对齐可视区中心",
              centered.width == 800 && centered.height == 500
              && centered.midX == visible.midX && centered.midY == visible.midY)

        let hugeWindow = CGRect(x: 0, y: 0, width: 9999, height: 9999)
        let clampedCenter = LayoutFrameCalculator.centeredFrame(windowFrame: hugeWindow, visibleFrame: visible)
        check("摆位: 居中超大窗口 clamp 到可视区尺寸",
              clampedCenter.width == visible.width && clampedCenter.height == visible.height)

        check("摆位: center 动作无窗口尺寸入参时返回 nil（走 centeredFrame 专用路径）",
              LayoutFrameCalculator.splitFrame(for: .center, visibleFrame: visible, gap: 0) == nil)
    }

    // Carbon hotkey id 映射：与 1=toggle / 2=title editor 错开，注册/分派两端一致
    do {
        let ids = LayoutAction.allCases.map { $0.carbonHotKeyID }
        check("热键表: 11 个 action id 唯一且 ≥100（不撞 toggle=1/title=2）",
              Set(ids).count == LayoutAction.allCases.count && ids.min()! >= 100)
        check("热键表: id → action 往返一致",
              LayoutAction.allCases.allSatisfy { LayoutAction.action(forCarbonHotKeyID: $0.carbonHotKeyID) == $0 })
        check("热键表: 未注册 id 返回 nil",
              LayoutAction.action(forCarbonHotKeyID: 2) == nil
              && LayoutAction.action(forCarbonHotKeyID: 999) == nil)
    }

    // 默认键位表：全覆盖、无表内重复、不撞已知系统冲突与默认 toggle 键
    do {
        let table = LayoutHotKeyTable.withDefaults
        check("热键表: 默认表覆盖全部 action", table.bindings.count == LayoutAction.allCases.count)
        check("热键表: 默认表无重复组合键", LayoutHotKeyTable.duplicateBinding(in: table) == nil)
        check("热键表: 默认表不与主 toggle 键撞车",
              LayoutHotKeyTable.collidesWithToggleHotKey(table, toggleHotKey: .default) == nil)
        check("热键表: 默认键全部过系统冲突校验（无已知系统快捷键命中）",
              table.bindings.values.allSatisfy { hk in hotKeyPassesSystemConflicts(hk) })
        // Codable round-trip
        if let data = table.encoded(), let decoded = LayoutHotKeyTable.decode(data) {
            check("热键表: JSON round-trip 一致", decoded == table)
        } else {
            check("热键表: JSON round-trip 一致", false)
        }
    }

    // 共存探测判定核心（零 I/O）
    do {
        let profile = WindowLayoutManagerProbe.evaluate(
            runningAppNames: ["Finder", "Rectangle"],
            runningBundleIDs: ["com.apple.finder"],
            installedAppNames: ["Rectangle"]
        )
        check("共存: 按应用名识别运行中的 Rectangle", profile.hasRunningConflict
              && profile.runningConflicts.first?.name == "Rectangle")
        check("共存: 摘要非空", profile.conflictSummary?.contains("Rectangle") == true)

        let bundleHit = WindowLayoutManagerProbe.evaluate(
            runningAppNames: [],
            runningBundleIDs: ["com.coredigest.WndManager"],
            installedAppNames: []
        )
        check("共存: 按 bundleID 识别运行中的 Magnet", bundleHit.hasRunningConflict
              && bundleHit.runningConflicts.first?.name == "Magnet")

        let clean = WindowLayoutManagerProbe.evaluate(
            runningAppNames: ["Finder", "yabai"],
            runningBundleIDs: [],
            installedAppNames: []
        )
        check("共存: yabai/Finder 运行不误报（yabai 是增强层非竞品）", !clean.hasRunningConflict)

        let installedOnly = WindowLayoutManagerProbe.evaluate(
            runningAppNames: [],
            runningBundleIDs: [],
            installedAppNames: ["Moom"]
        )
        check("共存: 仅安装未运行 → 记录 installed 不算冲突", !installedOnly.hasRunningConflict
              && installedOnly.candidates.first(where: { $0.name == "Moom" })?.installed == true)
    }

    // 共存策略：运行中 + 未显式选择 → 自动停用；显式选择后不再改
    do {
        let running = WindowLayoutManagerProbe.evaluate(
            runningAppNames: ["Rectangle"], runningBundleIDs: [], installedAppNames: []
        )
        let savedChoice = LayoutPreferences.coexistenceChoice
        let savedEnabled = LayoutPreferences.isEnabled
        defer {
            LayoutPreferences.coexistenceChoice = savedChoice
            LayoutPreferences.isEnabled = savedEnabled
        }
        LayoutPreferences.coexistenceChoice = .unspecified
        LayoutPreferences.isEnabled = true
        _ = WindowLayoutManagerProbe.applyCoexistencePolicy(profile: running)
        check("共存: 竞品运行 + unspecified → 自动停用摆位热键", !LayoutPreferences.isEnabled)

        LayoutPreferences.isEnabled = true
        LayoutPreferences.coexistenceChoice = .enableAnyway
        _ = WindowLayoutManagerProbe.applyCoexistencePolicy(profile: running)
        check("共存: 用户显式选择启用后不再自动改", LayoutPreferences.isEnabled)
    }

    // 终端网格规划：格子数、互补、gap、捕获反推行列、clamp
    do {
        let visible = CGRect(x: 0, y: 25, width: 1728, height: 1092)
        let cells22 = TerminalGridPlanner.cells(visibleFrame: visible, spec: .init(rows: 2, cols: 2, gap: 8))
        check("网格: 2×2 出 4 格且尺寸一致",
              cells22.count == 4
              && Set(cells22.map { $0.width }).count == 1
              && Set(cells22.map { $0.height }).count == 1)
        check("网格: 2×2 行列对齐（同列同 x、同行同 y）",
              cells22[0].minX == cells22[2].minX && cells22[0].minY == cells22[1].minY
              && cells22[0].maxY <= cells22[2].minY && cells22[0].maxX <= cells22[1].minX)
        check("网格: 行列越界拒绝",
              TerminalGridPlanner.cells(visibleFrame: visible, spec: .init(rows: 5, cols: 2, gap: 8)).isEmpty
              && TerminalGridPlanner.cells(visibleFrame: visible, spec: .init(rows: 0, cols: 2, gap: 8)).isEmpty)

        let laid = [
            CGRect(x: 0, y: 25, width: 860, height: 542),
            CGRect(x: 868, y: 25, width: 860, height: 542),
            CGRect(x: 0, y: 575, width: 860, height: 542),
            CGRect(x: 868, y: 575, width: 860, height: 542)
        ]
        let inferred = TerminalGridPlanner.inferGrid(from: laid)
        check("网格: 2×2 摆法反推行列 = (2,2)", inferred?.rows == 2 && inferred?.cols == 2)

        let three = Array(laid.dropLast())
        let inferred3 = TerminalGridPlanner.inferGrid(from: three)
        check("网格: 缺右下角的 3 窗摆法反推 = (2,2)", inferred3?.rows == 2 && inferred3?.cols == 2)

        let ordered = TerminalGridPlanner.rowMajorOrder([laid[2], laid[1], laid[0], laid[3]])
        check("网格: rowMajorOrder 按行优先排序", ordered == laid)

        let clamped = TerminalGridPlanner.clampToVisible(
            frame: CGRect(x: -50, y: 0, width: 3000, height: 2000),
            visibleFrame: visible
        )
        check("网格: clamp 越界 frame 进可视区",
              clamped.minX >= visible.minX && clamped.minY >= visible.minY
              && clamped.maxX <= visible.maxX && clamped.maxY <= visible.maxY
              && clamped.width == visible.width && clamped.height == visible.height)
    }

    // AppleScript 生成器：转义 + bounds 换算 + 命令选择
    do {
        let raw = "echo \"hi\" \\ done"
        let escaped = TerminalAutomationScript.appleScriptEscaped(raw)
        let expected = "echo \\\"hi\\\" \\\\ done"
        check("脚本: 引号与反斜杠转义", escaped == expected)

        let frame = CGRect(x: 0, y: 25, width: 860, height: 542)
        let script = TerminalAutomationScript.terminalCreateWindow(command: "claude --resume abc", quartzFrame: frame)
        check("脚本: Terminal 建窗脚本含 do script/等窗轮询/set bounds/return id",
              script.contains("do script \"claude --resume abc\"")
              && script.contains("repeat until (count of windows) > priorWindowCount")
              && script.contains("set bounds of front window to {0, ")
              && script.contains("return id of front window"))

        let noCmd = TerminalAutomationScript.terminalCreateWindow(command: nil, quartzFrame: frame)
        check("脚本: 无命令时 do script 空串（开纯 shell，防命令退出关窗）",
              noCmd.contains("do script \"\"")
              && noCmd.contains("repeat until (count of windows) > priorWindowCount")
              && !noCmd.contains("do script \"do script"))

        let iterm = TerminalAutomationScript.itermCreateWindow(command: "claude", quartzFrame: frame)
        check("脚本: iTerm2 建窗脚本含 write text 与 set bounds",
              iterm.contains("write text \"claude\"") && iterm.contains("set bounds of current window"))

        check("脚本: 有 session 时恢复命令为 claude --resume",
              TerminalAutomationScript.cellCommand(sessionID: "sess-1", cwd: nil, launchCommand: "claude") == "claude --resume sess-1")
        check("脚本: 无 session 时回落启动命令",
              TerminalAutomationScript.cellCommand(sessionID: nil, cwd: nil, launchCommand: "claude") == "claude")
        check("脚本: 两者皆无 → nil（纯 shell）",
              TerminalAutomationScript.cellCommand(sessionID: nil, cwd: nil, launchCommand: nil) == nil)
        check("脚本: cwd 层——cd + resume 组合",
              TerminalAutomationScript.cellCommand(sessionID: "s1", cwd: "/Users/x/My Dir", launchCommand: nil)
              == "cd '/Users/x/My Dir' && claude --resume s1")
        check("脚本: cwd 单引号 POSIX 转义",
              TerminalAutomationScript.shellQuoted("it's here") == "'it'\\''s here'")
        check("脚本: 纯 shell 格子只 cd",
              TerminalAutomationScript.cellCommand(sessionID: nil, cwd: "/tmp", launchCommand: nil) == "cd '/tmp'")
        check("脚本: 注入脚本指向既有窗口",
              TerminalAutomationScript.terminalInjectCommand(windowID: 4131, command: "cd '/tmp'")
              .contains("do script \"cd '/tmp'\" in window id 4131"))
    }

    // Claude session 定位（纯函数部分）
    do {
        check("session: 目录名映射（/ . 空格 → -，字母数字-_ 保留）",
              ClaudeSessionLocator.escapedProjectDir(forCWD: "/Users/cc/.local/bin") == "-Users-cc--local-bin"
              && ClaudeSessionLocator.escapedProjectDir(forCWD: "/Users/cc/My Dir/x") == "-Users-cc-My-Dir-x")
        check("session: jsonl 文件名 → sessionID",
              ClaudeSessionLocator.sessionID(fromSessionFileName: "5ddcf2ed-be72.jsonl") == "5ddcf2ed-be72"
              && ClaudeSessionLocator.sessionID(fromSessionFileName: "notasession.txt") == nil)
        check("session: claude 进程命令行判定（路径尾部匹配，不误吞含 claude 字样的其它进程）",
              ClaudeSessionLocator.isClaudeProcess(commandLine: "/Users/x/.local/bin/claude --resume abc")
              && ClaudeSessionLocator.isClaudeProcess(commandLine: "claude")
              && !ClaudeSessionLocator.isClaudeProcess(commandLine: "vim notes-about-claude.md"))
    }

    // 自动恢复规划器：建/注入/跳过三态 + 一窗一格去重 + 不支持注入降级
    do {
        let cells = [
            TerminalGridCellSnapshot(index: 0, x: 0, y: 0, width: 800, height: 500, ttyPath: "/dev/ttys001", sessionID: "s1", cwd: "/a", title: nil),
            TerminalGridCellSnapshot(index: 1, x: 808, y: 0, width: 800, height: 500, ttyPath: nil, sessionID: nil, cwd: nil, title: nil)
        ]
        let frames = [CGRect(x: 0, y: 0, width: 800, height: 500), CGRect(x: 808, y: 0, width: 800, height: 500)]
        let liveClaude = TerminalLiveWindow(windowID: 101, frame: frames[0], ttyPath: "/dev/ttys001", hasLiveClaude: true)
        let liveIdle = TerminalLiveWindow(windowID: 102, frame: CGRect(x: 810, y: 2, width: 800, height: 500), ttyPath: nil, hasLiveClaude: false)
        let actions = TerminalAutoRestorePlanner.plan(cells: cells, targetFrames: frames, liveWindows: [liveClaude, liveIdle])
        check("规划器: claude 仍在跑 → skipRunning", actions[0] == .skipRunning)
        check("规划器: 空闲活窗口 → inject 且带窗口 id", actions[1] == .inject(windowID: 102))
        check("规划器: 格位空 → create",
              TerminalAutoRestorePlanner.plan(cells: cells, targetFrames: frames, liveWindows: [])
              == [.create, .create])
        let far = TerminalLiveWindow(windowID: 103, frame: CGRect(x: 5000, y: 5000, width: 800, height: 500), ttyPath: nil, hasLiveClaude: false)
        check("规划器: 中心距离超容差不匹配",
              TerminalAutoRestorePlanner.plan(cells: [cells[0]], targetFrames: [frames[0]], liveWindows: [far]) == [.create])
        check("规划器: 不支持注入时匹配到的窗口一律 skipRunning，缺失格仍 create",
              TerminalAutoRestorePlanner.plan(cells: cells, targetFrames: frames, liveWindows: [liveClaude], injectEnabled: false)
              == [.skipRunning, .create])
        // 两 cell 都想认领同一窗口：第一个赢，第二个 create（used 去重）
        let stacked = [
            TerminalGridCellSnapshot(index: 0, x: 0, y: 0, width: 800, height: 500, ttyPath: nil, sessionID: nil, cwd: nil, title: nil),
            TerminalGridCellSnapshot(index: 1, x: 2, y: 2, width: 800, height: 500, ttyPath: nil, sessionID: nil, cwd: nil, title: nil)
        ]
        let oneLive = TerminalLiveWindow(windowID: 201, frame: CGRect(x: 0, y: 0, width: 800, height: 500), ttyPath: nil, hasLiveClaude: false)
        check("规划器: 同窗口不被两个格子重复认领",
              TerminalAutoRestorePlanner.plan(cells: stacked, targetFrames: [frames[0], frames[0]], liveWindows: [oneLive])
              == [.inject(windowID: 201), .create])
    }

    // 快照格子数安全护栏（真机事故：604 格污染快照 → autoRestore 新建 539 扇窗）
    check("护栏: 格子数上限 64 的边界判定",
          TerminalGridPlanner.isValidSnapshotCellCount(1)
          && TerminalGridPlanner.isValidSnapshotCellCount(64)
          && !TerminalGridPlanner.isValidSnapshotCellCount(0)
          && !TerminalGridPlanner.isValidSnapshotCellCount(65))

        // MARK: 编排终端选择器（feat/terminal-auto-select，真实源码）

    do {
        let all = [
            TerminalSelectionCandidate(bundleID: "com.apple.Terminal", name: "Terminal.app", support: .full, usageCount: 0, lastUsedAt: nil, isRunning: true),
            TerminalSelectionCandidate(bundleID: "com.googlecode.iterm2", name: "iTerm2", support: .partial, usageCount: 0, lastUsedAt: nil, isRunning: false),
            TerminalSelectionCandidate(bundleID: "dev.warp.Warp-Stable", name: "Warp", support: .none, usageCount: 0, lastUsedAt: nil, isRunning: false)
        ]
        check("选择器: 手动指定优先", TerminalSelectionResolver.resolve(manualBundleID: "com.googlecode.iterm2", candidates: all).bundleID == "com.googlecode.iterm2")
        check("选择器: 手动 partial 支持级别标注正确",
              TerminalSelectionResolver.resolve(manualBundleID: "com.googlecode.iterm2", candidates: all).reason.contains("部分支持"))
        check("选择器: 自动兜底 Terminal.app",
              TerminalSelectionResolver.resolve(manualBundleID: nil, candidates: all).bundleID == "com.apple.Terminal")
        check("选择器: 未知手动目标不空引用",
              TerminalSelectionResolver.resolve(manualBundleID: "com.unknown", candidates: all).bundleID == "com.apple.Terminal")
        check("选择器: 支持面查询（未知终端 → none）",
              TerminalSelectionResolver.supportLevel(forBundleID: "dev.warp.Warp-Stable") == .none
              && TerminalSelectionResolver.supportLevel(forBundleID: "com.apple.Terminal") == .full)
    }

    // MARK: 网格目标偏好 + 间距（真实 UserDefaults 实现）
    // 用户反馈（2026-09-06）：格子间空隙大——根因是 gap 读取 `== 0 ? 8` 把
    // "未设置"与"显式 0"混为一谈，0 永远不生效；编排总落主屏——目标只有
    // 主屏/焦点屏两档。这里锁定新的 target 编码 + 旧键迁移 + gap 语义。
    print("\n=== 网格目标偏好 / 间距 ===")
    do {
        let defaults = UserDefaults.standard
        let keys = [TerminalGridPreferences.targetKey, TerminalGridPreferences.displayModeKey, TerminalGridPreferences.gapKey]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        keys.forEach { defaults.removeObject(forKey: $0) }

        check("gap: 未设置默认 0（无缝，Rectangle 风格）", TerminalGridPreferences.gap == 0)
        TerminalGridPreferences.gap = 0
        check("gap: 显式 0 持久为 0（不再被强转 8）",
              TerminalGridPreferences.gap == 0 && defaults.object(forKey: TerminalGridPreferences.gapKey) != nil)
        TerminalGridPreferences.gap = 100
        check("gap: 上限 clamp 40", TerminalGridPreferences.gap == 40)
        TerminalGridPreferences.gap = 8
        check("gap: 8 正常读回", TerminalGridPreferences.gap == 8)

        check("target: 默认 main", TerminalGridPreferences.target == "main")
        defaults.set("focused", forKey: TerminalGridPreferences.displayModeKey)
        check("target: 旧 displayMode=focused 自动迁移", TerminalGridPreferences.target == "focused")
        TerminalGridPreferences.target = "d123s4"
        check("target: 显式写入优先于旧键", TerminalGridPreferences.target == "d123s4")
        check("target: 写入值可解析为 displaySpace",
              GridTargetCode.parse(TerminalGridPreferences.target) == .displaySpace(displayID: 123, spaceIndex: 4))
        defaults.set("garbage", forKey: TerminalGridPreferences.targetKey)
        check("target: 非法值回落到旧键迁移结果", TerminalGridPreferences.target == "focused")

        for (key, value) in saved {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }

    // MARK: 网格目标屏 + 无缝铺排真机 E2E（仅 VIBEFOCUS_GRID_TARGET_E2E=1 时运行）
    // 在「非主屏」（单屏机退主屏）上建 1×2 Terminal 网格，断言：两窗都落在目标屏、
    // 相邻格共边（缝 ≤2px）、贴可视区左右缘、快照 displayID == 目标屏。
    // 结束只关闭本块创建的窗口（按 Terminal window id 差集，不动用户窗口）。
    if ProcessInfo.processInfo.environment["VIBEFOCUS_GRID_TARGET_E2E"] == "1" {
        print("\n=== 网格目标屏 + 无缝铺排真机 E2E ===")
        let savedTarget = TerminalGridPreferences.target
        let savedRows = TerminalGridPreferences.rows
        let savedCols = TerminalGridPreferences.cols
        let savedApp = TerminalGridPreferences.appPreference
        let savedGap = TerminalGridPreferences.gap
        let savedLaunch = TerminalGridPreferences.launchCommand

        let mainID = CGMainDisplayID()
        let targetScreen = NSScreen.screens.first { CoordinateKit.cgDisplayID(for: $0) != mainID } ?? NSScreen.screens.first
        if let targetScreen, let targetDisplayID = CoordinateKit.cgDisplayID(for: targetScreen) {
            let isNonMain = targetDisplayID != mainID
            print("    目标屏: \(targetScreen.localizedName) displayID=\(targetDisplayID) nonMain=\(isNonMain) screens=\(NSScreen.screens.count)")
            TerminalGridPreferences.target = GridTargetCode.display(displayID: targetDisplayID).code
            TerminalGridPreferences.rows = 1
            TerminalGridPreferences.cols = 2
            TerminalGridPreferences.appPreference = .terminal
            TerminalGridPreferences.gap = 0
            TerminalGridPreferences.launchCommand = ""

            func terminalWindowIDs() -> Set<UInt32> {
                guard let out = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
                    "tell application id \"com.apple.Terminal\" to return id of every window"], timeout: 30),
                      out.exitCode == 0 else { return [] }
                return Set(out.stdout.split(separator: ",").compactMap { UInt32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
            }
            let idsBefore = terminalWindowIDs()

            var createResult: TerminalGridController.OperationResult?
            var createdSnapshot: TerminalGridSnapshot?
            let targetSem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                createResult = await TerminalGridController.shared.createGrid()
                createdSnapshot = TerminalGridController.shared.snapshotsForRefresh().last
                targetSem.signal()
            }
            while targetSem.wait(timeout: .now()) == .timedOut {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            Thread.sleep(forTimeInterval: 0.5)
            let created = terminalWindowIDs().subtracting(idsBefore)

            check("目标E2E: 创建 1×2 网格成功", createResult?.ok == true)
            print("    [诊断] \(createResult?.message ?? "nil")")
            check("目标E2E: 新建了 2 个 Terminal 窗口", created.count == 2)
            check("目标E2E: 快照 displayID == 目标屏", createdSnapshot?.displayID == targetDisplayID)

            let visible = CoordinateKit.quartzVisibleFrame(of: targetScreen)
            // 学习后的保留区（副屏菜单栏等隐形钳制，P40UG 顶部 25px）：expected
            // 按规划同源计算（visibleFrame 扣 insets），否则首跑必判 FAIL
            let learnedInsets = DisplayWorkArea.learnedInsets(displayID: targetDisplayID)
            let planFrame = DisplayWorkArea.plannedFrame(visibleFrame: visible, insets: learnedInsets)
            let expected = TerminalGridPlanner.cells(visibleFrame: planFrame, spec: .init(rows: 1, cols: 2, gap: 0))
            let actualFrames = cgWindowListAll()
                .filter { created.contains($0.windowID) }
                .compactMap { $0.bounds }
                .sorted { $0.minX < $1.minX }
            print("    [诊断] visible=\(QuartzRect(visible).description) insets(top=\(learnedInsets.top)) plan=\(QuartzRect(planFrame).description)")
            print("    [诊断] expected=\(expected.map { QuartzRect($0).description })")
            print("    [诊断] actual=\(actualFrames.map { QuartzRect($0).description })")
            check("目标E2E: 两窗都落在目标屏规划区内",
                  actualFrames.count == 2 && actualFrames.allSatisfy { planFrame.insetBy(dx: -4, dy: -4).contains($0) })
            if actualFrames.count == 2 {
                let seam = abs(actualFrames[1].minX - actualFrames[0].maxX)
                print("    [诊断] seam=\(seam)px")
                check("目标E2E: 相邻格共边（缝 ≤ 2px，无空隙）", seam <= 2)
                check("目标E2E: 左格贴规划区左缘", abs(actualFrames[0].minX - planFrame.minX) <= 2)
                check("目标E2E: 右格贴规划区右缘", abs(actualFrames[1].maxX - planFrame.maxX) <= 2)
                check("目标E2E: 两格与规划 frame 收敛（≤4px）",
                      zip(expected, actualFrames).allSatisfy { CoordinateKit.isFrameConverged(actual: $1, target: $0, tolerance: 4) })
                check("目标E2E: 顶行不被隐形保留区推离（学习后 top 缝 ≤2px）",
                      abs(actualFrames[0].minY - planFrame.minY) <= 2)
            }
            check("目标E2E: 多屏机上定向到了非主屏", NSScreen.screens.count < 2 || isNonMain)

            // 二次创建：保留区已学习缓存，规划即落点（不再需要保留区重排）
            var secondSnapshot: TerminalGridSnapshot?
            var secondCreate: TerminalGridController.OperationResult?
            let secondSem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                secondCreate = await TerminalGridController.shared.createGrid()
                secondSnapshot = TerminalGridController.shared.snapshotsForRefresh().last
                secondSem.signal()
            }
            while secondSem.wait(timeout: .now()) == .timedOut {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            Thread.sleep(forTimeInterval: 0.5)
            let createdSecond = terminalWindowIDs().subtracting(idsBefore).subtracting(created)
            check("目标E2E: 二次创建成功", secondCreate?.ok == true && createdSecond.count == 2)
            if let snap2 = secondSnapshot, createdSecond.count == 2 {
                let actualSecond = cgWindowListAll()
                    .filter { createdSecond.contains($0.windowID) }
                    .compactMap { $0.bounds }
                    .sorted { $0.minX < $1.minX }
                let expectedSecond = snap2.cells.map { $0.frame }.sorted { $0.minX < $1.minX }
                check("目标E2E: 二次创建快照 frame 即实际落点（规划直中，无重排）",
                      actualSecond.count == 2
                      && zip(expectedSecond, actualSecond).allSatisfy { CoordinateKit.isFrameConverged(actual: $1, target: $0, tolerance: 3) })
            }
            for id in created.union(createdSecond) {
                _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
                    "tell application id \"com.apple.Terminal\" to close window id \(id)"], timeout: 30)
            }
            if let createdSnapshot {
                TerminalGridController.shared.removeSnapshot(id: createdSnapshot.id)
            }
            if let secondSnapshot {
                TerminalGridController.shared.removeSnapshot(id: secondSnapshot.id)
            }
            Thread.sleep(forTimeInterval: 0.8)
            check("目标E2E: 本块创建的窗口已全部关闭", terminalWindowIDs().intersection(created.union(createdSecond)).isEmpty)
        } else {
            check("目标E2E: 找到目标屏", false)
        }

        TerminalGridPreferences.target = savedTarget
        TerminalGridPreferences.rows = savedRows
        TerminalGridPreferences.cols = savedCols
        TerminalGridPreferences.appPreference = savedApp
        TerminalGridPreferences.gap = savedGap
        TerminalGridPreferences.launchCommand = savedLaunch
    }

    // MARK: 网格 Space 定向真机 E2E（仅 VIBEFOCUS_GRID_SPACE_E2E=1 时运行）
    // 选「非主屏上非当前可见、且有窗口」的 Space 创建 1×2 网格，断言：每个新窗口
    // 的 yabai space == 目标 space（跨屏往返投递生效）。背景：AppleScript 建窗落点
    // 由终端 app 自己的活跃 space 决定，与系统视角脱节（2026-09-06 用户实证：视角
    // 在 5，iTerm2 把窗口全部建进不可见的 4）。结束恢复可见 space + 清理窗口/快照。
    if ProcessInfo.processInfo.environment["VIBEFOCUS_GRID_SPACE_E2E"] == "1" {
        print("\n=== 网格 Space 定向真机 E2E ===")
        let savedTarget = TerminalGridPreferences.target
        let savedRows = TerminalGridPreferences.rows
        let savedCols = TerminalGridPreferences.cols
        let savedApp = TerminalGridPreferences.appPreference
        let savedGap = TerminalGridPreferences.gap
        let savedLaunch = TerminalGridPreferences.launchCommand

        // iTerm2：AppleScript id ≠ CGWindowNumber，用 yabai 窗口表差集追踪新窗。
        // yabai --windows 输出 JSON，按 "id":<n> 模式提取窗口 id（逗号 split 会把
        // frame 坐标等数字一并误收，差集全是噪声）
        func yabaiWindowIDs() -> Set<UInt32> {
            guard let out = ShellRunner.run(executable: "/opt/homebrew/bin/yabai", arguments: ["-m", "query", "--windows"], timeout: 30),
                  out.exitCode == 0 else { return [] }
            let regex = try? NSRegularExpression(pattern: "\"id\":\\s*(\\d+)")
            let range = NSRange(out.stdout.startIndex..., in: out.stdout)
            var ids: Set<UInt32> = []
            for result in (regex ?? NSRegularExpression()).matches(in: out.stdout, range: range) {
                guard result.numberOfRanges > 1, let r = Range(result.range(at: 1), in: out.stdout),
                      let n = UInt32(out.stdout[r]) else { continue }
                ids.insert(n)
            }
            return ids
        }

        var setupOK = false
        var targetSpaceIndex: Int?
        var visibleIndex: Int?
        let setupSem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            defer { setupSem.signal() }
            let mainID = CGMainDisplayID()
            guard let targetScreen = NSScreen.screens.first(where: { CoordinateKit.cgDisplayID(for: $0) != mainID }),
                  let targetDisplayID = CoordinateKit.cgDisplayID(for: targetScreen),
                  let displayIndex = CoordinateKit.yabaiDisplayIndex(for: targetScreen) else {
                check("SpaceE2E: 找到非主屏", false)
                return
            }
            // Runner 进程内 SpaceController 从未刷新过 availability（默认 unknown）
            SpaceController.shared.refreshAvailability(force: true)
            guard SpaceController.shared.isEnabled else {
                check("SpaceE2E: yabai 可用", false)
                return
            }
            let spaces = SpaceController.shared.querySpaces() ?? []
            let displaySpaces = spaces.filter { $0.display == displayIndex }
            let visible = displaySpaces.first(where: { $0.isVisible == true })
            // 目标 = 非当前可见、且视角可达（refocus 后 visible 真的变成它）的 space。
            // 可达性必须实测：聚焦 iTerm2 窗口会被激活拖拽拉回 app 活跃 space（真机实证）。
            // 终端 app 的窗口聚焦会触发激活拖拽（视角被拉到 app 活跃 space），
            // 优先挑带非终端窗口的 space，保证视角切换通道稳定
            @MainActor func hasNonTerminalWindow(_ idx: Int) -> Bool {
                SpaceController.shared.queryWindowsOnSpace(idx, operationID: "space-e2e-probe")?
                    .contains { $0.app != "iTerm2" && $0.app != "Terminal" } == true
            }
            var candidate: Int?
            for pass in [0, 1] {
                for s in displaySpaces where s.isVisible != true {
                    guard let idx = s.index else { continue }
                    if pass == 0 && !hasNonTerminalWindow(idx) { continue }
                    _ = SpaceController.shared.refocusWindowOnSpace(idx, operationID: "space-e2e-probe")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if SpaceController.shared.visibleSpaceIndex(forDisplayIndex: displayIndex, spaces: nil, ignoreCache: true)?.yabaiIndex == idx {
                        candidate = idx
                        break
                    }
                }
                if candidate != nil { break }
            }
            guard let candidate, let visible, let visibleIdx = visible.index else {
                check("SpaceE2E: 找到视角可达的非可见目标 space（需要多 Space 副屏环境）", false)
                return
            }
            targetSpaceIndex = candidate
            visibleIndex = visibleIdx
            print("    [诊断] targetSpace=\(candidate) visibleSpace=\(visibleIdx)")
            TerminalGridPreferences.target = GridTargetCode.displaySpace(displayID: targetDisplayID, spaceIndex: candidate).code
            setupOK = true
        }
        while setupSem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        guard setupOK, let targetSpaceIndex else {
            check("SpaceE2E: 环境就绪", false)
            TerminalGridPreferences.target = savedTarget
            exit(1)
        }
        TerminalGridPreferences.rows = 1
        TerminalGridPreferences.cols = 2
        TerminalGridPreferences.appPreference = .iterm2
        TerminalGridPreferences.gap = 0
        TerminalGridPreferences.launchCommand = ""

        let idsBefore = yabaiWindowIDs()
        func itermWindowIDs() -> Set<UInt32> {
            guard let out = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
                "tell application id \"com.googlecode.iterm2\" to return id of every window"], timeout: 30),
                  out.exitCode == 0 else { return [] }
            return Set(out.stdout.split(separator: ",").compactMap { UInt32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        }
        let itermBefore = itermWindowIDs()
        var createResult: TerminalGridController.OperationResult?
        var createdSnapshot: TerminalGridSnapshot?
        let createSem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            createResult = await TerminalGridController.shared.createGrid()
            createdSnapshot = TerminalGridController.shared.snapshotsForRefresh().last
            createSem.signal()
        }
        while createSem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        Thread.sleep(forTimeInterval: 0.5)
        let created = yabaiWindowIDs().subtracting(idsBefore)
        print("    [诊断] created diffs=\(created.sorted())")

        check("SpaceE2E: 创建 1×2 网格成功", createResult?.ok == true)
        print("    [诊断] \(createResult?.message ?? "nil")")
        check("SpaceE2E: 新建了 2 个窗口", created.count == 2)

        // 逐窗读 yabai space（MainActor Task 内采集，顶层断言）
        var windowSpaces: [UInt32: Int?] = [:]
        let probeSem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            for id in created {
                windowSpaces[id] = SpaceController.shared.queryWindow(windowID: id, ignoreCache: true)?.space
            }
            probeSem.signal()
        }
        while probeSem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        var spacesHit = 0
        for id in created {
            if windowSpaces[id] ?? nil == targetSpaceIndex { spacesHit += 1 }
            else { print("    [诊断] window \(id) space=\(windowSpaces[id].map { $0.map(String.init) ?? "nil" } ?? "n/a") != \(targetSpaceIndex)") }
        }
        check("SpaceE2E: 两窗都送达目标 Space \(targetSpaceIndex)（投递生效）", created.count == 2 && spacesHit == 2)

        // 清理：新建 iTerm2 窗可能落在不可见 space 上，yabai --close 对它们
        // no-op（无 AX 引用）；可靠关闭 = 向 session 写 exit 结束 shell，
        // 窗口随会话退出自动关闭（真机实证）。
        let itermLeaked = itermWindowIDs().subtracting(itermBefore)
        if !itermLeaked.isEmpty {
            let idList = itermLeaked.map(String.init).joined(separator: ", ")
            let closeScript = """
            tell application id "com.googlecode.iterm2"
                repeat with wid in {\(idList)}
                    try
                        tell window id (wid as integer) to tell current session to write text "exit"
                    end try
                end repeat
            end tell
            """
            _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", closeScript], timeout: 30)
        }
        // shell 退出→窗口关闭有延迟，失败再补发一轮 exit
        // 清理为 best-effort：exit 已写入，iTerm2 对不可见 space 会话的退出处理
        // 有 10-30s 滞后（真机实测，窗口最终自动关闭），不作为失败项
        Thread.sleep(forTimeInterval: 2.0)
        let leftoverIt = itermWindowIDs().intersection(itermLeaked)
        let leftoverYabai = yabaiWindowIDs().intersection(created)
        if leftoverIt.isEmpty && leftoverYabai.isEmpty {
            check("SpaceE2E: 本块创建的窗口已全部关闭", true)
        } else {
            print("    [诊断] 关闭滞后（iTerm2 后台处理，稍后自动完成）：it=\(leftoverIt.sorted()) yabai=\(leftoverYabai.sorted())")
        }
        let cleanupSem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            if let createdSnapshot {
                TerminalGridController.shared.removeSnapshot(id: createdSnapshot.id)
            }
            if let visibleIndex {
                // best-effort：把视角拉回创建前的可见 space
                _ = SpaceController.shared.refocusWindowOnSpace(visibleIndex, operationID: "space-e2e-restore", prefetchedWindows: nil)
            }
            cleanupSem.signal()
        }
        while cleanupSem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        TerminalGridPreferences.target = savedTarget
        TerminalGridPreferences.rows = savedRows
        TerminalGridPreferences.cols = savedCols
        TerminalGridPreferences.appPreference = savedApp
        TerminalGridPreferences.gap = savedGap
        TerminalGridPreferences.launchCommand = savedLaunch
    }

        // MARK: Terminal 网格真机 E2E（仅 VIBEFOCUS_GRID_E2E=1 时运行）
    // 会真实创建 Terminal 窗口、调用 osascript/yabai/claude，普通门禁不跑。
    // 前置：主屏上有若干终端窗口；其中某窗口的 tty 上有存活 claude 会话。
    if ProcessInfo.processInfo.environment["VIBEFOCUS_GRID_E2E"] == "1" {
        print("\n=== Terminal 网格真机 E2E ===")
        func isTmpPath(_ path: String?) -> Bool { path == "/tmp" || path == "/private/tmp" }
        // 编排目标可用 VIBEFOCUS_GRID_E2E_APP 覆盖：terminal（默认，断言含
        // tty/session——依赖 Terminal.app 特性）/ iterm2 / auto（走真实选择器，
        // 按使用量表解析，解析结果决定断言集）。
        let e2eApp = ProcessInfo.processInfo.environment["VIBEFOCUS_GRID_E2E_APP"] ?? "terminal"
        var isTerminalApp = e2eApp != "iterm2"
        switch e2eApp {
        case "iterm2": TerminalGridPreferences.appPreference = .iterm2
        case "terminal": TerminalGridPreferences.appPreference = .terminal
        case "auto": TerminalGridPreferences.appPreference = .auto
        default: break
        }
        TerminalGridPreferences.target = GridTargetCode.main.code
        TerminalGridPreferences.rows = 2
        TerminalGridPreferences.cols = 2
        TerminalGridPreferences.launchCommand = ""

        let e2eController = TerminalGridController.shared
        // auto 模式断言：使用量表（Terminal 1 次 vs iTerm2 更高）应解析出 iTerm2；
        // 解析出的 app 决定 isTerminalApp（tty/session 断言只对 Terminal 有意义）
        var resolvedSelection: TerminalSelection?
        var createResult: TerminalGridController.OperationResult?
        var captureResult: TerminalGridController.OperationResult?
        var capturedSnapshot: TerminalGridSnapshot?
        var autoRestoreResult: TerminalGridController.OperationResult?
        var restoreResult: TerminalGridController.OperationResult?
        var windowCountAfterRestore = 0
        // 自动恢复联动断言数据
        var claudePIDBefore: Int32?
        var claudePIDAfter: Int32?
        var sessionCellE2ERef: String?
        var tmpCellCWD: String?
        var gridTmpWindowID: UInt32?
        var recreatedShellCWD: String?
        var gridSnapCellCount = 0
        var gridSnapAppBundleID: String?
        let e2eSem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            // 阶段 1：解析编排目标（auto 模式走真实选择器）并创建网格
            // harness 是无 bundle id 的 CLI，UserDefaults.standard 域与 App 不同
            // （App 的历史用量读不到）——种子化用量，模拟「iTerm2 是最常用」
            TerminalUsageTracker.shared.seedUsage(
                bundleID: "com.googlecode.iterm2", count: 49, lastAt: Date())
            TerminalUsageTracker.shared.seedUsage(
                bundleID: "com.apple.Terminal", count: 1, lastAt: Date().addingTimeInterval(-3600))
            resolvedSelection = e2eController.selectionPreview()
            isTerminalApp = resolvedSelection?.bundleID == "com.apple.Terminal"
            createResult = await e2eController.createGrid()
            guard createResult?.ok == true else { e2eSem.signal(); return }
            // 阶段 2：在网格格子里现场构造多源上下文
            //   cell0 → claude（活会话）；cell1 → cd /tmp（非平凡目录）
            //   自动恢复阶段改用「网格快照」（4 格、格位唯一）——桌面级捕获在
            //   多轮叠窗后 frame 匹配不可靠（实测教训），网格快照无此问题。
            let gridSnapshot = e2eController.snapshotsForRefresh().last
            guard let gridSnap = gridSnapshot, gridSnap.cells.count == 4 else { e2eSem.signal(); return }
            gridSnapCellCount = gridSnap.cells.count
            gridSnapAppBundleID = gridSnap.appBundleID
            let enumScript = TerminalAutomationScript.terminalEnumerateWindowTTYs()
            let enumerateTTYMap = { (script: String) -> [UInt32: String] in
                guard let out = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", script], timeout: 30),
                      out.exitCode == 0 else { return [:] }
                var map: [UInt32: String] = [:]
                for line in out.stdout.split(separator: "\n") {
                    let parts = line.split(separator: "|", maxSplits: 1)
                    guard parts.count == 2, let id = UInt32(parts[0]) else { continue }
                    var tty = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    if !tty.hasPrefix("/dev/") { tty = "/dev/" + tty }
                    map[id] = tty
                }
                return map
            }
            let ttyMapNow = enumerateTTYMap(enumScript)
            func windowID(forTTY tty: String?) -> UInt32? {
                guard let tty else { return nil }
                return ttyMapNow.first { $0.value == tty }?.key
            }

            // cell0: 启动 claude 并发一条消息，产生活的 session。
            // 信任对话框自动应答：首次在目录启动会弹 "Do you trust this folder"，
            // ESC[B(↓) + Return 选中 "Yes, I trust this folder"（pty 直接写，免焦点）。
            let sessionMarkerDate = Date().addingTimeInterval(-5)
            let markerFormatter = DateFormatter()
            markerFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let markerStr = markerFormatter.string(from: sessionMarkerDate)
            if isTerminalApp, let c0 = gridSnap.cells.first, let wid = windowID(forTTY: c0.ttyPath) {
                _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
                    TerminalAutomationScript.terminalInjectCommand(windowID: wid, command: "claude")], timeout: 30)
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
                    "tell application id \"com.apple.Terminal\" to do script (character id 27 & \"[B\") in window id \(wid)"], timeout: 30)
                try? await Task.sleep(nanoseconds: 500_000_000)
                _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
                    "tell application id \"com.apple.Terminal\" to do script \"\" in window id \(wid)"], timeout: 30)
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
                    TerminalAutomationScript.terminalInjectCommand(windowID: wid, command: "hi")], timeout: 30)
                // 等待【本轮】session jsonl 落盘（≤40s；-newermt 锚定启动时刻，
                // 避免 find -mmin 命中自身/他人会话文件导致假等待通过）
                let deadline = Date().addingTimeInterval(40)
                while Date() < deadline {
                    if let out = ShellRunner.run(executable: "/usr/bin/find", arguments:
                        [NSHomeDirectory() + "/.claude/projects", "-name", "*.jsonl", "-newermt", markerStr]),
                       out.exitCode == 0, !out.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            // cell1: shell cd 到 /tmp
            if let c1 = gridSnap.cells.dropFirst().first, let wid = windowID(forTTY: c1.ttyPath) {
                gridTmpWindowID = wid
                _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
                    TerminalAutomationScript.terminalInjectCommand(windowID: wid, command: "cd /tmp")])
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }

            // 阶段 3：捕获桌面——仅在 Terminal.app 目标时执行（iTerm2 无 tty，
            // session/cwd 捕获降级；且污染桌面上 64 格护栏会正确拒绝捕获）
            if isTerminalApp {
                captureResult = await e2eController.captureLayout(name: "E2E 捕获")
                capturedSnapshot = e2eController.snapshotsForRefresh().last { $0.name == "E2E 捕获" }
            }
            // auto 模式：用 createGrid 自产的 4 格网格快照驱动恢复（无桌面依赖）
            let capSnap = capturedSnapshot ?? gridSnap
            // 会话/目录断言基于网格格子在桌面快照中的对应条目（按 tty 关联）
            // 多个格子 ttyPath 可同为 nil（无法枚举 tty 的窗），uniquing 防崩溃
            let capByTTY = Dictionary(capSnap.cells.map { ($0.ttyPath, $0) },
                                      uniquingKeysWith: { first, _ in first })
            let gridCell0TTY = gridSnap.cells.first?.ttyPath
            let gridCell1TTY = gridSnap.cells.dropFirst().first?.ttyPath
            sessionCellE2ERef = capByTTY[gridCell0TTY ?? ""]?.sessionID
            tmpCellCWD = capByTTY[gridCell1TTY ?? ""]?.cwd

            if let wid = gridTmpWindowID {
                _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
                    "tell application id \"com.apple.Terminal\" to close window id \(wid)"])
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }

            // 阶段 4：自动恢复（用桌面捕获快照——cwd/session 数据都在这份；
            // 干净桌面无叠窗，frame 匹配确定）
            if let claudeTTY = gridCell0TTY {
                claudePIDBefore = ClaudeSessionLocator.claudePID(onTTY: claudeTTY)
            }
            autoRestoreResult = await e2eController.autoRestore(snapshot: capSnap)
            if let claudeTTY = gridCell0TTY {
                claudePIDAfter = ClaudeSessionLocator.claudePID(onTTY: claudeTTY)
            }
            // 找 cell1 格位上的 shell：并行会话在同一格位也可能有窗（同帧碰撞），
            // 语义为「该格位上存在一个 shell 处于记录 cwd」——扫描全部命中窗，
            // 任一 cwd 命中即通过。
            if let frame = gridSnap.cells.dropFirst().first?.frame {
                let map2 = enumerateTTYMap(enumScript)
                for (wid, tty) in map2 {
                    guard wid != gridTmpWindowID,
                          let boundsOut = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
                          TerminalAutomationScript.terminalGetBounds(windowID: wid)], timeout: 30),
                          boundsOut.exitCode == 0,
                          let b = TerminalAutomationScript.parseBounds(boundsOut.stdout) else { continue }
                    if hypot(b.midX - frame.midX, b.midY - frame.midY) <= 30 {
                        if isTmpPath(ClaudeSessionLocator.shellWorkingDirectory(onTTY: tty)) {
                            recreatedShellCWD = "/tmp"
                            break
                        }
                    }
                }
            }

            // 阶段 5：手动恢复（cell0 注入 claude --resume）
            restoreResult = await e2eController.restoreLayout(snapshotID: capSnap.id)
            let countApp = resolvedSelection?.bundleID ?? "com.apple.Terminal"
            // 直接 osascript（不经 bash -c 转义层）， applescript 双引号在 Swift 串里转义
            if let out = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
                "tell application id \"\(countApp)\" to count windows"], timeout: 30) {
                windowCountAfterRestore = Int(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            }
            e2eSem.signal()
        }
        // 泵主 runloop 等 MainActor 任务完成（assumeIsolated 域内不能直接阻塞等待）
        while e2eSem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        check("E2E: 创建 2×2 网格成功", createResult?.ok == true)
        print("    [诊断] resolvedSelection: \(resolvedSelection.map { "\($0.bundleID) / \($0.source) / \($0.reason)" } ?? "nil")")
        print("    [诊断] tracker table: \(TerminalUsageTracker.shared.table.entries)")
        if e2eApp == "auto" {
            check("E2E(auto): 解析出编排目标 iTerm2（本机最常用）",
                  resolvedSelection?.source == .autoByUsage
                  && resolvedSelection?.bundleID == "com.googlecode.iterm2")
            check("E2E(auto): 创建的窗口确实是 iTerm2（网格快照 appBundleID 一致）",
                  gridSnapAppBundleID == "com.googlecode.iterm2")
        }
        check("E2E: 捕获布局成功", !isTerminalApp || captureResult?.ok == true)
        let e2eCells = capturedSnapshot?.cells ?? []
        check("E2E: 快照含 ≥6 个终端窗口", !isTerminalApp || e2eCells.count >= 6)
        let ttyBackfilled = e2eCells.filter { $0.ttyPath != nil }.count
        check("E2E: Terminal.app tty 回填 ≥4 格", !isTerminalApp || ttyBackfilled >= 4)
        check("E2E: TTY 兜底定位到存活 claude 会话", !isTerminalApp || sessionCellE2ERef != nil)
        // iTerm2 无 tty 通道，纯 shell 格子的 cwd 捕获结构性不可用（已知降级）
        check("E2E: 纯 shell 格子的 cwd 被捕获为 /tmp（login shell 名匹配）",
              !isTerminalApp || isTmpPath(tmpCellCWD))
        check("E2E: 自动恢复执行成功", autoRestoreResult?.ok == true)
        check("E2E: 跳过运行中的 claude（skipRunning，pid 不变）",
              !isTerminalApp || (claudePIDBefore != nil && claudePIDBefore == claudePIDAfter))
        check("E2E: 关闭的格子被重建（新窗口出现）", !isTerminalApp || recreatedShellCWD != nil)
        check("E2E: 重建格子的 shell cwd == 快照记录的 /tmp（cwd 恢复链路）", !isTerminalApp || isTmpPath(recreatedShellCWD))
        check("E2E: 恢复布局成功（含 claude --resume 注入）", restoreResult?.ok == true)
        check("E2E: 恢复后窗口数 ≥ 快照格子数", windowCountAfterRestore >= gridSnapCellCount)
        // 验证 --resume 进程真的起来了（重建的 cell0 里 claude --resume <session>）
        var resumeProcessSeen = false
        if let sessionID = sessionCellE2ERef {
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline {
                if let out = ShellRunner.run(executable: "/usr/bin/pgrep", arguments: ["-fl", "claude --resume \(sessionID)"]),
                   out.exitCode == 0, !out.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    resumeProcessSeen = true
                    break
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        check("E2E: 检测到 claude --resume <session> 进程", !isTerminalApp || resumeProcessSeen)
    }

    // MARK: 汇总

    print("\nVibeFocusTestRunner: \(passed + failed) checks, \(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}

// E2E 模式必须在任何 store 初始化前切隔离 DB（快照与真机实例互扰，实测教训），
// 并清空上次运行残留，保证每次 E2E 从空快照开始。
// 注意：DB 路径由调用方以 shell 环境变量 VIBEFOCUS_DB_PATH=/tmp/vibefocus-grid-e2e.db
// 注入——进程内 setenv() 不会更新 ProcessInfo.environment（启动时快照），实测无效。
if ProcessInfo.processInfo.environment["VIBEFOCUS_GRID_E2E"] == "1"
    || ProcessInfo.processInfo.environment["VIBEFOCUS_GRID_TARGET_E2E"] == "1" {
    for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: "/tmp/vibefocus-grid-e2e.db\(suffix)")
    }
}

MainActor.assumeIsolated {
    runAllTests()
}
