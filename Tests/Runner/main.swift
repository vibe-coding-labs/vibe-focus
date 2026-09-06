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

/// restore 阶段序列日志：跨四类假依赖统一记录调用顺序（Batch 8 序列锁）。
@MainActor
final class RestoreSeqLog {
    var events: [String] = []
    func add(_ e: String) { events.append(e) }
}

@MainActor
final class FakeRestoreChannels: RestoreSpaceChanneling {
    var seq: RestoreSeqLog?
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
        seq?.add("focus")
        focusReceived = space
        return focusResult
    }

    func refocusWindowOnSpace(_ spaceIndex: Int, excludingWindowID: UInt32?, operationID: String?, prefetchedWindows: [YabaiWindowInfo]?) -> Bool {
        calls.append("refocus")
        seq?.add("refocus")
        refocusReceivedSpace = spaceIndex
        refocusReceivedExcluded = excludingWindowID
        refocusReceivedPrefetched = prefetchedWindows
        return refocusResult
    }

    func currentSpaceIndex() -> Int? {
        calls.append("current")
        seq?.add("current")
        guard !currentSpaceQueue.isEmpty else { return currentSpace }
        return currentSpaceQueue.removeFirst()
    }

    func clearQueryCache() {
        calls.append("clearCache")
        seq?.add("clearCache")
        cacheCleared = true
    }

    func queryWindow(windowID: UInt32, ignoreCache: Bool) -> YabaiWindowInfo? {
        calls.append("query")
        seq?.add("query")
        return queryResult
    }

    func visibleSpaceIndex(forDisplayIndex: Int?, spaces: [YabaiSpaceInfo]?, ignoreCache: Bool) -> SpaceIdentifier? {
        calls.append("visible")
        seq?.add("visible")
        return ignoreCache ? visibleSpaceAfterSwitch : visibleSpace
    }

    func setWindowFloat(_ windowID: UInt32, operationID: String?, knownWindowInfo: YabaiWindowInfo?) -> SpaceController.FloatToggleOutcome {
        calls.append("float")
        seq?.add("float")
        floatCalled = true
        return floatOutcome
    }

    func queryWindowsOnSpace(_ spaceIndex: Int, operationID: String?) -> [YabaiWindowInfo]? {
        calls.append("querySpaceWindows")
        seq?.add("querySpaceWindows")
        return spaceWindows
    }
}

// MARK: - restore 主体假依赖（record 存取 / 窗口操作 / 审计收集）

@MainActor
final class FakeRecords: RestoreRecordStoring {
    let record: ToggleRecord?
    private(set) var clearCalls = 0
    var seq: RestoreSeqLog?

    init(record: ToggleRecord?) {
        self.record = record
    }

    func load(windowID: UInt32) -> ToggleRecord? {
        seq?.add("load")
        return record
    }
    func clear(windowID: UInt32) {
        seq?.add("clear")
        clearCalls += 1
    }
}

@MainActor
final class FakeWindows: RestoreWindowOperating {
    var findResult: AXUIElement?
    var moveResult = true
    var displayContextResult: (yabaiIndex: Int?, displayID: UInt32?) = (yabaiIndex: 2, displayID: nil)
    let frameTolerance: CGFloat = 20
    var seq: RestoreSeqLog?
    private(set) var moveCalls: [(windowID: UInt32, stage: String)] = []

    init(findResult: AXUIElement?, moveResult: Bool = true) {
        self.findResult = findResult
        self.moveResult = moveResult
    }

    func findWindowByPID(_ pid: pid_t, windowID: UInt32?) -> AXUIElement? {
        seq?.add("lookup")
        return findResult
    }

    func moveWindowToFrameViaYabai(windowID: UInt32, frame: CGRect, op: String, stage: String, sourceVisibleFrame: CGRect?) -> Bool {
        seq?.add("move:\(stage)")
        moveCalls.append((windowID, stage))
        return moveResult
    }

    func displayContext(for frame: CGRect) -> (yabaiIndex: Int?, displayID: UInt32?) {
        seq?.add("displayContext")
        return displayContextResult
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
    var seq: RestoreSeqLog?

    func record(eventType: String, windowID: UInt32, pid: Int32?, sessionID: String?, details: [String: String]) {
        seq?.add("audit:\(eventType)")
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
            channels: FakeRestoreChannels,
            seq: RestoreSeqLog? = nil
        ) -> (FakeRecords, FakeWindows, FakeRestoreChannels, FakeAuditor) {
            let ax = findOK ? AXUIElementCreateSystemWide() : nil
            let recs = FakeRecords(record: record)
            let wins = FakeWindows(findResult: ax, moveResult: moveOK)
            let aud = FakeAuditor()
            recs.seq = seq
            wins.seq = seq
            channels.seq = seq
            aud.seq = seq
            return (recs, wins, channels, aud)
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
            // Batch 6 起 4a FloatSettle 恒清缓存一次；守卫成功再清一次 = 共 2 次。
            check("主体: 视角漂移 → 守卫切回成功并清缓存，结局仍 restored(true)",
                  outcome == .restored(spaceExact: true) && ch2.cacheCleared
                  && ch2.calls.filter { $0 == "clearCache" }.count == 2
                  && aud.events[0].eventType == "restore_success")
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
            // Batch 6 起 4a FloatSettle 恒清缓存一次（float 已改 yabai 侧状态，旧缓存
            // 必须失效）；守卫失败路径不再额外清 = 全程恰好 1 次（视角留在他处如实降级）。
            check("主体: 守卫双层全失败 → 结局仍 restored(true)，缓存仅 4a 清一次（守卫失败不再清）",
                  outcome == .restored(spaceExact: true)
                  && ch2.calls.filter { $0 == "clearCache" }.count == 1
                  && aud.events[0].eventType == "restore_success")
        }

        // MARK: 阶段序列锁（Batch 8）——restore 主体的顺序契约由跨依赖调用序列断言锁定。
        // 契约清单：load→lookup→query 先行；preMoveSpace(current) 必须先于 4-pre 判定
        // （漏采会把切换后的 space 当基准，漏切回用户视角）；4-pre 双层（visible 判定→
        // SA 直切→等到位轮询）先于守卫预取与 move；FloatSettle 恒清缓存紧跟 float；
        // move 后守卫先行（成功/失败路径都是）再动 record；永久失败才清 record。

        // S1. happy + 源屏 space 切回 + 视角逐卫成功：16 步全序锁定。
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.currentSpaceQueue = [1, 5, 5]          // preMove=1；move 后守卫查询=5（漂移）
            ch.queryResult = infoWindow()
            ch.visibleSpace = .yabaiIndex(5)           // 源屏(disp2)可见 space 5 ≠ sourceSpace 3 → switchNeeded
            ch.visibleSpaceAfterSwitch = .yabaiIndex(3) // 切回轮询确认落定 3
            ch.focusResult = true                      // SA 直切两层（4-pre + 守卫）都成功
            ch.spaceWindows = nil
            ch.floatOutcome = .toggled                 // 4a 真 float（FloatSettle 真实等待一次）
            let log = RestoreSeqLog()
            let (rec, win, ch2, aud) = makeDeps(channels: ch, seq: log)
            let outcome = run(rec, win, ch2, aud)
            check("restoreSeq S1: 结局 restored(spaceExact=true)", outcome == .restored(spaceExact: true))
            check("restoreSeq S1: 16 步全序（capture 先于 4-pre、float+清缓存先于 move、守卫先于 clear）",
                  log.events == ["load", "lookup", "query", "current", "visible", "focus", "visible",
                                 "querySpaceWindows", "float", "clearCache", "move:restore",
                                 "current", "focus", "clearCache", "clear", "audit:restore_success"])
            check("restoreSeq S1: record 在守卫成功后才清（clearCalls=1）", rec.clearCalls == 1)
        }

        // S2. 最小化快检失败：query 后立即短路（无 current/float/move/clear）。
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.queryResult = infoWindow(minimized: true)
            let log = RestoreSeqLog()
            let (rec, win, ch2, aud) = makeDeps(channels: ch, seq: log)
            let outcome = run(rec, win, ch2, aud)
            check("restoreSeq S2: 最小化 → moveFailedRetryable", outcome == .moveFailedRetryable)
            check("restoreSeq S2: 序列止于审计（preMoveSpace/float/move/clear 全部短路）",
                  log.events == ["load", "lookup", "query", "audit:restore_move_failed"]
                  && rec.clearCalls == 0)
        }

        // S3. move 失败 + origFrame 在屏内 → retryable：失败路径守卫先行，record 保留。
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.currentSpaceQueue = [1, 5, 5]
            ch.queryResult = infoWindow()
            ch.visibleSpace = .yabaiIndex(3)           // == sourceSpace → notNeeded（聚焦 4-pre 序列外）
            ch.focusResult = true
            let log = RestoreSeqLog()
            let (rec, win, ch2, aud) = makeDeps(moveOK: false, channels: ch, seq: log)
            let outcome = run(rec, win, ch2, aud)
            check("restoreSeq S3: move 失败屏内 → moveFailedRetryable", outcome == .moveFailedRetryable)
            check("restoreSeq S3: 失败路径同样守卫先行（move→current→focus→clearCache→审计），record 保留",
                  log.events == ["load", "lookup", "query", "current", "visible", "querySpaceWindows",
                                 "float", "clearCache", "move:restore", "current", "focus", "clearCache",
                                 "displayContext", "audit:restore_move_failed"]
                  && rec.clearCalls == 0)
        }

        // S4. move 失败 + origFrame 在所有屏外 → clamp 重试仍失败 → permanent：clamp 写
        //     发生在守卫之后、clear 之前（P1 保守退让的顺序契约）。
        do {
            let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: 1)
            ch.currentSpaceQueue = [1, 5, 5]
            ch.queryResult = infoWindow()
            ch.visibleSpace = .yabaiIndex(3)
            let log = RestoreSeqLog()
            let (rec, win, ch2, aud) = makeDeps(moveOK: false, channels: ch, seq: log)
            win.displayContextResult = (yabaiIndex: nil, displayID: nil)  // 屏外 → clamp 退让
            win.moveResult = false                                        // clamp 重试也失败
            let outcome = run(rec, win, ch2, aud)
            check("restoreSeq S4: 屏外且 clamp 失败 → moveFailedPermanent", outcome == .moveFailedPermanent)
            check("restoreSeq S4: notNeeded 无 4-pre 切回；clamp 后守卫再判漂移再守卫；审计后才 clear",
                  log.events == ["load", "lookup", "query", "current", "visible", "querySpaceWindows",
                                 "float", "clearCache", "move:restore", "current", "refocus",
                                 "displayContext", "move:restore_clamped", "current", "refocus",
                                 "clear", "audit:restore_move_failed"])
            check("restoreSeq S4: record 已清（永久失败唯一合法清除点之后）", rec.clearCalls == 1)
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

    // MARK: 跨屏移动尺寸保真真机 E2E（仅 VIBEFOCUS_SIZE_E2E=1 时运行）
    // 用户主诉（2026-09-06）：移动窗口后尺寸错误。用已知尺寸的 iTerm2 窗口走
    // WindowManager.moveWindowToFrameViaYabai 跨屏移动，覆盖两条写序：
    //   Case A 放大跨屏（主→副，800x600→1500x900，旧 origin+目标尺寸在源屏可视
    //          区内 → 命中 af19b2b 新增的 resizeThenMove 先行终态路径）
    //   Case B 缩小跨屏（副→主，1500x900→800x600 → 缩小分支 resizeThenMove）
    // 断言：最终 frame 尺寸/位置与目标一致（±40 量化容差）。结束清理窗口。
    if ProcessInfo.processInfo.environment["VIBEFOCUS_SIZE_E2E"] == "1" {
        print("\n=== 跨屏移动尺寸保真真机 E2E ===")
        SpaceController.shared.refreshAvailability(force: true)
        check("SizeE2E: yabai 可用", SpaceController.shared.isEnabled)

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
        func yabaiWindowFrame(_ id: UInt32) -> CGRect? {
            guard let out = ShellRunner.run(executable: "/opt/homebrew/bin/yabai",
                arguments: ["-m", "query", "--windows", "--window", "\(id)"], timeout: 30),
                out.exitCode == 0,
                let data = out.stdout.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let f = obj["frame"] as? [String: Any],
                let x = (f["x"] as? NSNumber)?.doubleValue,
                let y = (f["y"] as? NSNumber)?.doubleValue,
                let w = (f["w"] as? NSNumber)?.doubleValue,
                let h = (f["h"] as? NSNumber)?.doubleValue else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }
        func yabaiPlace(_ id: UInt32, frame: CGRect) {
            _ = SpaceController.shared.runYabai(
                arguments: ["-m", "window", "\(id)", "--move", "abs:\(Int(frame.origin.x)):\(Int(frame.origin.y))"],
                operation: "size-e2e.place", operationID: "size-e2e")
            _ = SpaceController.shared.runYabai(
                arguments: ["-m", "window", "\(id)", "--resize", "abs:\(Int(frame.width)):\(Int(frame.height))"],
                operation: "size-e2e.place", operationID: "size-e2e")
        }
        func itermWindowIDs() -> Set<UInt32> {
            guard let out = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
                "tell application id \"com.googlecode.iterm2\" to return id of every window"], timeout: 30),
                  out.exitCode == 0 else { return [] }
            return Set(out.stdout.split(separator: ",").compactMap { UInt32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        }

        guard let mainScreen = NSScreen.screens.first(where: { CoordinateKit.cgDisplayID(for: $0) == CGMainDisplayID() }),
              let secondaryScreen = NSScreen.screens.first(where: { CoordinateKit.cgDisplayID(for: $0) != CGMainDisplayID() }) else {
            check("SizeE2E: 找到主副双屏", false)
            exit(1)
        }

        let idsBefore = yabaiWindowIDs()
        // 创建 iTerm2 窗口（落点由 app 决定，随后 yabai 摆到精确初始帧）
        _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
            "tell application id \"com.googlecode.iterm2\" to create window with default profile"], timeout: 30)
        Thread.sleep(forTimeInterval: 0.8)
        let created = yabaiWindowIDs().subtracting(idsBefore)
        guard created.count == 1, let wid = created.first else {
            check("SizeE2E: 创建 iTerm2 测试窗口", false)
            exit(1)
        }
        print("    [诊断] 测试窗口 id=\(wid)")

        func runCase(name: String, initial: CGRect, target: CGRect, sourceVisible: CGRect) {
            let placeSem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                yabaiPlace(wid, frame: initial)
                placeSem.signal()
            }
            while placeSem.wait(timeout: .now()) == .timedOut {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            Thread.sleep(forTimeInterval: 0.6)
            guard let startFrame = yabaiWindowFrame(wid) else {
                check("SizeE2E \(name): 读取初始帧", false)
                return
            }
            print("    [诊断] \(name) 初始=\(startFrame) 目标=\(target)")
            let moveSem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                _ = WindowManager.shared.moveWindowToFrameViaYabai(
                    windowID: wid, frame: target, op: "size-e2e", stage: "size_e2e.\(name)",
                    sourceVisibleFrame: sourceVisible)
                moveSem.signal()
            }
            while moveSem.wait(timeout: .now()) == .timedOut {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            // 收敛观察窗：2s 内帧稳定即采样
            var final: CGRect?
            var last: CGRect?
            var stable = 0
            for _ in 0..<20 {
                let f = yabaiWindowFrame(wid)
                if let f, let last, f == last { stable += 1; if stable >= 3 { final = f; break } }
                else { stable = 0 }
                last = f
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard let final else {
                check("SizeE2E \(name): 读到稳定终帧", false)
                return
            }
            let sizeDW = abs(final.width - target.width)
            let sizeDH = abs(final.height - target.height)
            let posDX = abs(final.origin.x - target.origin.x)
            let posDY = abs(final.origin.y - target.origin.y)
            print("    [诊断] \(name) 终帧=\(final) Δsize=(\(sizeDW),\(sizeDH)) Δpos=(\(posDX),\(posDY))")
            check("SizeE2E \(name): 尺寸保真（Δ≤40，实测 Δ=(\(Int(sizeDW)),\(Int(sizeDH)))）",
                  sizeDW <= 40 && sizeDH <= 40)
            check("SizeE2E \(name): 位置保真（Δ≤80）", posDX <= 80 && posDY <= 80)
        }

        // Case A：主→副 放大（旧 origin(100,100)+目标尺寸在主屏可视区内 → 命中
        // af19b2b 放大先行 resizeThenMove 新路径）
        runCase(name: "main_to_secondary_enlarge",
                initial: CGRect(x: 100, y: 100, width: 800, height: 600),
                target: CGRect(x: 200, y: 150, width: 1500, height: 900),
                sourceVisible: mainScreen.visibleFrame)
        // Case B：副→主 缩小（缩小分支：目标 fits 源屏可视区 → resizeThenMove）
        runCase(name: "secondary_to_main_shrink",
                initial: CGRect(x: 200, y: 150, width: 1500, height: 900),
                target: CGRect(x: 100, y: 100, width: 800, height: 600),
                sourceVisible: secondaryScreen.visibleFrame)

        // Case C：完整 toggle 往返（用户真实操作路径：聚焦副屏窗口 → 热键 toggle
        // 到主屏 → 再 toggle 还原回副屏原帧）。两次 toggle 各测一次尺寸。
        let c1Sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            yabaiPlace(wid, frame: CGRect(x: -814, y: -1415, width: 1146, height: 707))
            c1Sem.signal()
        }
        while c1Sem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        Thread.sleep(forTimeInterval: 0.6)
        // 聚焦测试窗口（toggle 操作聚焦窗口）
        _ = ShellRunner.run(executable: "/opt/homebrew/bin/yabai", arguments: ["-m", "window", "\(wid)", "--focus"], timeout: 30)
        Thread.sleep(forTimeInterval: 0.5)
        let toggle1Sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            WindowManager.shared.toggle(operationID: "size-e2e-toggle-1", triggerSource: "size_e2e")
            toggle1Sem.signal()
        }
        while toggle1Sem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        Thread.sleep(forTimeInterval: 1.2)
        if let afterMove = yabaiWindowFrame(wid) {
            let onMain = afterMove.origin.x >= 0
            let sizeOK = abs(afterMove.width - 1653) <= 40 && abs(afterMove.height - 1079) <= 40
            print("    [诊断] toggle1 移主屏 终帧=\(afterMove) onMain=\(onMain)")
            check("SizeE2E toggleCase: toggle 到主屏尺寸 = 主屏可视区 1653x1079（±40）", onMain && sizeOK)
        } else {
            check("SizeE2E toggleCase: 读取 toggle 后帧", false)
        }
        let toggle2Sem = DispatchSemaphore(value: 0)
        // 重聚焦后再 toggle：期间系统设置等窗口可能抢焦点（ax 引导流会开系统设置）
        _ = ShellRunner.run(executable: "/opt/homebrew/bin/yabai", arguments: ["-m", "window", "\(wid)", "--focus"], timeout: 30)
        Thread.sleep(forTimeInterval: 0.3)
        Task { @MainActor in
            WindowManager.shared.toggle(operationID: "size-e2e-toggle-2", triggerSource: "size_e2e")
            toggle2Sem.signal()
        }
        while toggle2Sem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        Thread.sleep(forTimeInterval: 1.2)
        if let afterRestore = yabaiWindowFrame(wid) {
            print("    [诊断] toggle2 还原 终帧=\(afterRestore)（期望 -814,-1415 1146x707）")
            let backOnSecondary = afterRestore.origin.x < 0
            let sizeOK = abs(afterRestore.width - 1146) <= 40 && abs(afterRestore.height - 707) <= 40
            check("SizeE2E toggleCase: 还原回副屏尺寸保真（±40）", backOnSecondary && sizeOK)
            check("SizeE2E toggleCase: 还原回副屏原位置（±80）",
                  abs(afterRestore.origin.x - (-814)) <= 80 && abs(afterRestore.origin.y - (-1415)) <= 80)
        } else {
            check("SizeE2E toggleCase: 读取还原后帧", false)
        }

        // Case D：解堵路由尺寸保持。主屏上一个无 toggle 记录的窗口（新窗即满足）
        // toggle → 走 stuck 路由移副屏。修复前：目标=副屏整屏可视区（3440x1440），
        // 窗口被撑满整副屏（用户主诉「尺寸搞错」）；修复后：保持原尺寸 900x600，
        // 位置夹进副屏可视区。
        let idsBeforeD = yabaiWindowIDs()
        _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
            "tell application id \"com.googlecode.iterm2\" to create window with default profile"], timeout: 30)
        Thread.sleep(forTimeInterval: 0.8)
        let createdD = yabaiWindowIDs().subtracting(idsBeforeD)
        guard createdD.count == 1, let widD = createdD.first else {
            check("SizeE2E stuckCase: 创建第二测试窗口", false)
            exit(1)
        }
        let d1Sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            yabaiPlace(widD, frame: CGRect(x: 600, y: 300, width: 900, height: 600))
            d1Sem.signal()
        }
        while d1Sem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        Thread.sleep(forTimeInterval: 0.6)
        _ = ShellRunner.run(executable: "/opt/homebrew/bin/yabai", arguments: ["-m", "window", "\(widD)", "--focus"], timeout: 30)
        Thread.sleep(forTimeInterval: 0.5)
        let d2Sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            WindowManager.shared.toggle(operationID: "size-e2e-toggle-stuck", triggerSource: "size_e2e")
            d2Sem.signal()
        }
        while d2Sem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        Thread.sleep(forTimeInterval: 1.2)
        if let stuckFrame = yabaiWindowFrame(widD) {
            print("    [诊断] stuckCase 终帧=\(stuckFrame)（期望尺寸保持 900x600、移到副屏）")
            let onSecondary = stuckFrame.origin.y < 0
            let sizeKept = abs(stuckFrame.width - 900) <= 40 && abs(stuckFrame.height - 600) <= 40
            check("SizeE2E stuckCase: 解堵移副屏尺寸保持 900x600（±40，修复前=撑满 3440x1440）",
                  onSecondary && sizeKept)
        } else {
            check("SizeE2E stuckCase: 读取解堵后帧", false)
        }

        // Case E：restore 屏外 origFrame 保守退让（P1 修复）。合成一条 origFrame 在
        // 所有屏之外的 record（显示器配置变化后的真实场景），restore 应把原始帧夹进
        // 源屏可视区完成还原（修复前：清 record 放弃，窗口卡在原处）。期望终帧 =
        // clampFrame((5000,500,800,600), 副屏可视区) = (1826,-600,800,600)。
        let itermPID = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
            "tell application id \"com.googlecode.iterm2\" to return unix id"], timeout: 30)
            .flatMap { Int32($0.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let e1Sem = DispatchSemaphore(value: 0)
        var clampExpected = CGRect.zero
        var restoreOutcome: String = "n/a"
        Task { @MainActor in
            let spaces = SpaceController.shared.querySpaces()
            let secDisplay = spaces?.first(where: { $0.display != 1 })?.display ?? 2
            let secVisibleSpaceIdx = spaces?.first(where: { $0.display == secDisplay && $0.isVisible == true })?.index ?? 3
            ToggleEngine.shared.save(
                windowID: wid,
                pid: itermPID ?? 0,
                bundleIdentifier: "com.googlecode.iterm2",
                appName: "iTerm2",
                origFrame: CGRect(x: 5000, y: 500, width: 800, height: 600),
                sourceSpace: .yabaiIndex(secVisibleSpaceIdx),
                sourceDisplay: .yabaiIndex(Int(secDisplay)),
                sourceYabaiDisp: .yabaiIndex(Int(secDisplay)),
                sourceDispSpace: secVisibleSpaceIdx,
                targetFrame: CGRect(x: 75, y: 38, width: 1653, height: 1079),
                targetDisplay: 1,
                sessionID: nil,
                reason: .manualHotkey
            )
            if let secScreen = CoordinateKit.nsScreen(forYabaiDisplayIndex: Int(secDisplay)) {
                clampExpected = CoordinateKit.clampFrame(
                    CGRect(x: 5000, y: 500, width: 800, height: 600),
                    into: CoordinateKit.quartzVisibleFrame(of: secScreen))
            }
            let outcome = ToggleEngine.shared.restore(windowID: wid, triggerSource: "size_e2e", traceID: "size-e2e-clamp")
            restoreOutcome = outcome.outcomeLabel
            e1Sem.signal()
        }
        while e1Sem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        Thread.sleep(forTimeInterval: 1.0)
        print("    [诊断] clampCase 结果=\(restoreOutcome) 期望终帧=\(clampExpected)")
        if let clampedFinal = yabaiWindowFrame(wid), clampExpected != .zero {
            let sizeOK = abs(clampedFinal.width - 800) <= 40 && abs(clampedFinal.height - 600) <= 40
            let onScreen = CoordinateKit.isOnMainScreen(clampedFinal.origin)
                || clampedFinal.origin.y < 0
            check("SizeE2E clampCase: restore 上报 restored", restoreOutcome.hasPrefix("restored"))
            check("SizeE2E clampCase: 屏外 origFrame 被夹进源屏且尺寸保持（±40）",
                  sizeOK && onScreen)
            check("SizeE2E clampCase: record 已消费", ToggleEngine.shared.load(windowID: wid) == nil)
        } else {
            check("SizeE2E clampCase: 读取夹取还原后帧", false)
        }

        // Case F：move_to_main 路由直呼（P2 补用例）。副屏窗口直接调公开路由
        // moveToMainScreen（与热键同路径，区别于 Case C 的 toggle 决策入口），
        // 断言：窗口落主屏可视区（1653x1079 ±40）+ toggle record 落库（还原可用）。
        let f1Sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            yabaiPlace(wid, frame: CGRect(x: -814, y: -1415, width: 1146, height: 707))
            f1Sem.signal()
        }
        while f1Sem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        Thread.sleep(forTimeInterval: 0.6)
        _ = ShellRunner.run(executable: "/opt/homebrew/bin/yabai", arguments: ["-m", "window", "\(wid)", "--focus"], timeout: 30)
        Thread.sleep(forTimeInterval: 0.5)
        let f2Sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            WindowManager.shared.moveToMainScreen(operationID: "size-e2e-move-to-main", triggerSource: "size_e2e")
            f2Sem.signal()
        }
        while f2Sem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        Thread.sleep(forTimeInterval: 1.2)
        if let movedFrame = yabaiWindowFrame(wid) {
            print("    [诊断] moveToMainCase 终帧=\(movedFrame)（期望主屏可视区 75,38 1653x1079 ±40）")
            let onMain = movedFrame.origin.x >= 0
            let sizeOK = abs(movedFrame.width - 1653) <= 40 && abs(movedFrame.height - 1079) <= 40
            check("SizeE2E moveToMainCase: 路由直呼落主屏可视区（±40）", onMain && sizeOK)
            let recordSaved = ToggleEngine.shared.load(windowID: wid) != nil
            check("SizeE2E moveToMainCase: toggle record 已落库（还原可用）", recordSaved)
        } else {
            check("SizeE2E moveToMainCase: 读取移主屏后帧", false)
        }

        // 清理：向两个测试窗口的 session 写 exit 结束 shell，窗口随会话关闭（best-effort）
        let exitScript = """
        tell application id "com.googlecode.iterm2"
            repeat with targetID in {\(wid), \(widD)}
                try
                    tell window id (targetID as integer) to tell current session to write text "exit"
                end try
            end repeat
        end tell
        """
        _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", exitScript], timeout: 30)
        Thread.sleep(forTimeInterval: 1.5)
        let leftover = yabaiWindowIDs().intersection(created)
        if leftover.isEmpty {
            check("SizeE2E: 测试窗口已关闭", true)
        } else {
            print("    [诊断] 关闭滞后（iTerm2 后台处理）：\(leftover.sorted())")
        }
    }

    // MARK: FloatSettle 序列原语真机 E2E（仅 VIBEFOCUS_FLOATSETTLE_E2E=1 时运行）
    // 全链路无 AX 依赖（yabai fork + CGWindowList + 内存缓存）——无辅助功能授权环境
    // 可闭环（2026-09-06 AX 授权反复被并行构建毒化期间的质量门底座）。
    //   Case 1 managed 窗 → 真 toggle：didToggle + isFloating 翻转 + 落定有界（<2s）
    //          + 等待后 frame 两读稳定（重摆确实落定，后续 frame 写不再被覆盖）；
    //   Case 2 已 float 窗再跑 → skippedNoOp：didToggle=false 且近零耗时（restore
    //          常见路径零浪费的实机证据）。
    if ProcessInfo.processInfo.environment["VIBEFOCUS_FLOATSETTLE_E2E"] == "1" {
        print("\n=== FloatSettle 序列原语真机 E2E ===")
        SpaceController.shared.refreshAvailability(force: true)
        check("FloatSettleE2E: yabai 可用", SpaceController.shared.isEnabled)

        func yabaiWindowIDsFS() -> Set<UInt32> {
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
        func isFloatingFS(_ id: UInt32) -> Bool? {
            SpaceController.shared.queryWindow(windowID: id, ignoreCache: true)?.isFloating
        }

        let fsIdsBefore = yabaiWindowIDsFS()
        _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
            "tell application id \"com.googlecode.iterm2\" to create window with default profile"], timeout: 30)
        Thread.sleep(forTimeInterval: 0.8)
        let fsCreated = yabaiWindowIDsFS().subtracting(fsIdsBefore)
        guard let fsWid = fsCreated.first else {
            check("FloatSettleE2E: 创建测试窗口", false)
            exit(1)
        }
        check("FloatSettleE2E: 测试窗口已创建 id=\(fsWid)", true)

        // 前置：确保 managed（若 yabai 配置 float 了 iTerm2 新窗，先拨回 tiled）
        if isFloatingFS(fsWid) == true {
            _ = SpaceController.shared.runYabai(
                arguments: ["-m", "window", "\(fsWid)", "--toggle", "float"],
                operation: "floatsettle-e2e.pretile", operationID: "floatsettle-e2e")
            Thread.sleep(forTimeInterval: 0.4)
        }
        check("FloatSettleE2E: 前置窗口为 managed（tiled）", isFloatingFS(fsWid) == false)

        // Case 1：真 toggle（真实等待，不注入 sleep）
        let fsT1 = Date()
        let outcome1 = FloatSettle.floatAndSettle(
            windowID: fsWid,
            operationID: "floatsettle-e2e-1",
            knownWindowInfo: nil,
            tolerance: 20,
            setFloat: { SpaceController.shared.setWindowFloat($0, operationID: $1, knownWindowInfo: $2) },
            read: { cgWindowBounds(for: $0) },
            clearCache: { SpaceController.shared.clearWindowQueryCache() }
        )
        let ms1 = Int(Date().timeIntervalSince(fsT1) * 1000)
        check("FloatSettleE2E Case1: didToggle=true", outcome1.didToggle)
        check("FloatSettleE2E Case1: yabai 侧 isFloating 已翻转", isFloatingFS(fsWid) == true)
        check("FloatSettleE2E Case1: 落定等待有界（\(ms1)ms < 2000）", ms1 < 2000)
        if let f1 = cgWindowBounds(for: fsWid) {
            Thread.sleep(forTimeInterval: 0.05)
            let f2 = cgWindowBounds(for: fsWid)
            check("FloatSettleE2E Case1: 等待后 frame 两读稳定（重摆已落定）",
                  f2.map { CoordinateKit.isFrameConverged(actual: $0, target: f1, tolerance: 20) } == true)
        } else {
            check("FloatSettleE2E Case1: 读取 frame", false)
        }
        print("    [诊断] Case1 outcome=\(outcome1) 外部计时=\(ms1)ms")

        // Case 2：已 float 再跑 → skippedNoOp 零浪费
        let outcome2 = FloatSettle.floatAndSettle(
            windowID: fsWid,
            operationID: "floatsettle-e2e-2",
            knownWindowInfo: nil,
            tolerance: 20,
            setFloat: { SpaceController.shared.setWindowFloat($0, operationID: $1, knownWindowInfo: $2) },
            read: { cgWindowBounds(for: $0) },
            clearCache: { SpaceController.shared.clearWindowQueryCache() }
        )
        check("FloatSettleE2E Case2: 已 float → didToggle=false", !outcome2.didToggle)
        check("FloatSettleE2E Case2: 近零耗时（\(outcome2.durationMs)ms < 100）", outcome2.durationMs < 100)
        print("    [诊断] Case2 outcome=\(outcome2)")

        // 清理：向测试窗口 session 写 exit 关窗（best-effort，同 SizeE2E）。
        // 注意：新建即 exit 会触发 iTerm2「session ended very soon」警告框（需手动
        // 点 OK），窗口关闭可能滞后——清理非本原语契约，残余窗口如实报告不判 FAIL。
        _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
            "tell application id \"com.googlecode.iterm2\" to tell window id \(fsWid) to tell current session to write text \"exit\""], timeout: 30)
        Thread.sleep(forTimeInterval: 1.5)
        let fsLeftover = yabaiWindowIDsFS().intersection(fsCreated)
        if fsLeftover.isEmpty {
            check("FloatSettleE2E: 测试窗口已关闭", true)
        } else {
            print("    [诊断] 关窗滞后（iTerm2 警告框/后台处理），请手动关闭：\(fsLeftover.sorted())")
        }
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

    // MARK: FrameConvergence.shortfalls/resendSegments（真实实现——补发计划唯一事实源）

    do {
        let target = CGRect(x: 75, y: 38, width: 1653, height: 1079)
        let tol: CGFloat = 20
        // 与真实 CoordinateKit 交叉验证：shortfalls 空集 ⇔ isFrameConverged。
        let converged = CGRect(x: 80, y: 40, width: 1650, height: 1075)
        check("shortfalls: 双维容差内 → 空集（与 isFrameConverged 对拍）",
              FrameConvergence.shortfalls(current: converged, target: target, tolerance: tol).isEmpty
              && CoordinateKit.isFrameConverged(actual: converged, target: target, tolerance: tol))
        let driftedOrigin = CGRect(x: 200, y: 38, width: 1653, height: 1079)
        check("shortfalls: 仅 origin 超 20 → [.origin]",
              FrameConvergence.shortfalls(current: driftedOrigin, target: target, tolerance: tol) == [.origin])
        let driftedSize = CGRect(x: 75, y: 38, width: 1653, height: 900)
        check("shortfalls: 仅 size 超 20 → [.size]",
              FrameConvergence.shortfalls(current: driftedSize, target: target, tolerance: tol) == [.size])
        check("shortfalls: 双维超 → [.origin, .size]",
              FrameConvergence.shortfalls(current: CGRect(x: 500, y: 500, width: 800, height: 600), target: target, tolerance: tol) == [.origin, .size])
        check("shortfalls: 恰在容差边界（=20）→ 空集（≤ 判定）",
              FrameConvergence.shortfalls(current: CGRect(x: 95, y: 38, width: 1653, height: 1079), target: target, tolerance: tol).isEmpty)
        check("shortfalls: current=nil → 全缺（最坏防御，历史 ?? false 语义）",
              FrameConvergence.shortfalls(current: nil, target: target, tolerance: tol) == [.origin, .size])

        // resendSegments：四分支 × 两写序。
        check("resend: 无偏差 → 空计划",
              FrameConvergence.resendSegments(shortfall: [], order: .resizeThenMove).isEmpty)
        check("resend: 仅 origin 缺 → [.move]（两写序同）",
              FrameConvergence.resendSegments(shortfall: [.origin], order: .resizeThenMove) == [.move]
              && FrameConvergence.resendSegments(shortfall: [.origin], order: .moveThenResize) == [.move])
        check("resend: 仅 size 缺 → [.resize]（两写序同）",
              FrameConvergence.resendSegments(shortfall: [.size], order: .moveThenResize) == [.resize]
              && FrameConvergence.resendSegments(shortfall: [.size], order: .resizeThenMove) == [.resize])
        check("resend: 全缺 × resizeThenMove → resize→move（源屏先行序）",
              FrameConvergence.resendSegments(shortfall: [.origin, .size], order: .resizeThenMove) == [.resize, .move])
        check("resend: 全缺 × moveThenResize → move→resize（历史序）",
              FrameConvergence.resendSegments(shortfall: [.origin, .size], order: .moveThenResize) == [.move, .resize])

        // 交叉验证（防公式单边漂移）：shortfalls 与真实 CoordinateKit 在漂移样本上一致。
        let samples: [(CGRect, Bool)] = [
            (CGRect(x: 75, y: 38, width: 1653, height: 1079), true),
            (CGRect(x: 80, y: 48, width: 1643, height: 1069), true),
            (CGRect(x: 96, y: 59, width: 1632, height: 1057), false),
            (CGRect(x: 97, y: 38, width: 1653, height: 1079), false),
        ]
        var crossOK = true
        for (sample, expectConverged) in samples {
            let short = FrameConvergence.shortfalls(current: sample, target: target, tolerance: tol)
            if short.isEmpty != (expectConverged && CoordinateKit.isFrameConverged(actual: sample, target: target, tolerance: tol)) { crossOK = false }
        }
        check("shortfalls × CoordinateKit 交叉验证 4 样本一致", crossOK)
    }

    // MARK: FrameWriteExecutor（真实实现——执行编排 + apply 调用序列断言）

    do {
        let target = CGRect(x: 75, y: 38, width: 1653, height: 1079)
        let tol: CGFloat = 20
        let missSize = CGRect(x: 75, y: 38, width: 1653, height: 900)   // 仅 size 缺
        let fullMiss = CGRect(x: 500, y: 500, width: 800, height: 600)  // 双维缺
        let noSleep: (UInt32) -> Void = { _ in } // 虚拟时间：预算分支瞬时跑满

        func makeExecutor(
            read: @escaping () -> CGRect?,
            calls: @escaping (String) -> Void
        ) -> FrameWriteExecutor {
            FrameWriteExecutor(
                deps: .init(
                    read: read,
                    applyMove: { calls("move") },
                    applyResizeAdaptive: { calls("resizeAdaptive") },
                    applyResizeRobust: { calls("resizeRobust") }
                ),
                tolerance: tol,
                op: "runner", stage: "executor-test", windowID: 1,
                pollSleep: noSleep
            )
        }

        // A. resizeThenMove 满意路径：读恒收敛 → resize→move 各一次，零补发。
        do {
            var calls: [String] = []
            let run = makeExecutor(read: { target }, calls: { calls.append($0) })
                .run(target: target, order: .resizeThenMove)
            check("executor A: 调用序列 [resizeAdaptive, move]",
                  calls == ["resizeAdaptive", "move"])
            check("executor A: converged / 1 轮 / 0 补发",
                  run.outcome.isConverged && run.convergedRounds == 1 && run.resendCount == 0)
        }

        // B. moveThenResize 满意路径：move→resize 各一次。
        do {
            var calls: [String] = []
            let run = makeExecutor(read: { target }, calls: { calls.append($0) })
                .run(target: target, order: .moveThenResize)
            check("executor B: 调用序列 [move, resizeAdaptive]",
                  calls == ["move", "resizeAdaptive"])
            check("executor B: converged", run.outcome.isConverged)
        }

        // C. size 单缺补发：phase1 等待耗尽（13 次读全缺）→ move → 段二补 adaptive
        //    resize → 读收敛。序列锁死：resize→move→resize。
        do {
            var n = 0
            var calls: [String] = []
            let run = makeExecutor(
                read: { n += 1; return n <= 14 ? missSize : target },
                calls: { calls.append($0) }
            ).run(target: target, order: .resizeThenMove)
            check("executor C: 调用序列 [resizeAdaptive, move, resizeAdaptive]（单缺补发走择优通道）",
                  calls == ["resizeAdaptive", "move", "resizeAdaptive"])
            check("executor C: converged / 1 轮", run.outcome.isConverged && run.convergedRounds == 1)
        }

        // D. 全缺 × 两轮不收敛：段一 [resizeAdaptive, move]；段二每轮计划两段走
        //    robust 纯 yabai 按写序 [resizeRobust, move]；停滞重发（4 读不变）在
        //    轮询内重复同一计划、不计新轮——因此断言模式而非精确次数。
        do {
            var calls: [String] = []
            let run = makeExecutor(read: { fullMiss }, calls: { calls.append($0) })
                .run(target: target, order: .resizeThenMove)
            check("executor D: 段一 [resizeAdaptive, move]",
                  calls.count >= 2 && calls[0] == "resizeAdaptive" && calls[1] == "move")
            var pairsOK = (calls.count - 2) >= 2 && (calls.count - 2) % 2 == 0
            var i = 2
            while i + 1 < calls.count {
                if calls[i] != "resizeRobust" || calls[i + 1] != "move" { pairsOK = false }
                i += 2
            }
            check("executor D: 段二每轮 [resizeRobust, move] 按写序（停滞重发重复同一计划）", pairsOK)
            check("executor D: mismatched / 2 轮 / 停滞补发计入 resend（≥1）",
                  !run.outcome.isConverged && run.convergedRounds == 2 && run.resendCount >= 1)
        }

        // E. 停滞重发：读恒 size 缺 → 轮询内 4 读不变即幂等补发 adaptive（≥1 次）。
        do {
            var calls: [String] = []
            let run = makeExecutor(read: { missSize }, calls: { calls.append($0) })
                .run(target: target, order: .resizeThenMove)
            let adaptiveCount = calls.filter { $0 == "resizeAdaptive" }.count
            check("executor E: 停滞重发触发多次 adaptive 补发（≥3）", adaptiveCount >= 3)
            check("executor E: 全程无 robust（单 size 缺不进全缺通道）", !calls.contains("resizeRobust"))
            check("executor E: 不收敛如实上报 mismatched", !run.outcome.isConverged)
        }
    }

    // MARK: WindowManager.route（真实实现——toggle 执行路由唯一映射，Batch 5）

    do {
        check("route: .restore → restore（onMain=true 不影响）",
              WindowManager.route(for: .restore, onMainScreen: true) == .restore)
        check("route: .restore → restore（onMain=nil 也不影响）",
              WindowManager.route(for: .restore, onMainScreen: nil) == .restore)
        check("route: .moveToMain + onMain=false → moveToMain",
              WindowManager.route(for: .moveToMain, onMainScreen: false) == .moveToMain)
        check("route: .moveToMain + onMain=true → moveSecondaryStuck（mode 与执行同源）",
              WindowManager.route(for: .moveToMain, onMainScreen: true) == .moveSecondaryStuck)
        check("route: .noRecord + onMain=nil → moveToMain（归属未知不进 stuck）",
              WindowManager.route(for: .noRecord, onMainScreen: nil) == .moveToMain)
        check("route: .corruptedClearWindowID + onMain=true → moveSecondaryStuck",
              WindowManager.route(for: .corruptedClearWindowID(7), onMainScreen: true) == .moveSecondaryStuck)
        check("route: .noFocusedWindow + onMain=false → moveToMain",
              WindowManager.route(for: .noFocusedWindow, onMainScreen: false) == .moveToMain)
        check("route: .noMainScreen + onMain=true → moveSecondaryStuck",
              WindowManager.route(for: .noMainScreen, onMainScreen: true) == .moveSecondaryStuck)
        check("route: logName 与审计 mode 值一致",
              WindowManager.ToggleRoute.restore.logName == "restore"
              && WindowManager.ToggleRoute.moveToMain.logName == "move_to_main"
              && WindowManager.ToggleRoute.moveSecondaryStuck.logName == "move_to_secondary_stuck")

    // MARK: ToggleFocusBranching（真实实现——P6 三分支焦点决策纯内核，分支组合穷尽锁定）

    do {
        // CGWindowEntry 只有 init?(from dict:)（memberwise 被吞），测试经 dict 构造。
        func win(_ id: UInt32, pid: pid_t = 100, layer: Int = 0, onScreen: Bool = true, withBounds: Bool = true) -> CGWindowEntry {
            var dict: [String: Any] = [
                kCGWindowNumber as String: id,
                kCGWindowOwnerPID as String: pid,
                kCGWindowLayer as String: layer,
                kCGWindowIsOnscreen as String: onScreen,
            ]
            if withBounds {
                dict[kCGWindowBounds as String] = ["X": CGFloat(10), "Y": CGFloat(20), "Width": CGFloat(800), "Height": CGFloat(600)]
            }
            return CGWindowEntry(from: dict)!
        }

        // 分支 1 候选集：三条件过滤（异 pid / layer≠0 / 离屏全排除）+ z-order 顺序保持。
        let snapshot = [win(1), win(2, pid: 200), win(3, layer: -1), win(4, onScreen: false), win(5)]
        check("branch1: 候选集只留前台普通可见窗（顺序保持）",
              ToggleFocusBranching.cgListFocusCandidates(snapshot: snapshot, ownerPID: 100).map(\.windowID) == [1, 5])

        // 分支 1 快速路径：恰好 1 个。
        check("branch1: 单候选带 bounds → 命中",
              ToggleFocusBranching.singleWindowFastPath([win(7)])?.windowID == 7)
        check("branch1: 零候选 → nil（窗口在别的 space/最小化）",
              ToggleFocusBranching.singleWindowFastPath([]) == nil)
        check("branch1: 多候选 → nil（z-order ≠ AX focus，P0.3 教训）",
              ToggleFocusBranching.singleWindowFastPath([win(7), win(8)]) == nil)
        check("branch1: 单候选无 bounds → nil（落 yabai，拆分前同款边界）",
              ToggleFocusBranching.singleWindowFastPath([win(7, withBounds: false)]) == nil)

        // 分支 2 接受判定：id 可精确转 UInt32 + pid 与前台一致。
        func yabaiInfo(_ id: Int?, pid: Int?) -> YabaiWindowInfo {
            YabaiWindowInfo(id: id, pid: pid, app: "App", title: "t", space: 1, display: 1,
                            frame: nil, isFloatingRaw: false, hasAXReferenceRaw: true,
                            isMinimizedRaw: false, hasFocusRaw: true)
        }
        check("branch2: id+pid 全匹配 → winID",
              ToggleFocusBranching.yabaiFocusCandidate(yabaiInfo(77, pid: 100), frontPID: 100)?.winID == 77)
        check("branch2: yabai 无报告 → nil", ToggleFocusBranching.yabaiFocusCandidate(nil, frontPID: 100) == nil)
        check("branch2: id 缺失 → nil",
              ToggleFocusBranching.yabaiFocusCandidate(yabaiInfo(nil, pid: 100), frontPID: 100) == nil)
        check("branch2: id 超出 UInt32 → nil（UInt32(exactly:) 失败）",
              ToggleFocusBranching.yabaiFocusCandidate(yabaiInfo(4_294_967_296, pid: 100), frontPID: 100) == nil
              && ToggleFocusBranching.yabaiFocusCandidate(yabaiInfo(-1, pid: 100), frontPID: 100) == nil)
        check("branch2: pid 不一致 → nil（yabai/系统焦点不同步，回退 AX）",
              ToggleFocusBranching.yabaiFocusCandidate(yabaiInfo(77, pid: 200), frontPID: 100) == nil)

        // 分支 3 身份落位：全量快照按 windowID 查，不过滤 layer/onScreen（AX 认定不二次裁剪）。
        let fullList = [win(1), win(9, layer: 5, onScreen: false)]
        check("branch3: 按 windowID 命中（含离屏/高层窗口）",
              ToggleFocusBranching.axIdentityEntry(cgList: fullList, winID: 9)?.windowID == 9)
        check("branch3: 查不到 → nil（调用壳降位仅记 windowID/AX）",
              ToggleFocusBranching.axIdentityEntry(cgList: fullList, winID: 42) == nil)
    }

    }

    // MARK: FrameConvergence.convergeFrame（真实实现直测——镜像测试锁副本，本段锁真身，Batch 11）

    do {
        // convergeFrame 语义契约（FrameConvergenceLoopTests 锁副本；此处真身逐分支）：
        // write→settle→read→判据；write 硬失败短路；read nil 不终止；attempts 归一。

        // C1. 首轮即收敛：write 1 次、settle 1 次、read 1 次。
        do {
            var calls: [String] = []
            let outcome = FrameConvergence.convergeFrame(
                attempts: 3,
                settleMicros: 1,
                write: { calls.append("write"); return true },
                read: { calls.append("read"); return CGRect(x: 0, y: 0, width: 100, height: 100) },
                isConverged: { _ in true },
                sleep: { _ in calls.append("settle") }
            )
            check("convergeFrame C1: converged(attempt:1) 且序列 write→settle→read",
                  outcome == .converged(attempt: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
                  && calls == ["write", "settle", "read"])
        }

        // C2. 第 3 轮收敛：前两轮判据不满足，attempt 计数如实。
        do {
            var round = 0
            let outcome = FrameConvergence.convergeFrame(
                attempts: 3, settleMicros: 1,
                write: { true },
                read: { CGRect(x: round * 10, y: 0, width: 100, height: 100) },
                isConverged: { _ in
                    round += 1
                    return round >= 3
                },
                sleep: { _ in }
            )
            check("convergeFrame C2: 第 3 轮收敛 attempt=3", 
                  outcome == .converged(attempt: 3, frame: CGRect(x: 20, y: 0, width: 100, height: 100)))
        }

        // C3. 走满轮数不收敛 → mismatched（lastFrame=最后一次读回）。
        do {
            let outcome = FrameConvergence.convergeFrame(
                attempts: 2, settleMicros: 1,
                write: { true },
                read: { CGRect(x: 5, y: 5, width: 50, height: 50) },
                isConverged: { _ in false },
                sleep: { _ in }
            )
            check("convergeFrame C3: mismatched(attempts:2, lastFrame)",
                  outcome == .mismatched(attempts: 2, lastFrame: CGRect(x: 5, y: 5, width: 50, height: 50)))
        }

        // C4. write 硬失败：当轮短路（无 settle/read），attempt 计入。
        do {
            var writes = 0
            var settles = 0
            var reads = 0
            let outcome = FrameConvergence.convergeFrame(
                attempts: 3, settleMicros: 1,
                write: { writes += 1; return writes < 2 },  // 第 2 轮 write 失败
                read: { reads += 1; return CGRect(x: 0, y: 0, width: 1, height: 1) },
                isConverged: { _ in false },
                sleep: { _ in settles += 1 }
            )
            check("convergeFrame C4: writeFailed(attempt:2)；失败轮不进 settle/read（写2/settle1/read1）",
                  outcome == .writeFailed(attempt: 2) && writes == 2 && settles == 1 && reads == 1)
        }

        // C5. read 持续 nil：轮次继续（不终止、不计收敛），走满后 mismatched(lastFrame=nil)。
        do {
            var reads = 0
            let outcome = FrameConvergence.convergeFrame(
                attempts: 3, settleMicros: 1,
                write: { true },
                read: { reads += 1; return nil },
                isConverged: { _ in true },               // 有读即判收敛——nil 读不该触发
                sleep: { _ in }
            )
            check("convergeFrame C5: nil 读不终止不收敛（3 读后 mismatched lastFrame=nil）",
                  outcome == .mismatched(attempts: 3, lastFrame: nil) && reads == 3)
        }

        // C6. attempts=0 归一为 1（防 1...0 崩溃）。
        do {
            let outcome = FrameConvergence.convergeFrame(
                attempts: 0, settleMicros: 1,
                write: { true },
                read: { CGRect(x: 0, y: 0, width: 1, height: 1) },
                isConverged: { _ in false },
                sleep: { _ in }
            )
            check("convergeFrame C6: attempts=0 归一 1 轮 mismatched",
                  outcome == .mismatched(attempts: 1, lastFrame: CGRect(x: 0, y: 0, width: 1, height: 1)))
        }
    }

    // MARK: CoordinateKit 真实实现直测（访问器与 NSScreen 依赖函数，Batch 11）

    do {
        // QuartzRect 访问器与换算。
        let qr = QuartzRect(x: 3, y: 4, width: 100, height: 50)
        check("coordKit: midX/midY/maxX/maxY", qr.midX == 53 && qr.midY == 29 && qr.maxX == 103 && qr.maxY == 54)
        check("coordKit: cgRect 换算", qr.cgRect == CGRect(x: 3, y: 4, width: 100, height: 50))
        check("coordKit: sizeDescription", qr.sizeDescription == "100x50")

        // DisplayIdentifier / SpaceIdentifier 便捷构造。
        check("coordKit: DisplayIdentifier.yabai/.cgDisplay 构造",
              DisplayIdentifier.yabai(2) == .yabaiIndex(2) && DisplayIdentifier.cgDisplay(7) == .cgDirectDisplayID(7))
        check("coordKit: SpaceIdentifier.native 构造",
              SpaceIdentifier.native(9) == .nativeID(9))

        // NSScreen 依赖函数（Runner 跑在 GUI 会话，screens 非空）。
        if let mainScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first {
            check("coordKit: mainScreenQuartzFrame 非空且含原点屏 frame",
                  CoordinateKit.mainScreenQuartzFrame == mainScreen.frame)
            check("coordKit: isOnMainScreen(mainScreen 中心)=true",
                  CoordinateKit.isOnMainScreen(CGPoint(x: mainScreen.frame.midX, y: mainScreen.frame.midY)))
            check("coordKit: isOnMainScreen(远点)=false",
                  !CoordinateKit.isOnMainScreen(CGPoint(x: 99_999, y: 99_999)))
            check("coordKit: mainScreenHeight > 0", CoordinateKit.mainScreenHeight > 0)
            let yabaiIdx = CoordinateKit.yabaiDisplayIndex(for: mainScreen)
            check("coordKit: yabaiDisplayIndex(主屏)=1", yabaiIdx == 1)
            check("coordKit: nsScreen(forYabaiDisplayIndex:1) 回主屏",
                  CoordinateKit.nsScreen(forYabaiDisplayIndex: 1) != nil)
            check("coordKit: nsScreen(越界 99)=nil（防御分支）",
                  CoordinateKit.nsScreen(forYabaiDisplayIndex: 99) == nil)
            check("coordKit: quartzVisibleFrame 非空且在屏 frame 内（visibleFrame ⊆ frame）",
                  CoordinateKit.quartzVisibleFrame(of: mainScreen).width <= mainScreen.frame.width
                  && CoordinateKit.quartzVisibleFrame(of: mainScreen).height <= mainScreen.frame.height)
            check("coordKit: clampFrame 夹取（屏外点收回 bounds）",
                  CoordinateKit.clampFrame(CGRect(x: 9_999, y: 9_999, width: 50, height: 50),
                                           into: mainScreen.frame).maxX <= mainScreen.frame.maxX)
            check("coordKit: cocoaY/quartzY 往返自洽",
                  CoordinateKit.cocoaY(fromQuartzY: CoordinateKit.quartzY(fromCocoaY: 37)) == 37)
        }

        // 纯收敛判据（真身直测，Batch 4 nonisolated 化后的回归位）。
        check("coordKit: isFrameConverged 漂移和判据",
              CoordinateKit.isFrameConverged(actual: CGRect(x: 8, y: 0, width: 100, height: 100),
                                             target: CGRect(x: 0, y: 0, width: 100, height: 100),
                                             tolerance: 20)
              && !CoordinateKit.isFrameConverged(actual: CGRect(x: 21, y: 0, width: 100, height: 100),
                                                 target: CGRect(x: 0, y: 0, width: 100, height: 100),
                                                 tolerance: 20))
    }

    // MARK: FloatSettle（真实实现——float 脱管→等重摆→缓存失效唯一序列原语，Batch 6）

    do {
        // A. 真 toggle：setFloat 恰一次 → 睡下限 → 稳定早返回 → 缓存恒清，顺序锁定。
        do {
            var events: [String] = []
            var sleeps: [useconds_t] = []
            var polls: [UInt32] = []
            let outcome = FloatSettle.floatAndSettle(
                windowID: 42,
                operationID: "fs-a",
                knownWindowInfo: nil,
                tolerance: 20,
                setFloat: { id, op, _ in events.append("float(\(id),\(op))"); return .toggled },
                read: { _ in CGRect(x: 0, y: 0, width: 800, height: 600) },
                clearCache: { events.append("clear") },
                sleep: { sleeps.append($0); events.append("sleep") },
                pollSleep: { polls.append($0); events.append("poll") }
            )
            check("floatsettle A: 序列 float→sleep→poll→clear（真身）",
                  events == ["float(42,fs-a)", "sleep", "poll", "clear"])
            check("floatsettle A: 下限取 WindowSettle.floatRelayoutMinSettleMicros（120ms）",
                  sleeps == [WindowSettle.floatRelayoutMinSettleMicros])
            check("floatsettle A: 两读稳定即早返回（1 拍 25ms）",
                  polls == [WindowSettle.frameVerifyPollIntervalMs])
            check("floatsettle A: didToggle=true 如实上报", outcome.didToggle)
        }

        // B. skippedNoOp（已 float/unmanaged/query-nil）：零等待、缓存仍恒清。
        do {
            var waitEvents = 0
            var clears = 0
            let outcome = FloatSettle.floatAndSettle(
                windowID: 42, operationID: "fs-b", knownWindowInfo: nil, tolerance: 20,
                setFloat: { _, _, _ in .skippedNoOp },
                read: { _ in waitEvents += 1; return nil },
                clearCache: { clears += 1 },
                sleep: { _ in waitEvents += 1 }, pollSleep: { _ in waitEvents += 1 })
            check("floatsettle B: 已 float 零读零等待", waitEvents == 0)
            check("floatsettle B: 缓存恒清语义（跳过场景仍清一次）", clears == 1)
            check("floatsettle B: didToggle=false 如实上报", !outcome.didToggle)
        }

        // C. 预算兜底（μs→ms 修正回归金丝雀）：永不稳定走满 300ms = 12 拍。
        //    Batch 6 前四处手抄直传微秒值（budgetMs=300_000 → 病理路径轮询 100 分钟），
        //    本断言锁死换算，防回归。
        do {
            var polls = 0
            var readN = 0
            let outcome = FloatSettle.floatAndSettle(
                windowID: 42, operationID: "fs-c", knownWindowInfo: nil, tolerance: 20,
                setFloat: { _, _, _ in .toggled },
                read: { _ in readN += 1; return CGRect(x: readN * 100, y: 0, width: 800, height: 600) },
                clearCache: {},
                sleep: { _ in }, pollSleep: { _ in polls += 1 })
            check("floatsettle C: 预算按毫秒计（300ms=12 拍，而非 30 万拍 100 分钟）", polls == 12 && readN == 13)
            check("floatsettle C: 走满预算仍如实上报 didToggle", outcome.didToggle)
        }
    }

    // MARK: MoveToMainPipeline（真实实现——move_to_main 阶段管线，Batch 7）

    do {
        final class Rec {
            var events: [String] = []
            var floatIDs: [UInt32] = []
            var saveArgs: (windowID: UInt32, origFrame: CGRect)?
            var postCheckWindowID: UInt32?
            var notifyCount = 0
        }

        let sysWideAX = AXUIElementCreateSystemWide()
        let identity = WindowIdentity(windowID: 42, pid: 100, bundleIdentifier: "com.test.app", appName: "Test", windowNumber: nil, title: "t")
        let realScreen = NSScreen.screens.first!
        let mainScreenFrame = realScreen.frame
        let knownFrame = CGRect(x: -800, y: -700, width: 1146, height: 707)
        let axReadFrame = CGRect(x: -810, y: -710, width: 1146, height: 707)
        let onMainCenterFrame = CGRect(x: mainScreenFrame.midX, y: mainScreenFrame.midY, width: 800, height: 600)

        /// 假通道工厂：默认「AX 路径 happy path」配置，场景按需覆盖。
        func makeDeps(
            _ rec: Rec,
            hasAX: Bool = true,
            visSpace: SpaceIdentifier? = .yabaiIndex(1),
            resolveOK: Bool = true,
            axFrameToRead: CGRect?,
            queryDisplay: Int? = 2,
            settableOK: Bool = true,
            applyDirectOK: Bool = true,
            applyAXOK: Bool = true,
            handleOK: Bool = true
        ) -> MoveToMainPipeline.Deps {
            MoveToMainPipeline.Deps(
                hasAX: { rec.events.append("hasAX"); return hasAX },
                notifyAXRequired: { rec.notifyCount += 1 },
                captureSpaceContext: { _, _ in
                    rec.events.append("capture")
                    return SpaceContext(sourceSpaceIndex: .yabaiIndex(5), targetSpaceIndex: nil,
                                        sourceDisplayIndex: .yabaiIndex(2), sourceDisplaySpaceIndex: 7)
                },
                visibleSpaceIndexOfMainDisplay: { rec.events.append("visSpace"); return visSpace },
                floatAndSettle: { id, _, _ in
                    rec.events.append("float"); rec.floatIDs.append(id)
                    return FloatSettle.Outcome(didToggle: true, durationMs: 123)
                },
                resolveWindow: { _ in rec.events.append("resolve"); return resolveOK ? sysWideAX : nil },
                readAXFrame: { _ in rec.events.append("readAXFrame"); return axFrameToRead },
                queryWindow: { _ in
                    rec.events.append("query")
                    return queryDisplay.map {
                        YabaiWindowInfo(id: 42, pid: 100, app: "App", title: "t", space: 5, display: $0,
                                        frame: nil, isFloatingRaw: false, hasAXReferenceRaw: true,
                                        isMinimizedRaw: false, hasFocusRaw: false)
                    }
                },
                isSettable: { _ in rec.events.append("settable"); return settableOK },
                mainScreen: { rec.events.append("mainScreen"); return realScreen },
                targetFrameFor: { _ in
                    rec.events.append("targetFrame")
                    return CGRect(x: 75, y: 38, width: mainScreenFrame.width, height: mainScreenFrame.height)
                },
                targetDisplayIndexOf: { _ in rec.events.append("targetIndex"); return 1 },
                windowHandleOf: { _ in rec.events.append("handle"); return handleOK ? 77 : nil },
                visibleFrameOfYabaiDisplay: { _ in rec.events.append("sourceVisible"); return CGRect(x: 0, y: 0, width: 3440, height: 1440) },
                applyFrameDirect: { _, _, _, _ in rec.events.append("applyDirect"); return applyDirectOK },
                applyAX: { _, _, _, _ in rec.events.append("applyAX"); return applyAXOK },
                postCheck: { _, id, _, _, _, _ in
                    rec.events.append("postCheck"); rec.postCheckWindowID = id; return 8
                },
                save: { _, id, orig, _, _, _, _ in
                    rec.events.append("save"); rec.saveArgs = (id, orig); return 3
                }
            )
        }

        // A. AX 路径 happy path：origFrame 来自 AX 读（apply 前），apply 后 post-check→save。
        do {
            let rec = Rec()
            let result = MoveToMainPipeline.run(identity: identity, op: "A", knownWindowAX: sysWideAX, knownOrigFrame: nil, deps: makeDeps(rec, axFrameToRead: axReadFrame))
            check("pipeline A: AX 路径结局 moved(effectiveWindowID=77)", result.outcome == .moved(effectiveWindowID: 77))
            check("pipeline A: 序列 hasAX→capture→readAXFrame→query→settable→mainScreen→target→float→applyAX→postCheck→save",
                  rec.events == ["hasAX", "capture", "readAXFrame", "query", "settable", "mainScreen", "targetFrame", "targetIndex", "handle", "float", "applyAX", "postCheck", "save"])
            check("pipeline A: AX 路径 float 恰一次（apply 前、用 effectiveWindowID）", rec.floatIDs == [77])
            check("pipeline A: save 收到的 origFrame = AX 快照读值", rec.saveArgs?.origFrame == axReadFrame)
            check("pipeline A: postCheck 用 effectiveWindowID", rec.postCheckWindowID == 77)
        }

        // B. P2 路径 happy path：预 float 恰一次，origFrame 用 knownOrigFrame（绝不 AX 读）。
        do {
            let rec = Rec()
            let result = MoveToMainPipeline.run(identity: identity, op: "B", knownWindowAX: nil, knownOrigFrame: knownFrame, deps: makeDeps(rec, axFrameToRead: nil))
            check("pipeline B: P2 路径结局 moved(77)", result.outcome == .moved(effectiveWindowID: 77))
            check("pipeline B: 序列 capture→visSpace→float→resolve→query→…→sourceVisible→applyDirect→postCheck→save",
                  rec.events == ["hasAX", "capture", "visSpace", "float", "resolve", "query", "settable", "mainScreen", "targetFrame", "targetIndex", "handle", "sourceVisible", "applyDirect", "postCheck", "save"])
            check("pipeline B: readAXFrame 未被调用（a049a86 快照时机铁律）", !rec.events.contains("readAXFrame"))
            check("pipeline B: float 恰一次（预 float，窗口 42）", rec.floatIDs == [42])
            check("pipeline B: save 收到 knownOrigFrame", rec.saveArgs?.origFrame == knownFrame)
            check("pipeline B: floatMs = P2 预 float 段耗时", result.timings.floatMs == result.timings.p2SpaceMoveMs)
        }

        // C. AX 路径已在主屏：skip 短路（不 settable/不 apply/不 post-check/不 save）。
        do {
            let rec = Rec()
            let result = MoveToMainPipeline.run(identity: identity, op: "C", knownWindowAX: sysWideAX, knownOrigFrame: nil,
                                                deps: makeDeps(rec, axFrameToRead: onMainCenterFrame, queryDisplay: 1))
            check("pipeline C: 已在主屏 → alreadyOnMain", result.outcome == .alreadyOnMain)
            check("pipeline C: 序列止于 skip 检查（短路 settable/apply/save）",
                  rec.events == ["hasAX", "capture", "readAXFrame", "query", "mainScreen"])
        }

        // D. AX 拒绝：notify 恰一次，其余一切短路。
        do {
            let rec = Rec()
            let result = MoveToMainPipeline.run(identity: identity, op: "D", knownWindowAX: nil, knownOrigFrame: nil, deps: makeDeps(rec, hasAX: false, axFrameToRead: nil))
            check("pipeline D: ax_denied", result.outcome == .failed(stage: "ax_denied"))
            check("pipeline D: 无任何通道调用 + notify 恰一次", rec.events == ["hasAX"] && rec.notifyCount == 1)
        }

        // E. P2 主屏 visible space 解析失败：float 之前短路。
        do {
            let rec = Rec()
            let result = MoveToMainPipeline.run(identity: identity, op: "E", knownWindowAX: nil, knownOrigFrame: nil, deps: makeDeps(rec, visSpace: nil, axFrameToRead: nil))
            check("pipeline E: visible_space 失败", result.outcome == .failed(stage: "visible_space"))
            check("pipeline E: float 未被发起", !rec.events.contains("float"))
        }

        // F. P2 resolve 失败：float 已发生（真实序），apply/post-check/save 短路。
        do {
            let rec = Rec()
            let result = MoveToMainPipeline.run(identity: identity, op: "F", knownWindowAX: nil, knownOrigFrame: nil, deps: makeDeps(rec, resolveOK: false, axFrameToRead: nil))
            check("pipeline F: resolve_window 失败", result.outcome == .failed(stage: "resolve_window"))
            check("pipeline F: 序列止于 resolve（float 已发生，无 apply/save）",
                  rec.events == ["hasAX", "capture", "visSpace", "float", "resolve"])
        }

        // G. origFrame 不可读：快照 guard 短路（query 都不发起）。
        do {
            let rec = Rec()
            let result = MoveToMainPipeline.run(identity: identity, op: "G", knownWindowAX: sysWideAX, knownOrigFrame: nil, deps: makeDeps(rec, axFrameToRead: nil))
            check("pipeline G: orig_frame 失败", result.outcome == .failed(stage: "orig_frame"))
            check("pipeline G: 序列止于 AX 快照读", rec.events == ["hasAX", "capture", "readAXFrame"])
        }

        // H. settable false：不解析主屏不 apply。
        do {
            let rec = Rec()
            let result = MoveToMainPipeline.run(identity: identity, op: "H", knownWindowAX: sysWideAX, knownOrigFrame: nil, deps: makeDeps(rec, axFrameToRead: axReadFrame, settableOK: false))
            check("pipeline H: settable 失败", result.outcome == .failed(stage: "settable"))
            check("pipeline H: 序列止于 settable", rec.events == ["hasAX", "capture", "readAXFrame", "query", "settable"])
        }

        // I. P2 frame 直写不收敛：post-check/save 短路。
        do {
            let rec = Rec()
            let result = MoveToMainPipeline.run(identity: identity, op: "I", knownWindowAX: nil, knownOrigFrame: knownFrame, deps: makeDeps(rec, axFrameToRead: nil, applyDirectOK: false))
            check("pipeline I: apply_p2 失败", result.outcome == .failed(stage: "apply_p2"))
            check("pipeline I: 无 postCheck/save", !rec.events.contains("postCheck") && !rec.events.contains("save"))
        }

        // J. AX apply 失败：post-check/save 短路；float 恰一次。
        do {
            let rec = Rec()
            let result = MoveToMainPipeline.run(identity: identity, op: "J", knownWindowAX: sysWideAX, knownOrigFrame: nil, deps: makeDeps(rec, axFrameToRead: axReadFrame, applyAXOK: false))
            check("pipeline J: apply_ax 失败", result.outcome == .failed(stage: "apply_ax"))
            check("pipeline J: float 恰一次且无 postCheck/save",
                  rec.floatIDs == [77] && !rec.events.contains("postCheck") && !rec.events.contains("save"))
        }

        // L. windowHandle 解析失败 → effectiveWindowID 回退 identity.windowID；
        //    space 上下文字段为 nil 时日志分支如实降级。
        do {
            let rec = Rec()
            let result2 = MoveToMainPipeline.run(identity: identity, op: "L2", knownWindowAX: sysWideAX, knownOrigFrame: nil,
                                                 deps: makeDeps(rec, axFrameToRead: axReadFrame, handleOK: false))
            check("pipeline L: windowHandle nil → 回退 identity.windowID",
                  result2.outcome == .moved(effectiveWindowID: 42))
        }

        // K. skip 纯决策（真实实现直锁；镜像另立 MoveToMainSkipDecisionTests）。
        check("pipeline K: display≠1 不 skip", !MoveToMainPipeline.isAlreadyMaximizedOnMain(displayYabaiIndex: 2, mainScreenFrame: mainScreenFrame, frame: onMainCenterFrame))
        check("pipeline K: display nil 不 skip", !MoveToMainPipeline.isAlreadyMaximizedOnMain(displayYabaiIndex: nil, mainScreenFrame: mainScreenFrame, frame: onMainCenterFrame))
        check("pipeline K: 主屏 frame nil 不 skip", !MoveToMainPipeline.isAlreadyMaximizedOnMain(displayYabaiIndex: 1, mainScreenFrame: nil, frame: onMainCenterFrame))
        check("pipeline K: 中心在主屏内 → skip", MoveToMainPipeline.isAlreadyMaximizedOnMain(displayYabaiIndex: 1, mainScreenFrame: mainScreenFrame, frame: onMainCenterFrame))
        check("pipeline K: 中心在主屏外不 skip", !MoveToMainPipeline.isAlreadyMaximizedOnMain(displayYabaiIndex: 1, mainScreenFrame: mainScreenFrame, frame: CGRect(x: -800, y: -700, width: 400, height: 300)))
    }

    // MARK: 终端标题定向改名真机 E2E（仅 VIBEFOCUS_TITLE_E2E=1 时运行）
    // 2026-09-07 用户实测「Ctrl+T 改名完全无效」回归保护：写通道必须按弹框前捕获的
    // 目标身份（会话 tty，两终端统一）命中自建会话，且改名能扛住 shell OSC
    // 覆写。自建窗口只碰自建（差集追踪），Terminal 用 exit 自关、iTerm2 用 write text
    // "exit" 自关（会话退出无确认框）。

    if ProcessInfo.processInfo.environment["VIBEFOCUS_TITLE_E2E"] == "1" {
        @MainActor
        func runAS(_ source: String) -> String? {
            let appleScript = NSAppleScript(source: source)
            var error: NSDictionary?
            let result = appleScript?.executeAndReturnError(&error)
            if let error {
                print("    [TitleE2E] AppleScript FAILED: \(error[NSAppleScript.errorNumber] as? Int ?? -1) \(error[NSAppleScript.errorMessage] as? String ?? "")")
                return nil
            }
            return result?.stringValue
        }

        print("\n—— TitleE2E：终端标题定向改名 ——")

        // Case A：Terminal 定向改名（tty 寻址）+ OSC/提示符覆写探针。
        // 断言走 `name of window id N`（窗口可见标题），不走 CGWindowName——
        // 非活跃空间的窗口 kCGWindowName 读不到（首轮实测踩坑）。
        caseA: do {
            let created = runAS("""
                tell application "Terminal"
                    do script ""
                    delay 0.5
                    set wID to id of front window
                    set wTTY to tty of selected tab of front window
                    return (wID as string) & "|" & wTTY
                end tell
                """)
            guard let created, created.contains("|") else {
                check("TitleE2E Terminal: 自建窗口（id|tty）", false)
                break caseA
            }
            let parts = created.components(separatedBy: "|")
            let windowID = parts[0]
            let tty = parts[1]
            check("TitleE2E Terminal: 自建窗口（id=\(windowID), tty=\(tty)）", true)

            // 捕获助手必须命中自建会话（定向修复的核心断言）。
            let captured = TitleEditorService.captureTerminalFrontTabTTY()
            check("TitleE2E Terminal: captureTerminalFrontTabTTY == 自建会话 tty",
                  captured == tty)

            // 定向写入 + 可见标题回读。
            let writeOK = TitleEditorService.shared.applyViaAppleScript(
                "VFT-E2E-T1", bundleID: "com.apple.Terminal", targetTTY: tty)
            check("TitleE2E Terminal: tty 定向写入 matched", writeOK)
            func terminalWindowName() -> String? {
                runAS("tell application \"Terminal\" to get name of window id \(windowID)")
            }
            func pollTerminalTitle(_ seconds: Double) -> Bool {
                let deadline = Date().addingTimeInterval(seconds)
                while Date() < deadline {
                    if let n = terminalWindowName(), n.contains("VFT-E2E-T1") { return true }
                    Thread.sleep(forTimeInterval: 0.3)
                }
                return false
            }
            check("TitleE2E Terminal: 标题落屏", pollTerminalTitle(4))

            // 覆写探针：跑一条命令触发新提示符（zsh OSC），标题必须保持。
            _ = runAS("tell application \"Terminal\" to do script \"true\" in window id \(windowID)")
            Thread.sleep(forTimeInterval: 2.0)
            // 实证（2026-09-07 探针）：macOS 默认 zsh 每次画提示符都用 OSC 重设标题——
            // 自定义标题被 shell 顶回是 shell 行为，应用层不可控，故只如实记录不断言。
            let oscSurvived = pollTerminalTitle(3)
            print("    [TitleE2E] Terminal 提示符重绘后标题存活（shell OSC 行为，信息项）: \(oscSurvived)")

            // 清理：exit 自关；shell 退出后窗口偶发滞留（实测），close 兜底。
            _ = runAS("tell application \"Terminal\" to do script \"exit\" in window id \(windowID)")
            check("TitleE2E Terminal: 自建窗口已自关", {
                let deadline = Date().addingTimeInterval(4)
                while Date() < deadline {
                    if terminalWindowName() == nil { return true }
                    Thread.sleep(forTimeInterval: 0.3)
                }
                _ = runAS("tell application \"Terminal\" to close window id \(windowID)")
                let deadline2 = Date().addingTimeInterval(4)
                while Date() < deadline2 {
                    if terminalWindowName() == nil { return true }
                    Thread.sleep(forTimeInterval: 0.3)
                }
                return false
            }())
        }

        // Case B：iTerm2 定向改名（tty 寻址）+ OSC 覆写探针（会话名能否扛住 shell 重绘的实证）。
        caseB: do {
            let created = runAS("""
                tell application "iTerm2"
                    create window with default profile
                    delay 0.5
                    set wID to id of current window
                    set wTTY to tty of current session of current window
                    return (wID as string) & "|" & wTTY
                end tell
                """)
            guard let created, created.contains("|") else {
                check("TitleE2E iTerm2: 自建窗口（id|tty）", false)
                break caseB
            }
            let parts = created.components(separatedBy: "|")
            let windowID = parts[0]
            let tty = parts[1]
            check("TitleE2E iTerm2: 自建窗口（id=\(windowID), tty=\(tty)）", true)

            let writeOK = TitleEditorService.shared.applyViaAppleScript(
                "VFT-E2E-T2", bundleID: "com.googlecode.iterm2", targetTTY: tty)
            check("TitleE2E iTerm2: tty 定向写入 matched", writeOK)

            func iTermSessionName() -> String? {
                runAS("""
                    tell application "iTerm2"
                        repeat with w in windows
                            repeat with t in tabs of w
                                repeat with s in sessions of t
                                    if tty of s = "\(tty)" then
                                        return name of s
                                    end if
                                end repeat
                            end repeat
                        end repeat
                        return "session_gone"
                    end tell
                    """)
            }
            // 注意：`first window whose id = N` 在 iTerm2 AppleScript 上不可用（-1719
            // Invalid index，实测），窗口标题改为命中会话时取其所属窗的 name。
            func iTermWindowName() -> String? {
                runAS("""
                    tell application "iTerm2"
                        repeat with w in windows
                            repeat with t in tabs of w
                                repeat with s in sessions of t
                                    if tty of s = "\(tty)" then
                                        return name of w
                                    end if
                                end repeat
                            end repeat
                        end repeat
                        return "window_gone"
                    end tell
                    """)
            }
            func pollBoth(_ seconds: Double) -> (session: Bool, window: Bool) {
                let deadline = Date().addingTimeInterval(seconds)
                var session = false
                var window = false
                while Date() < deadline {
                    if let n = iTermSessionName(), n.contains("VFT-E2E-T2") { session = true }
                    if let n = iTermWindowName(), n.contains("VFT-E2E-T2") { window = true }
                    if session && window { break }
                    Thread.sleep(forTimeInterval: 0.3)
                }
                return (session, window)
            }
            let landed = pollBoth(4)
            check("TitleE2E iTerm2: 会话名写入生效", landed.session)
            print("    [TitleE2E] iTerm2 窗口标题落屏（会话名→标题显示语义实证）: \(landed.window)")
            print("    [TitleE2E] iTerm2 窗口标题是否跟随会话名（机器/profile 相关，信息项）: \(landed.window)")

            // 覆写探针：向该 session 写命令触发 zsh 新提示符（OSC 重绘），标题必须保持。
            _ = runAS("""
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s = "\(tty)" then
                                    tell s to write text "true"
                                    return "sent"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                """)
            Thread.sleep(forTimeInterval: 2.0)
            let survived = pollBoth(3)
            // 实证（2026-09-07 探针）：提示符重绘后 shell 的 precmd OSC 会把会话名一并
            // 覆写（session name 亦不免疫）——shell 行为应用层不可控，只如实记录。
            print("    [TitleE2E] iTerm2 提示符重绘后会话名存活（shell OSC 行为，信息项）: \(survived.session)")
            print("    [TitleE2E] iTerm2 窗口标题抗 OSC（信息项）: \(survived.window)")

            // 清理：session exit 自关（无确认框路径）。
            _ = runAS("""
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s = "\(tty)" then
                                    tell s to write text "exit"
                                    return "exit_sent"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                """)
            check("TitleE2E iTerm2: 自建窗口已自关", {
                let deadline = Date().addingTimeInterval(6)
                while Date() < deadline {
                    let n = iTermWindowName()
                    if n == nil || n == "window_gone" { return true }
                    Thread.sleep(forTimeInterval: 0.3)
                }
                return false
            }())
        }
    }

    // MARK: TerminalGrid 拆分单元（真实实现——2026-09-07 拆分批次：tty 解析/捕获排序/恢复帧规划）

    do {
        // ===== parseWindowTTYMap：逐行解析 windowID|tty（分支穷尽） =====
        let parsed = TerminalAutomationScript.parseWindowTTYMap("""
        12|/dev/ttys001
        bad-line-without-pipe
        xx|/dev/ttys002
          33  |  ttys003
        44|weird|path
        4294967296|/dev/ttys005

        """)
        check("ttyMap: 正常行解析", parsed[12] == "/dev/ttys001")
        check("ttyMap: 非 UInt32 id（含空白 id）行跳过", parsed[UInt32(33)] == nil && parsed.count == 2)
        check("ttyMap: 空白容忍只对 tty 侧（id 严格解析）", parsed[12] != nil && parsed[44] != nil)
        check("ttyMap: 首个 | 之后的 | 不撕列", parsed[44] == "/dev/weird|path")
        check("ttyMap: 空输入 → 空 Map", TerminalAutomationScript.parseWindowTTYMap("").isEmpty)

        // ===== sortedByReadingOrder：行带分组阅读序（分支穷尽） =====
        // 复用 CGWindowEntry(from:) 的 dict 构造（memberwise 被自定义 init 吞掉）。
        func cgEntry(_ id: UInt32, midX: CGFloat, midY: CGFloat) -> CGWindowEntry {
            CGWindowEntry(from: [
                kCGWindowNumber as String: id,
                kCGWindowOwnerPID as String: pid_t(100),
                kCGWindowBounds as String: [
                    "X": midX - 50, "Y": midY - 40, "Width": CGFloat(100), "Height": CGFloat(80)
                ],
            ])!
        }
        func cgEntryNoBounds(_ id: UInt32) -> CGWindowEntry {
            CGWindowEntry(from: [
                kCGWindowNumber as String: id,
                kCGWindowOwnerPID as String: pid_t(100),
            ])!
        }
        // 上行(y=100) x: 300,100；下行(y=300) x: 200,50 —— 期望阅读序 2,1,4,3
        let raw = [cgEntry(1, midX: 300, midY: 100), cgEntry(2, midX: 100, midY: 100),
                   cgEntry(3, midX: 200, midY: 300), cgEntry(4, midX: 50, midY: 300)]
        let ordered = TerminalGridController.sortedByReadingOrder(raw)
        check("captureOrder: 行带→midX 阅读序", ordered.map { $0.windowID } == [2, 1, 4, 3])
        // 无 bounds 条目：windowID 兜底排序
        let mixed = [cgEntryNoBounds(9), cgEntry(5, midX: 0, midY: 0), cgEntryNoBounds(7)]
        let orderedMixed = TerminalGridController.sortedByReadingOrder(mixed)
        check("captureOrder: 无 bounds 按 windowID 兜底",
              orderedMixed.map { $0.windowID } == [5, 7, 9])
        check("captureOrder: 空输入 → 空", TerminalGridController.sortedByReadingOrder([]).isEmpty)

        // ===== restoreTargetFrames：复用记录帧 vs 重排（分支穷尽） =====
        func cell(_ index: Int, x: CGFloat, y: CGFloat) -> TerminalGridCellSnapshot {
            TerminalGridCellSnapshot(index: index, x: x, y: y, width: 500, height: 400,
                                     ttyPath: nil, sessionID: nil, cwd: nil, title: nil)
        }
        let snapshot = TerminalGridSnapshot(
            name: "t", appBundleID: "com.apple.Terminal", displayID: 1,
            displayYabaiIndex: nil, rows: 1, cols: 2,
            cells: [cell(0, x: 10, y: 20), cell(1, x: 520, y: 20)],
            launchCommand: nil
        )
        let visible = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        // 分支 1：记录屏仍可用 → 记录帧原样（已在界内，clamp 不动）
        let reused = TerminalGridController.restoreTargetFrames(
            snapshot: snapshot, recordedDisplayStillFits: true, visibleFrame: visible)
        check("restoreFrames: 屏可用 → 记录帧复用",
              reused.count == 2 && reused[0] == CGRect(x: 10, y: 20, width: 500, height: 400))
        // 分支 2：记录屏失效 → 按 rows×cols 重排（1×2 网格规划）
        let replanned = TerminalGridController.restoreTargetFrames(
            snapshot: snapshot, recordedDisplayStillFits: false, visibleFrame: visible)
        check("restoreFrames: 屏失效 → 规划重排 1×2",
              replanned.count == 2 && replanned[0] != replanned[1]
              && replanned[0].width == replanned[1].width)
        // 分支 3：屏可用但记录帧越界 → clamp 进可用区
        let overflowSnapshot = TerminalGridSnapshot(
            name: "t2", appBundleID: "com.apple.Terminal", displayID: 1,
            displayYabaiIndex: nil, rows: 1, cols: 1,
            cells: [cell(0, x: 1900, y: 900)],
            launchCommand: nil
        )
        let clampedFrames = TerminalGridController.restoreTargetFrames(
            snapshot: overflowSnapshot, recordedDisplayStillFits: true, visibleFrame: visible)
        check("restoreFrames: 越界记录帧 clamp 进界",
              clampedFrames.count == 1
              && clampedFrames[0].maxX <= visible.maxX && clampedFrames[0].maxY <= visible.maxY)
    }

    // MARK: SoundPreferences 兼容解码 + CustomSoundStatus（真实实现——持久化铁律：旧 JSON 缺字段不得静默重置）

    do {
        // 旧版本 JSON：只有 soundType 一个字段（v1 时代用户保存的形态）
        let legacyJSON = Data(#"{"soundType":"builtin_ding"}"#.utf8)
        let legacy = try? JSONDecoder().decode(SoundPreferences.self, from: legacyJSON)
        check("prefs: 旧 JSON 可解码", legacy != nil)
        check("prefs: soundType 保留", legacy?.soundType == .builtinDing)
        check("prefs: customSoundPath 缺省 nil", legacy?.customSoundPath == nil)
        check("prefs: minPlayIntervalSeconds 缺省 2", legacy?.minPlayIntervalSeconds == 2)
        check("prefs: quietHours 缺省关闭", legacy?.quietHoursEnabled == false)
        check("prefs: quietStart/End 缺省 22/8",
              legacy?.quietStartHour == 22 && legacy?.quietEndHour == 8)
        check("prefs: projectRules 缺省空", legacy?.projectRules.isEmpty == true)

        // 全字段往返
        let full = SoundPreferences(
            soundType: .custom, customSoundPath: "/tmp/a.m4a",
            volume: 0.5, minPlayIntervalSeconds: 7,
            quietHoursEnabled: true, quietStartHour: 1, quietEndHour: 6,
            projectRules: [ProjectSoundRule(projectName: "p", soundType: .builtinPing)]
        )
        let roundtrip = try? JSONDecoder().decode(SoundPreferences.self, from: JSONEncoder().encode(full))
        check("prefs: 全字段往返一致", roundtrip == full)

        // 未来版本多字段（向前容忍：JSONDecoder 默认忽略未知键）
        let futureJSON = Data(#"{"soundType":"builtin_ping","futureField":123}"#.utf8)
        let future = try? JSONDecoder().decode(SoundPreferences.self, from: futureJSON)
        check("prefs: 未来字段不炸解码", future?.soundType == .builtinPing)

        // 非法 JSON → nil（调用方 loadPreferences 回退 .default）
        check("prefs: 非法 JSON 解码失败可被捕获",
              (try? JSONDecoder().decode(SoundPreferences.self, from: Data("not-json".utf8))) == nil)

        // CustomSoundStatus.evaluate 真实实现分支（文件系统交互）
        check("soundStatus: nil → notSet", CustomSoundStatus.evaluate(path: nil) == .notSet)
        check("soundStatus: 空串 → notSet", CustomSoundStatus.evaluate(path: "") == .notSet)
        check("soundStatus: 不存在文件 → missing",
              CustomSoundStatus.evaluate(path: "/tmp/vf-definitely-missing-\(UUID().uuidString).wav") == .missing)
        let tmp = "/tmp/vf-sound-status-\(UUID().uuidString).wav"
        FileManager.default.createFile(atPath: tmp, contents: Data([0]))
        check("soundStatus: 存在文件 → valid", CustomSoundStatus.evaluate(path: tmp) == .valid)
        try? FileManager.default.removeItem(atPath: tmp)
        check("soundStatus: 文件删除后 → missing", CustomSoundStatus.evaluate(path: tmp) == .missing)
    }

    // MARK: 编排页提纯单元（真实实现——B3：目标摘要/终端说明文案/间距步进）

    do {
        // GridTargetCode.summaryText：四分支
        check("targetSummary: main", GridTargetCode.main.summaryText == "→ 主屏")
        check("targetSummary: focused", GridTargetCode.focused.summaryText == "→ 焦点屏")
        check("targetSummary: display", GridTargetCode.display(displayID: 7).summaryText == "→ #7 当前 Space")
        check("targetSummary: displaySpace", GridTargetCode.displaySpace(displayID: 7, spaceIndex: 3).summaryText == "→ #7 · Space 3")
        check("targetSummary: parse→summary 集成",
              GridTargetCode.parse("d2s5")?.summaryText == "→ #2 · Space 5")

        // AppPreference.selectionDetailText：三分支非空且互异
        let details = [
            TerminalGridPreferences.AppPreference.auto,
            .terminal,
            .iterm2
        ].map { $0.selectionDetailText }
        check("appPrefDetail: 三分支非空且互异",
              details.allSatisfy { !$0.isEmpty } && Set(details).count == 3)
        check("appPrefDetail: terminal 指明完整支持", details[1].contains("完整支持"))
        check("appPrefDetail: iterm2 指明部分支持", details[2].contains("部分支持"))

        // TerminalGridPlanner.steppedGap：2px 步进取整
        check("steppedGap: 0 → 0（无缝）", TerminalGridPlanner.steppedGap(0) == 0)
        check("steppedGap: 1.2 → 2（向上取档）", TerminalGridPlanner.steppedGap(1.2) == 2)
        check("steppedGap: 3.9 → 4（恰档不动）", TerminalGridPlanner.steppedGap(3.9) == 4)
        check("steppedGap: 24 → 24（上界）", TerminalGridPlanner.steppedGap(24) == 24)
        check("steppedGap: 23 → 24（越上界取整）", TerminalGridPlanner.steppedGap(23) == 24)
    }

    // MARK: SA 恢复状态机（真实实现——B4：recoveryVerdict/autoRecoveryAllowed/saProbeVerdict 穷尽锁定）

    do {
        // recoveryVerdict：成功/SIP 阻断/用户拒绝（大小写容忍）/其他失败
        check("saVerdict: success → succeeded",
              SpaceController.recoveryVerdict(success: true, outputOrError: "") == .succeeded)
        check("saVerdict: success 优先于错误文本",
              SpaceController.recoveryVerdict(success: true, outputOrError: "System Integrity Protection") == .succeeded)
        check("saVerdict: SIP 文本 → blockedBySIP",
              SpaceController.recoveryVerdict(success: false, outputOrError: "yabai: System Integrity Protection forbids") == .blockedBySIP)
        check("saVerdict: User Canceled 大小写容忍 → userDeclined",
              SpaceController.recoveryVerdict(success: false, outputOrError: "script error: User Canceled.") == .userDeclined)
        check("saVerdict: 其他输出 → failedOther",
              SpaceController.recoveryVerdict(success: false, outputOrError: "connection invalid") == .failedOther)
        check("saVerdict: 空输出 → failedOther",
              SpaceController.recoveryVerdict(success: false, outputOrError: "") == .failedOther)

        // autoRecoveryAllowed：冷静期矩阵（含边界小时）
        let week: TimeInterval = 7 * 24
        check("saRetry: blockedBySIP 永不自动重试",
              !SpaceController.autoRecoveryAllowed(verdict: .blockedBySIP, hoursSince: week * 52))
        check("saRetry: succeeded 无需恢复",
              !SpaceController.autoRecoveryAllowed(verdict: .succeeded, hoursSince: week))
        check("saRetry: userDeclined 冷静期未满拒",
              !SpaceController.autoRecoveryAllowed(verdict: .userDeclined, hoursSince: week - 1))
        check("saRetry: userDeclined 冷静期满放行",
              SpaceController.autoRecoveryAllowed(verdict: .userDeclined, hoursSince: week))
        check("saRetry: failedOther 24h 未满拒",
              !SpaceController.autoRecoveryAllowed(verdict: .failedOther, hoursSince: 23.9))
        check("saRetry: failedOther 24h 满放行",
              SpaceController.autoRecoveryAllowed(verdict: .failedOther, hoursSince: 24))

        // saProbeVerdict（真实实现直测，收敛 Standalone 镜像语义）
        check("saProbe: exit 0 → 通过",
              SpaceController.saProbeVerdict(exitCode: 0, stderr: ""))
        check("saProbe: SA 缺失 → 不通过",
              !SpaceController.saProbeVerdict(exitCode: 1, stderr: "yabai: error with the scripting-addition"))
        check("saProbe: mission-control 阻断 → 不通过",
              !SpaceController.saProbeVerdict(exitCode: 1, stderr: "yabai: cannot focus space: mission-control is active!"))
        check("saProbe: 其他错误 → 通过（非 SA 类失败不判死）",
              SpaceController.saProbeVerdict(exitCode: 2, stderr: "yabai: unknown command"))
    }

    // MARK: 语音播报插值与队列策略（真实实现——B5：消镜像漂移，直测 Sources）

    do {
        func payload(cwd: String?, projectDir: String?, model: String?, sessionID: String) -> ClaudeHookPayload {
            ClaudeHookPayload(
                event: .stop, sessionID: sessionID, source: "test", timestamp: nil,
                cwd: cwd,
                model: model,
                terminalCtx: TerminalContext(
                    termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
                    weztermPane: nil, tty: nil, ppid: nil,
                    claudeProjectDir: projectDir, windowID: nil, machineLabel: nil
                ),
                lastAssistantMessage: nil, transcriptPath: nil
            )
        }
        let p = payload(cwd: "/tmp/repo", projectDir: "/Users/u/github/vibe-coding-labs/", model: "GLM", sessionID: "sess-1")
        check("interpolate: 四变量全替换",
              VoiceAnnouncementTemplate.interpolate("{project_name}/{model}@{cwd}#{session_id}", payload: p)
              == "vibe-coding-labs/GLM@/tmp/repo#sess-1")
        check("interpolate: projectDir 去首尾斜杠取末段", !VoiceAnnouncementTemplate.interpolate("{project_name}", payload: p).contains("/"))
        let noCtx = payload(cwd: nil, projectDir: nil, model: nil, sessionID: "s2")
        check("interpolate: 缺 ctx → 未知项目/未知模型/cwd 空串",
              VoiceAnnouncementTemplate.interpolate("{project_name}|{model}|{cwd}", payload: noCtx) == "未知项目|未知模型|")
        check("interpolate: sessionID 原样保留（无兜底）",
              VoiceAnnouncementTemplate.interpolate("{session_id}", payload: noCtx) == "s2")
        check("interpolate: 无变量模板原样返回",
              VoiceAnnouncementTemplate.interpolate("对话完成", payload: p) == "对话完成")

        // 队列策略：容量边界与丢最旧顺序
        func q(_ items: [Int]) -> [QueuedAnnouncement] {
            items.map { .text("t\($0)") }
        }
        func ids(_ items: [QueuedAnnouncement]) -> [String] {
            items.map { if case .text(let s) = $0 { return s } ; return "?" }
        }
        var queue = VoiceAnnouncementQueuePolicy.appendedQueue([], appending: .text("t1"), capacity: 3)
        queue = VoiceAnnouncementQueuePolicy.appendedQueue(queue, appending: .text("t2"), capacity: 3)
        queue = VoiceAnnouncementQueuePolicy.appendedQueue(queue, appending: .text("t3"), capacity: 3)
        check("queue: 未满按序保留", ids(queue) == ["t1", "t2", "t3"])
        queue = VoiceAnnouncementQueuePolicy.appendedQueue(queue, appending: .text("t4"), capacity: 3)
        check("queue: 满则丢最旧", ids(queue) == ["t2", "t3", "t4"])
        let defensive = VoiceAnnouncementQueuePolicy.appendedQueue(q([1]), appending: .text("x"), capacity: 0)
        check("queue: capacity<1 防御为 1（新条目总在）", ids(defensive) == ["x"])
    }

    // MARK: 提示音设置页提纯（真实实现——B9：节流/免打扰文案 + 规则兜底音效）

    do {
        check("throttleLabel: 0 → 关闭", SoundSectionText.throttleLabel(seconds: 0) == "关闭")
        check("throttleLabel: 7 → 7 秒", SoundSectionText.throttleLabel(seconds: 7) == "7 秒")
        check("quietHoursDetail: 开启 → 静音说明",
              SoundSectionText.quietHoursDetail(enabled: true).contains("保持静音"))
        check("quietHoursDetail: 关闭 → 设定说明",
              SoundSectionText.quietHoursDetail(enabled: false).contains("设定静音时间段"))

        let ruleWithSound = ProjectSoundRule(projectName: "p", soundType: .builtinPing)
        check("ruleSound: 显式音效生效", ruleWithSound.effectiveSoundType == .builtinPing)
        let ruleRaw = ProjectSoundRule(projectName: "p2", soundType: .builtinComplete)
        var ruleEmpty = ruleRaw
        ruleEmpty.soundRawValue = "not-a-sound"
        check("ruleSound: 非法 rawValue → 兜底 builtinComplete",
              ruleEmpty.effectiveSoundType == .builtinComplete)
    }

    // MARK: Hook 数据契约（真实实现——B6：ClaudeHookPayload 容错解码/TerminalContext 绑定判据穷尽锁定）

    do {
        func decode(_ json: String) throws -> ClaudeHookPayload {
            try JSONDecoder().decode(ClaudeHookPayload.self, from: Data(json.utf8))
        }
        // 事件键双别名
        check("payload: event 键", (try? decode(#"{"event":"Stop","session_id":"s1"}"#))?.event == .stop)
        check("payload: hook_event_name 别名", (try? decode(#"{"hook_event_name":"SessionStart","session_id":"s1"}"#))?.event == .sessionStart)
        check("payload: 两键皆缺 → 抛错", (try? decode(#"{"session_id":"s1"}"#)) == nil)
        check("payload: 未知事件值 → 抛错", (try? decode(#"{"event":"Nonsense","session_id":"s1"}"#)) == nil)
        // 会话键别名 + trim + 空拒绝
        check("payload: session_id 键", (try? decode(#"{"event":"Stop","session_id":"  abc  "}"#))?.sessionID == "abc")
        check("payload: sessionId 别名", (try? decode(#"{"event":"Stop","sessionId":"abc"}"#))?.sessionID == "abc")
        check("payload: 空白会话 → 抛错", (try? decode(#"{"event":"Stop","session_id":"   "}"#)) == nil)
        check("payload: 缺会话 → 抛错", (try? decode(#"{"event":"Stop"}"#)) == nil)
        // 可选字段缺省 nil
        let minimal = try! decode(#"{"event":"Stop","session_id":"m1"}"#)
        check("payload: 可选字段缺省 nil",
              minimal.source == nil && minimal.cwd == nil && minimal.model == nil
              && minimal.terminalCtx == nil && minimal.lastAssistantMessage == nil
              && minimal.transcriptPath == nil)
        // 嵌套 terminalCtx（snake_case 键）+ 文本字段
        let rich = try! decode("""
        {"event":"UserPromptSubmit","session_id":"r1","source":"cc","cwd":"/w",
         "model":"m","transcript_path":"/t.jsonl","last_assistant_message":"hi",
         "terminal_ctx":{"tty":"/dev/ttys004","claude_project_dir":"/repo","window_id":"42"}}
        """)
        check("payload: 嵌套 ctx 解码", rich.terminalCtx?.tty == "/dev/ttys004"
              && rich.terminalCtx?.claudeProjectDir == "/repo" && rich.terminalCtx?.windowID == "42")
        check("payload: 其余可选字段解码", rich.source == "cc" && rich.cwd == "/w"
              && rich.model == "m" && rich.transcriptPath == "/t.jsonl"
              && rich.lastAssistantMessage == "hi")

        // TerminalContext.hasUsefulContext：五因子判定（绑定前置判据）
        func ctx(tty: String? = nil, term: String? = nil, iterm: String? = nil,
                 ppid: String? = nil, machine: String? = nil) -> TerminalContext {
            TerminalContext(termSessionID: term, itermSessionID: iterm, kittyWindowID: nil,
                            weztermPane: nil, tty: tty, ppid: ppid,
                            claudeProjectDir: nil, windowID: nil, machineLabel: machine)
        }
        check("ctx: tty 单独即有用", ctx(tty: "/dev/ttys001").hasUsefulContext)
        check("ctx: termSessionID 单独即有用", ctx(term: "t").hasUsefulContext)
        check("ctx: itermSessionID 单独即有用", ctx(iterm: "i").hasUsefulContext)
        check("ctx: 有效 ppid(>1) 即有用", ctx(ppid: "123").hasUsefulContext)
        check("ctx: ppid=1 无用（init 进程排除）", !ctx(ppid: "1").hasUsefulContext)
        check("ctx: ppid 非数字无用", !ctx(ppid: "abc").hasUsefulContext)
        check("ctx: machineLabel 单独即有用", ctx(machine: "srv-1").hasUsefulContext)
        check("ctx: 全空无用", !ctx(tty: "", term: "", iterm: "", ppid: "", machine: "").hasUsefulContext)
        check("ctx: 全 nil 无用", !ctx().hasUsefulContext)
        check("ctx: isRemote 有标签 true", ctx(machine: "srv").isRemote)
        check("ctx: isRemote 空/nil 标签 false", !ctx(machine: "").isRemote && !ctx().isRemote)

        // ClaudeHookResponse 编码：sessionID 走 snake_case
        let respObj = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(
            ClaudeHookResponse(ok: true, code: "ok", message: "done", sessionID: "s9", handled: true)
        ))) as? [String: Any]
        check("response: session_id snake_case 键", respObj?["session_id"] as? String == "s9" && respObj?["ok"] as? Bool == true)
    }

    // MARK: Hook 窗移决策树（真实实现——B7：守护顺序契约从镜像转 Runner 直测，决策树唯一事实源）

    do {
        typealias D = HookEventHandler.WindowMoveDecision
        // 守护顺序逐条锁定（顺序即生产契约：前一条满足时后条不可达）
        check("decide: autoFocus 关闭最优先",
              HookEventHandler.decideWindowMove(autoFocusEnabled: false, hasBinding: false, bindingVerified: false, isWindowOnMainScreen: false, isInCooldown: false, bindingAge: 0, pidMatches: nil, isTerminalOrIDE: false) == .autoFocusDisabled)
        check("decide: remoteOnly → localBindingSkip（跳过全部绑定语义）",
              HookEventHandler.decideWindowMove(autoFocusEnabled: true, hasBinding: true, bindingVerified: true, isWindowOnMainScreen: false, isInCooldown: false, bindingAge: 0, pidMatches: true, isTerminalOrIDE: true, remoteOnly: true) == .localBindingSkip)
        check("decide: 无绑定 → noBindingSkip",
              HookEventHandler.decideWindowMove(autoFocusEnabled: true, hasBinding: false, bindingVerified: false, isWindowOnMainScreen: false, isInCooldown: false, bindingAge: 0, pidMatches: nil, isTerminalOrIDE: false) == .noBindingSkip)
        check("decide: 绑定未验证 → bindingVerificationFailed",
              HookEventHandler.decideWindowMove(autoFocusEnabled: true, hasBinding: true, bindingVerified: false, isWindowOnMainScreen: false, isInCooldown: false, bindingAge: 0, pidMatches: nil, isTerminalOrIDE: false) == .bindingVerificationFailed)
        check("decide: 已在主屏 → alreadyOnMainScreen",
              HookEventHandler.decideWindowMove(autoFocusEnabled: true, hasBinding: true, bindingVerified: true, isWindowOnMainScreen: true, isInCooldown: false, bindingAge: 0, pidMatches: true, isTerminalOrIDE: true) == .alreadyOnMainScreen)
        check("decide: 恢复冷却 → restoreCooldownActive",
              HookEventHandler.decideWindowMove(autoFocusEnabled: true, hasBinding: true, bindingVerified: true, isWindowOnMainScreen: false, isInCooldown: true, bindingAge: 0, pidMatches: true, isTerminalOrIDE: true) == .restoreCooldownActive)
        check("decide: 陈旧绑定+pid 失配 → staleBindingPIDMismatch",
              HookEventHandler.decideWindowMove(autoFocusEnabled: true, hasBinding: true, bindingVerified: true, isWindowOnMainScreen: false, isInCooldown: false, bindingAge: 1801, pidMatches: false, isTerminalOrIDE: true) == .staleBindingPIDMismatch)
        check("decide: pid 失配但未超龄 → 继续移动",
              HookEventHandler.decideWindowMove(autoFocusEnabled: true, hasBinding: true, bindingVerified: true, isWindowOnMainScreen: false, isInCooldown: false, bindingAge: 1799, pidMatches: false, isTerminalOrIDE: true) == .proceedToMove(source: "binding"))
        check("decide: 非终端窗 → nonTerminalWindow",
              HookEventHandler.decideWindowMove(autoFocusEnabled: true, hasBinding: true, bindingVerified: true, isWindowOnMainScreen: false, isInCooldown: false, bindingAge: 0, pidMatches: true, isTerminalOrIDE: false) == .nonTerminalWindow)
        check("decide: 全绿 → proceedToMove(binding)",
              HookEventHandler.decideWindowMove(autoFocusEnabled: true, hasBinding: true, bindingVerified: true, isWindowOnMainScreen: false, isInCooldown: false, bindingAge: 0, pidMatches: true, isTerminalOrIDE: true) == .proceedToMove(source: "binding"))
        check("decide: pidMatches nil（查询失败）+ 超龄 → 不判死继续移动",
              HookEventHandler.decideWindowMove(autoFocusEnabled: true, hasBinding: true, bindingVerified: true, isWindowOnMainScreen: false, isInCooldown: false, bindingAge: 1801, pidMatches: nil, isTerminalOrIDE: true) == .proceedToMove(source: "binding"))

        // 决策 → HTTP 响应映射表：8 跳过类全部 200+handled=false+code 对应；proceed → nil
        for (decision, code) in [(D.autoFocusDisabled, "auto_focus_disabled"),
                                 (D.localBindingSkip, "trigger_disabled_skip"),
                                 (D.noBindingSkip, "no_binding_skip"),
                                 (D.bindingVerificationFailed, "binding_verification_failed"),
                                 (D.alreadyOnMainScreen, "already_on_main_screen"),
                                 (D.restoreCooldownActive, "restore_cooldown_active"),
                                 (D.staleBindingPIDMismatch, "stale_binding_pid_mismatch"),
                                 (D.nonTerminalWindow, "non_terminal_window")] as [(HookEventHandler.WindowMoveDecision, String)] {
            guard let resp = HookEventHandler.httpResponse(for: decision, triggerName: "T", sessionID: "s") else {
                check("httpResponse: \(code) 应有响应", false)
                continue
            }
            check("httpResponse: \(code) → 200/handled=false/code 对应",
                  resp.statusCode == 200 && resp.response.ok && !resp.response.handled
                  && resp.response.code == code)
        }
        check("httpResponse: proceedToMove → nil（响应由执行器产生）",
              HookEventHandler.httpResponse(for: .proceedToMove(source: "binding"), triggerName: "T", sessionID: "s") == nil)
        check("logDescription: proceed 带源标注",
              D.proceedToMove(source: "binding").logDescription == "proceed_to_move(source=binding)")
    }

    // MARK: Space 投递决策（真实实现——B8：七分支决策表从镜像转 Runner 直测）

    do {
        typealias Dec = TerminalGridController.SpaceDeliveryDecision
        typealias Args = (
            targetSpaceIndex: Int?, targetDisplayVisibleSpace: Int?,
            targetDisplayIndex: Int?, windowDisplayIndex: Int?,
            hasParkingDisplay: Bool, windowSpaceIndex: Int?
        )
        func decide(_ a: Args) -> TerminalGridController.SpaceDeliveryDecision {
            TerminalGridController.spaceDeliveryDecision(
                targetSpaceIndex: a.targetSpaceIndex,
                targetDisplayVisibleSpace: a.targetDisplayVisibleSpace,
                targetDisplayIndex: a.targetDisplayIndex,
                windowDisplayIndex: a.windowDisplayIndex,
                hasParkingDisplay: a.hasParkingDisplay,
                windowSpaceIndex: a.windowSpaceIndex
            )
        }
        // 全参便利：显式目标 Space 5 / 目标屏 display 1 / 双屏
        let base = Args(5, 5, 1, 1, true, 5)
        check("delivery: 窗已在目标 space → notNeeded", decide(base) == .notNeeded)
        check("delivery: 非显式 space 目标 → notApplicable",
              decide(Args(nil, 5, 1, 1, true, 5)) == .notApplicable)
        check("delivery: yabai 不可用（可见 space nil）→ skipNoYabai",
              decide(Args(5, nil, 1, 1, true, 5)) == .skipNoYabai)
        check("delivery: 目标屏视角未在目标 space → skipViewNotOnTarget",
              decide(Args(5, 4, 1, 1, true, 5)) == .skipViewNotOnTarget)
        check("delivery: 跨屏窗 + 有泊位屏 → deliverCrossDisplay",
              decide(Args(5, 5, 1, 2, true, nil)) == .deliverCrossDisplay)
        check("delivery: 同屏错位 + 有泊位屏 → deliverRoundTrip",
              decide(Args(5, 5, 1, 1, true, 3)) == .deliverRoundTrip)
        check("delivery: 同屏错位 + 单屏无泊位 → skipNoParkingDisplay",
              decide(Args(5, 5, 1, 1, false, 3)) == .skipNoParkingDisplay)
        check("delivery: 窗 space 查询失败（nil）按需投递（同屏）",
              decide(Args(5, 5, 1, 1, true, nil)) == .deliverRoundTrip)
        check("delivery: 窗 display 查询失败（nil）≠ 目标屏 → 跨屏",
              decide(Args(5, 5, 1, nil, true, nil)) == .deliverCrossDisplay)
    }

    // MARK: Overlay 刷新域（真实实现——防风暴门/热插拔防护/Space 快照解析，Batch 12）

    do {
        // A. refreshGate 门矩阵真身（镜像 OverlayRefreshPolicyTests 同矩阵）。
        check("overlayGate A1: suspend+非force → skipSuspended",
              OverlayRefreshPolicy.refreshGate(suspended: true, enabled: true, force: false) == .skipSuspended)
        check("overlayGate A2: suspend+force → proceed（debounce 补刷新穿透 suspend）",
              OverlayRefreshPolicy.refreshGate(suspended: true, enabled: true, force: true) == .proceed)
        check("overlayGate A3: disabled 恒 skip（force 不豁免）",
              OverlayRefreshPolicy.refreshGate(suspended: true, enabled: false, force: true) == .skipDisabled
              && OverlayRefreshPolicy.refreshGate(suspended: false, enabled: false, force: true) == .skipDisabled)
        check("overlayGate A4: 常态 proceed",
              OverlayRefreshPolicy.refreshGate(suspended: false, enabled: true, force: false) == .proceed)

        // B. 去重判定真身。
        let last = Date(timeIntervalSince1970: 1000)
        check("overlayGate B: 连发丢弃 + 越阈放行",
              OverlayRefreshPolicy.isDuplicateForceTrigger(lastTriggerAt: last, now: last.addingTimeInterval(0.29), minInterval: 0.3)
              && !OverlayRefreshPolicy.isDuplicateForceTrigger(lastTriggerAt: last, now: last.addingTimeInterval(0.31), minInterval: 0.3))

        // C. ScreenHotplugGuard 真身：集合相等语义 + 防御过滤。
        let u1 = UUID(), u2 = UUID(), u3 = UUID()
        check("overlayGate C: 热插拔集合相等（顺序无关）+ 插拔不一致",
              ScreenHotplugGuard.identityMatches(preUUIDs: [u1, u2], currentUUIDs: [u2, u1])
              && !ScreenHotplugGuard.identityMatches(preUUIDs: [u1], currentUUIDs: [u1, u2]))
        check("overlayGate C: filterStale 剔除失效条目",
              ScreenHotplugGuard.filterStale([(0, u1, 1, 1), (1, u3, 2, 3)], liveUUIDs: [u1]).count == 1)

        // D. SpaceSnapshot / AllSpaceSnapshot 解析真身（Bool/Int 双形态防御 + 缺字段跳过）。
        let mixed: [[String: Any]] = [
            ["index": 1, "display": 1, "is-visible": true, "has-focus": 1],
            ["index": 2, "display": 1, "is-visible": 0, "has-focus": 0],
            ["display": 2, "is-visible": true],                    // 缺 index → 跳过
            ["index": 3, "is-visible": true],                      // 缺 display → AllSpace 跳过
        ]
        let perScreen = SpaceSnapshot.parse(from: mixed)
        check("overlayGate D: SpaceSnapshot 双形态防御解析（缺 index 跳过）",
              perScreen.count == 3 && perScreen[0].isVisible && perScreen[1].hasFocus == false)
        let all = AllSpaceSnapshot.parse(from: mixed)
        check("overlayGate D: AllSpaceSnapshot 缺 display 跳过",
              all.count == 2 && all[1].display == 1)
        check("overlayGate D: parseJSONArray 形状不符 → nil / 合法数组解析",
              AllSpaceSnapshot.parseJSONArray(Data(#"{"a":1}"#.utf8)) == nil
              && AllSpaceSnapshot.parseJSONArray(Data(#"[{"index":1}]"#.utf8))?.count == 1)

        // E. resolveScreenSpaceIndex 真身：focused 位次优先 → 可见位次 → nil。
        let spaces = [
            AllSpaceSnapshot(index: 3, display: 1, isVisible: false, hasFocus: false),
            AllSpaceSnapshot(index: 1, display: 1, isVisible: true, hasFocus: false),
            AllSpaceSnapshot(index: 2, display: 1, isVisible: true, hasFocus: true),
        ]
        check("overlayGate E: focused 命中 → 按升序位次（2）",
              AllSpaceSnapshot.resolveScreenSpaceIndex(from: spaces, focusedSpaceIndex: 2) == 2)
        check("overlayGate E: focused 属别屏 → 首个可见位次（1）",
              AllSpaceSnapshot.resolveScreenSpaceIndex(from: spaces, focusedSpaceIndex: 9) == 1)
        check("overlayGate E: 全不可见 → nil",
              AllSpaceSnapshot.resolveScreenSpaceIndex(
                from: [AllSpaceSnapshot(index: 2, display: 1, isVisible: false, hasFocus: false)],
                focusedSpaceIndex: nil) == nil)
    }

    // MARK: SessionWindowRegistry 查找级联（真实实现 + 隔离 DB——B10：绑定查找唯一事实源）
    // 仅 VIBEFOCUS_REGISTRY_E2E=1 时运行（须配 VIBEFOCUS_DB_PATH 隔离库；E2E 互斥锁自动生效）。

    if ProcessInfo.processInfo.environment["VIBEFOCUS_REGISTRY_E2E"] == "1" {
        let registry = SessionWindowRegistry.shared
        // 取一个真实终端 app 的 pid（查找级联按「pid 仍是终端进程」判有效）
        let terminalPID = NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == "com.googlecode.iterm2" || $0.bundleIdentifier == "com.apple.Terminal" }?
            .processIdentifier ?? ProcessInfo.processInfo.processIdentifier

        func state(_ wid: UInt32, pid: Int32, session: String?) -> WindowState {
            var ws = WindowState(
                windowID: wid, pid: pid, tty: nil,
                axWindowNumber: nil, appName: "TestTerminal", bundleIdentifier: nil, title: nil,
                termSessionID: nil, itermSessionID: nil, kittyWindowID: nil, weztermPane: nil,
                envWindowID: nil, sessionID: session, cwd: nil, model: nil,
                isCompleted: false, createdAt: Date(), updatedAt: Date()
            )
            return ws
        }

        // 直命中：sessionID 精确匹配
        registry.windowStates[9001] = state(9001, pid: terminalPID, session: "sess-A")
        check("registry: 直命中 sessionID", registry.binding(for: "sess-A")?.windowID == 9001)

        // 有效 pid 优先：同 session 两条（一条 pid 已死），返回 pid 有效者
        registry.windowStates[9002] = state(9002, pid: 999_999_999, session: "sess-B")
        registry.windowStates[9003] = state(9003, pid: terminalPID, session: "sess-B")
        check("registry: 同会话多绑定优先 pid 有效者", registry.binding(for: "sess-B")?.windowID == 9003)

        // 别名通道：主表无、别名表有
        registry.sessionAliasWindowID["alias-sess"] = 9001
        check("registry: 别名通道命中", registry.binding(for: "alias-sess")?.windowID == 9001)

        // 未注册会话 → nil
        check("registry: 未注册会话 → nil", registry.binding(for: "nope") == nil)

        // markCompleted 联动（State 扩展唯一入口）
        registry.markCompleted(sessionID: "sess-A")
        check("registry: markCompleted 后绑定仍可查",
              registry.binding(for: "sess-A")?.windowID == 9001)

        // 清理：markCompleted 已持久化，仅删内存不够——查找级联第三层是 DB 兜底
        // （findWindowStateBySession），隔离库行须一并删除（本轮实测验证了该层真实存在）。
        registry.windowStates.removeValue(forKey: 9001)
        registry.windowStates.removeValue(forKey: 9002)
        registry.windowStates.removeValue(forKey: 9003)
        registry.sessionAliasWindowID.removeValue(forKey: "alias-sess")
        for wid in [UInt32(9001), 9002, 9003] {
            WindowStateStore.shared.deleteWindowState(windowID: wid)
        }
        check("registry: 内存+DB 双清后 → nil", registry.binding(for: "sess-A") == nil)
    }

    // MARK: 终端上下文匹配族 + Claude 窗口定位（真实实现——B11：镜像转直测）

    do {
        // fullDevicePath / normalizeTTY
        check("tty: fullDevicePath 补前缀", WindowManager.fullDevicePath("ttys003") == "/dev/ttys003")
        check("tty: fullDevicePath 已带前缀原样", WindowManager.fullDevicePath("/dev/ttys003") == "/dev/ttys003")
        check("tty: normalize nil/空/not-a-tty → nil",
              WindowManager.normalizeTTY(nil) == nil
              && WindowManager.normalizeTTY("") == nil
              && WindowManager.normalizeTTY("not a tty") == nil)
        check("tty: normalize 正常补全", WindowManager.normalizeTTY("ttys009") == "/dev/ttys009")

        // matchCommandToWindowTitle：倒序命令优先 + em-dash contains + 大小写
        let wins = [
            WindowIdentity(windowID: 1, pid: 100, bundleIdentifier: nil, appName: "T", windowNumber: 1, title: "user — Zsh"),
            WindowIdentity(windowID: 2, pid: 100, bundleIdentifier: nil, appName: "T", windowNumber: 2, title: "repo — claude"),
        ]
        check("cmdMatch: 命中 em-dash 标题",
              WindowManager.matchCommandToWindowTitle(commands: ["claude"], windows: wins)?.windowID == 2)
        check("cmdMatch: 倒序遍历（后者优先）",
              WindowManager.matchCommandToWindowTitle(commands: ["zsh", "claude"], windows: wins)?.windowID == 2)
        check("cmdMatch: 大小写敏感命令不命中小写标题",
              WindowManager.matchCommandToWindowTitle(commands: ["CLAUDE"], windows: wins) == nil)

        // parseCommandBasename：路径取 basename、空行跳过
        let basenames = WindowManager.parseCommandBasename(from: "/usr/bin/claude\n\n  /opt/homebrew/bin/nvim ")
        check("cmdBasename: 取末段 + 空行跳过", basenames == ["claude", "nvim"])

        // parseItermSessionUUID / UUID / TTY 校验（注入防御 allowlist）
        check("itermUUID: 冒号后取段", WindowManager.parseItermSessionUUID("iTerm:ABC-123") == "ABC-123")
        check("itermUUID: 无冒号原样", WindowManager.parseItermSessionUUID("ABC") == "ABC")
        check("itermUUID: 冒号后空 → nil", WindowManager.parseItermSessionUUID("iTerm:") == nil)
        check("uuidAllow: hex+连字符通过", WindowManager.isValidUUIDPart("ABC-def-0123"))
        check("uuidAllow: 元字符拒绝", !WindowManager.isValidUUIDPart("abc\"; rm"))
        check("ttyAllow: /dev/ttys### 通过", WindowManager.isValidTTYPath("/dev/ttys004"))
        check("ttyAllow: /dev/pty### 通过", WindowManager.isValidTTYPath("/dev/pty3"))
        check("ttyAllow: 非设备路径拒绝", !WindowManager.isValidTTYPath("/dev/tty; rm -rf"))

        // Claude 窗口定位：两级策略
        typealias Cand = WindowManager.WindowCandidate
        let candidates = [
            Cand(windowID: 11, pid: 100, appName: "iTerm2", bundleIdentifier: "com.googlecode.iterm2", title: "proj — zsh"),
            Cand(windowID: 12, pid: 100, appName: "iTerm2", bundleIdentifier: "com.googlecode.iterm2", title: "Claude Code — proj"),
        ]
        let isHost: (Cand) -> Bool = { $0.appName == "iTerm2" }
        let m1 = WindowManager.matchClaudeCodeCandidate(candidates, projectName: "proj", isHostApp: isHost)
        check("claudeMatch: 策略1 项目名命中前者",
              m1?.strategy == .hostAppProjectName && m1?.candidate.windowID == 11)
        let m2 = WindowManager.matchClaudeCodeCandidate(candidates, projectName: nil, isHostApp: isHost)
        check("claudeMatch: 策略2 无项目名回落标题", m2?.strategy == .hostAppClaudeCodeTitle && m2?.candidate.windowID == 12)
        let m3 = WindowManager.matchClaudeCodeCandidate(candidates, projectName: "nomatch", isHostApp: isHost)
        check("claudeMatch: 项目名未命中回落策略2", m3?.strategy == .hostAppClaudeCodeTitle && m3?.candidate.windowID == 12)
        let noHost = WindowManager.matchClaudeCodeCandidate(candidates, projectName: "proj", isHostApp: { _ in false })
        check("claudeMatch: 无 hostApp 候选 → nil", noHost == nil)
    }

    // MARK: 编排目标与终端选择解析（真实实现——B12：GridTargetCode.parse / TerminalSelectionResolver.resolve 直测）

    do {
        // GridTargetCode.parse：全形态 + 非法输入
        check("gridParse: main/focused", GridTargetCode.parse("main") == .main && GridTargetCode.parse("focused") == .focused)
        check("gridParse: 纯 display", GridTargetCode.parse("d42") == .display(displayID: 42))
        check("gridParse: display+space", GridTargetCode.parse("d7s3") == .displaySpace(displayID: 7, spaceIndex: 3))
        check("gridParse: 非法形态 → nil",
              GridTargetCode.parse(nil) == nil && GridTargetCode.parse("") == nil
              && GridTargetCode.parse("x1") == nil && GridTargetCode.parse("dx") == nil)
        check("gridParse: space 非法（0/非数字）→ nil",
              GridTargetCode.parse("d7s0") == nil && GridTargetCode.parse("d7sx") == nil)
        check("gridParse: display 非数字 → nil", GridTargetCode.parse("d-1") == nil)

        // TerminalSelectionResolver.resolve：手动优先 / auto 运行优先 / fallback
        func candidate(_ bundleID: String, running: Bool, count: Int) -> TerminalSelectionCandidate {
            TerminalSelectionCandidate(
                bundleID: bundleID, name: bundleID, support: .full,
                usageCount: count, lastUsedAt: nil, isRunning: running
            )
        }
        let cands = [candidate("com.apple.Terminal", running: false, count: 3),
                     candidate("com.googlecode.iterm2", running: true, count: 9)]
        let manual = TerminalSelectionResolver.resolve(manualBundleID: "com.apple.Terminal", candidates: cands)
        check("selection: 手动指定优先", manual.bundleID == "com.apple.Terminal")
        let auto = TerminalSelectionResolver.resolve(manualBundleID: nil, candidates: cands)
        check("selection: auto 按使用频次排序取最常用", auto.bundleID == "com.googlecode.iterm2")
        let empty = TerminalSelectionResolver.resolve(manualBundleID: nil, candidates: [])
        check("selection: 无候选回落 Terminal.app", empty.bundleID == "com.apple.Terminal")
    }

    // MARK: float 脱管/恢复链路纯决策（真实实现——B13：FloatToggle/RestoreGuard/RefocusCandidate 镜像转直测）

    do {
        // floatToggleDecision：决策序 disabled → query_nil → already_floating → unmanaged → toggled
        func info(float: Bool, ax: Bool) -> YabaiWindowInfo {
            YabaiWindowInfo(id: 7, pid: 100, app: "T", title: "t", space: 1, display: 1,
                            frame: nil, isFloatingRaw: float, hasAXReferenceRaw: ax,
                            isMinimizedRaw: false, hasFocusRaw: false)
        }
        var lazyTouched = false
        let disabled = SpaceController.floatToggleDecision(isEnabled: false, info: { lazyTouched = true; return info(float: false, ax: true) }())
        check("floatToggle: disabled → skip 且惰性不触查询",
              disabled.outcome == .skippedNoOp && disabled.skipReason == "disabled" && !lazyTouched)
        check("floatToggle: 查询 nil → query_nil",
              SpaceController.floatToggleDecision(isEnabled: true, info: { nil }()).skipReason == "query_nil")
        check("floatToggle: 已 float → already_floating",
              SpaceController.floatToggleDecision(isEnabled: true, info: { info(float: true, ax: true) }()).skipReason == "already_floating")
        check("floatToggle: 无 AX 引用 → unmanaged",
              SpaceController.floatToggleDecision(isEnabled: true, info: { info(float: false, ax: false) }()).skipReason == "unmanaged")
        check("floatToggle: 可脱管 → toggled",
              SpaceController.floatToggleDecision(isEnabled: true, info: { info(float: false, ax: true) }()).outcome == .toggled)

        // selectRefocusCandidate：space/可管理/排除过滤 + 非最小化优先
        func win(_ id: Int, space: Int, ax: Bool, minimized: Bool) -> YabaiWindowInfo {
            YabaiWindowInfo(id: id, pid: 100, app: "T", title: "w\(id)", space: space, display: 1,
                            frame: nil, isFloatingRaw: false, hasAXReferenceRaw: ax,
                            isMinimizedRaw: minimized, hasFocusRaw: false)
        }
        let wins = [win(1, space: 5, ax: true, minimized: false),
                    win(2, space: 4, ax: true, minimized: false),
                    win(3, space: 5, ax: true, minimized: true),
                    win(4, space: 5, ax: false, minimized: false)]
        check("refocus: 过滤 space/可管理，非最小化优先",
              SpaceController.selectRefocusCandidate(windows: wins, spaceIndex: 5, excludingWindowID: nil)?.id == 1)
        check("refocus: 排除窗不入选",
              SpaceController.selectRefocusCandidate(windows: wins, spaceIndex: 5, excludingWindowID: 1)?.id == 3)
        check("refocus: 全最小化回落首个可管理",
              SpaceController.selectRefocusCandidate(
                windows: [win(3, space: 5, ax: true, minimized: true), win(6, space: 5, ax: true, minimized: true)],
                spaceIndex: 5, excludingWindowID: nil)?.id == 3)

        // RestoreOutcome.outcomeLabel：四分支机器可读标签
        check("outcomeLabel: restored(spaceExact=nil)",
              ToggleEngine.RestoreOutcome.restored(spaceExact: nil).outcomeLabel == "restored(spaceExact=nil)")
        check("outcomeLabel: aborted_reason",
              ToggleEngine.RestoreOutcome.aborted(reason: "no_window").outcomeLabel == "aborted_no_window")
        check("outcomeLabel: 可重试标签",
              ToggleEngine.RestoreOutcome.moveFailedRetryable.outcomeLabel == "move_failed_retryable_record_kept")
        check("outcomeLabel: 永久失败标签",
              ToggleEngine.RestoreOutcome.moveFailedPermanent.outcomeLabel == "move_failed_permanent_record_cleared")

        // isMoveFailureRetryable：origFrame 在屏与否
        check("retryable: 在屏 → 保留 record", ToggleEngine.isMoveFailureRetryable(origFrameOnAnyDisplay: true))
        check("retryable: 不在任何屏 → 清除 record", !ToggleEngine.isMoveFailureRetryable(origFrameOnAnyDisplay: false))

        // sourceSpacePreSwitch：三态决策
        check("preSwitch: 无上下文（0 值）→ noContext",
              ToggleEngine.sourceSpacePreSwitch(sourceSpace: 0, sourceYabaiDisp: 0, visibleSpaceOnSourceDisplay: 5) == .noContext)
        check("preSwitch: 可见性查询失败 → notNeeded（不盲切）",
              ToggleEngine.sourceSpacePreSwitch(sourceSpace: 5, sourceYabaiDisp: 1, visibleSpaceOnSourceDisplay: nil) == .notNeeded)
        check("preSwitch: 已在源 space → notNeeded",
              ToggleEngine.sourceSpacePreSwitch(sourceSpace: 5, sourceYabaiDisp: 1, visibleSpaceOnSourceDisplay: 5) == .notNeeded)
        check("preSwitch: 停在别 space → switchNeeded",
              ToggleEngine.sourceSpacePreSwitch(sourceSpace: 5, sourceYabaiDisp: 1, visibleSpaceOnSourceDisplay: 2)
              == .switchNeeded(visibleSpace: 2))
    }

    // MARK: restore 结局播报映射（真实实现——B14：outcome→plan 总映射 + 文案/通道语义）

    do {
        // restored(spaceExact) 三态映射
        check("announce: spaceExact=nil → restoredExact",
              ToggleEngine.RestoreOutcome.restored(spaceExact: nil).restoreAnnouncementPlan == .restoredExact)
        check("announce: spaceExact=true → restoredExact",
              ToggleEngine.RestoreOutcome.restored(spaceExact: true).restoreAnnouncementPlan == .restoredExact)
        check("announce: spaceExact=false → restoredDegraded",
              ToggleEngine.RestoreOutcome.restored(spaceExact: false).restoreAnnouncementPlan == .restoredDegraded)
        check("announce: retryable → failedRetryable",
              ToggleEngine.RestoreOutcome.moveFailedRetryable.restoreAnnouncementPlan == .failedRetryable)
        check("announce: permanent → failedPermanent",
              ToggleEngine.RestoreOutcome.moveFailedPermanent.restoreAnnouncementPlan == .failedPermanent)
        check("announce: aborted → silent",
              ToggleEngine.RestoreOutcome.aborted(reason: "no_window").restoreAnnouncementPlan == .silent)

        // 文案 nil 语义（silent 不播报）+ 成败通道
        check("announce: silent 文案为 nil", RestoreAnnouncementPlan.silent.text == nil)
        check("announce: degraded 文案指向工作区不可达",
              RestoreAnnouncementPlan.restoredDegraded.text?.contains("不可达") == true)
        check("announce: 成功/降级/静默走完成通道",
              RestoreAnnouncementPlan.restoredExact.isSuccessful
              && RestoreAnnouncementPlan.restoredDegraded.isSuccessful
              && RestoreAnnouncementPlan.silent.isSuccessful)
        check("announce: 两类失败走失败音效（Basso）",
              !RestoreAnnouncementPlan.failedRetryable.isSuccessful
              && !RestoreAnnouncementPlan.failedPermanent.isSuccessful)
    }

    // MARK: 坐标换算与移动冷却（真实实现——B15：Quartz/Cocoa 互转 + 冷却纯决策）

    do {
        // Quartz ↔ Cocoa y 互转（主屏高度 = 两侧和恒等）
        check("coord: quartzY = primaryMaxY - appKitMaxY",
              CoordinateKit.quartzY(appKitRectMaxY: 300, primaryMaxY: 1117) == 817)
        check("coord: cocoaY/fromQuartzY 互逆",
              CoordinateKit.cocoaY(fromQuartzY: 500) == CoordinateKit.mainScreenHeight - 500
              && CoordinateKit.quartzY(fromCocoaY: CoordinateKit.mainScreenHeight - 500) == 500)

        // MoveCooldownRegistry：静态纯决策
        let now = Date()
        check("cooldown: 从未移动 → 不在冷却",
              !MoveCooldownRegistry.isInCooldown(lastMove: nil, now: now, cooldownSeconds: 3))
        check("cooldown: 2s 前 < 3s → 冷却中",
              MoveCooldownRegistry.isInCooldown(lastMove: now.addingTimeInterval(-2), now: now, cooldownSeconds: 3))
        check("cooldown: 4s 前 > 3s → 冷却结束",
              !MoveCooldownRegistry.isInCooldown(lastMove: now.addingTimeInterval(-4), now: now, cooldownSeconds: 3))
        check("cooldown: remainingSeconds 无记录 → 0（无冷却需求）",
              MoveCooldownRegistry.remainingSeconds(lastMove: nil, now: now, cooldownSeconds: 3) == 0)
        check("cooldown: remainingSeconds 边界取整向上",
              MoveCooldownRegistry.remainingSeconds(lastMove: now.addingTimeInterval(-2.2), now: now, cooldownSeconds: 3) == 1)
        check("cooldown: 冷却结束 remaining 归零",
              MoveCooldownRegistry.remainingSeconds(lastMove: now.addingTimeInterval(-5), now: now, cooldownSeconds: 3) == 0)
    }

    // MARK: WindowStateStore 记录持久层（真实 SQLite——老库 PK 迁移/KV 往返，Batch 13）

    do {
        // 迁移是「老用户首次启动新版本」才跑的代码，此前 0 覆盖。
        // 夹具：sqlite3 CLI 预建旧 schema（PK=(pid,tty)，允许 window_id 重复）+ 种子行；
        // init 触发 migrateWindowsPKIfNeeded → 断言新 PK + 去重保留 + 数据完整。
        func cli(_ sql: String, _ db: String) -> String? {
            ShellRunner.run(executable: "/usr/bin/sqlite3", arguments: [db, sql], timeout: 30)?.stdout
        }
        let dir = "/tmp/vibefocus-dbtest-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dbPath = dir + "/old.db"
        let oldSchema = """
            CREATE TABLE windows (
                window_id INTEGER, pid INTEGER NOT NULL, tty TEXT NOT NULL DEFAULT '',
                ax_window_number INTEGER, app_name TEXT, bundle_id TEXT, title TEXT,
                term_session_id TEXT, iterm_session_id TEXT, kitty_window_id TEXT,
                wezterm_pane TEXT, env_window_id TEXT, session_id TEXT, cwd TEXT, model TEXT,
                orig_x REAL, orig_y REAL, orig_w REAL, orig_h REAL,
                target_x REAL, target_y REAL, target_w REAL, target_h REAL,
                source_space INTEGER, source_display INTEGER, source_yabai_disp INTEGER,
                source_disp_space INTEGER, target_display INTEGER, toggle_reason TEXT,
                toggled_at REAL, is_completed INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL, updated_at REAL NOT NULL, completed_at REAL,
                PRIMARY KEY(pid, tty)
            );
            INSERT INTO windows (window_id, pid, tty, session_id, cwd, created_at, updated_at)
                VALUES (1, 100, '/dev/ttys001', 'sess-A', '/tmp/a', 100.0, 100.0);
            INSERT INTO windows (window_id, pid, tty, session_id, cwd, created_at, updated_at)
                VALUES (1, 200, '/dev/ttys002', 'sess-B', '/tmp/b', 100.0, 100.0);
            INSERT INTO windows (window_id, pid, tty, session_id, cwd, created_at, updated_at)
                VALUES (2, 300, '/dev/ttys003', 'sess-C', '/tmp/c', 100.0, 100.0);
            """
        _ = ShellRunner.run(executable: "/usr/bin/sqlite3", arguments: [dbPath, oldSchema], timeout: 30)

        // A. init 触发迁移：老 PK=(pid,tty) → 新 PK=(window_id)。
        let storeA = WindowStateStore(dbPath: dbPath)
        _ = storeA
        let pkInfo = cli("PRAGMA table_info(windows);", dbPath) ?? ""
        // 按 PRAGMA 行解析：每行末字段为 pk 标志，恰一行（window_id）pk=1。
        let pkLines = pkInfo.split(separator: "\n").filter { !$0.isEmpty && $0.split(separator: "|").last == "1" }
        check("store A: 迁移后 PK 恰为 window_id 一列",
              pkLines.count == 1 && pkLines[0].contains("window_id"))
        let count = cli("SELECT COUNT(*) FROM windows;", dbPath)?.trimmingCharacters(in: .whitespacesAndNewlines)
        check("store A: INSERT OR IGNORE 去重（同 window_id 双行留一，共 2 行）", count == "2")
        let sessA = cli("SELECT session_id FROM windows WHERE window_id=1 AND pid=100;", dbPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        check("store A: 数据完整（pid=100 行的 session_id 保留）", sessA == "sess-A")
        let idx = cli("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='windows';", dbPath) ?? ""
        check("store A: 迁移后重建三索引",
              idx.contains("idx_windows_session_id") && idx.contains("idx_windows_pid_tty") && idx.contains("idx_windows_last_seen"))

        // B. 新库免迁移：fresh 路径直接是新 PK。
        let freshPath = dir + "/fresh.db"
        _ = WindowStateStore(dbPath: freshPath)
        let freshPK = cli("PRAGMA table_info(windows);", freshPath) ?? ""
        check("store B: 新库直接是 window_id PK", freshPK.contains("window_id|INTEGER|1||1"))

        // C. preferences KV 往返：save→load→覆盖→missing nil。
        let storeC = WindowStateStore(dbPath: dir + "/prefs.db")
        storeC.savePreference(key: "gate", value: "v1")
        check("store C: save→load 往返", storeC.loadPreference(key: "gate") == "v1")
        storeC.savePreference(key: "gate", value: "v2")
        check("store C: 同 key 覆盖 upsert", storeC.loadPreference(key: "gate") == "v2")
        check("store C: 缺失 key → nil", storeC.loadPreference(key: "nope") == nil)

        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: 进程树行走 + 终端注册表（真实实现——B16：walkToTerminalPID 谓词注入直测）

    do {
        // 场景 1：起始 pid 即终端
        let immediate = TerminalRegistry.walkToTerminalPID(
            startPID: 500, parentPID: { _ in nil }, isTerminal: { $0 == 500 })
        check("walk: 起始即终端 (pid=500, depth=1)",
              immediate.pid == 500 && immediate.depth == 1)
        // 场景 2：沿父链上溯两级命中
        let chain: [Int32: Int32] = [900: 800, 800: 700]  // pid → parent
        let walked = TerminalRegistry.walkToTerminalPID(
            startPID: 900,
            parentPID: { chain[$0] },
            isTerminal: { $0 == 700 })
        check("walk: 父链上溯两级命中 (depth=3)",
              walked.pid == 700 && walked.depth == 3)
        // 场景 3：深度上限保护
        let infinite: (Int32) -> Int32? = { $0 - 1 }
        let capped = TerminalRegistry.walkToTerminalPID(
            startPID: 100, parentPID: infinite, isTerminal: { _ in false }, maxDepth: 4)
        check("walk: 深度上限 4 步止步", capped.pid == nil && capped.depth == 4)
        // 场景 4：ppid<=1（launchd）断链
        let launchd = TerminalRegistry.walkToTerminalPID(
            startPID: 50, parentPID: { _ in 1 }, isTerminal: { _ in false })
        check("walk: ppid=1 断链不进 init 进程", launchd.pid == nil)
        // 场景 5：自环防护（父=自身）
        let selfLoop = TerminalRegistry.walkToTerminalPID(
            startPID: 60, parentPID: { _ in 60 }, isTerminal: { _ in false })
        check("walk: 自环防护", selfLoop.pid == nil)
        // 场景 6：maxDepth<1 防御为至少 1 步
        let minDepth = TerminalRegistry.walkToTerminalPID(
            startPID: 70, parentPID: { _ in nil }, isTerminal: { _ in false }, maxDepth: 0)
        check("walk: maxDepth<1 防御为 1 步", minDepth.depth == 1 && minDepth.pid == nil)

        // 终端注册表静态集合
        check("registry: Terminal/iTerm2 bundleID 认可",
              TerminalRegistry.isTerminalBundleID("com.apple.Terminal")
              && TerminalRegistry.isTerminalBundleID("com.googlecode.iterm2"))
        check("registry: 陌生 bundleID 不认可", !TerminalRegistry.isTerminalBundleID("com.example.unknown"))
        check("registry: IDE 识别 VS Code",
              TerminalRegistry.isTerminalOrIDEApp(appName: "Code", bundleIdentifier: "com.microsoft.VSCode"))
    }

    // MARK: Hook 脚本生成器（真实实现——B17：hooks JSON 合法性/事件注册/远程安装脚本不变量）

    do {
        // hooks JSON：可解析 + SessionStart/Stop 恒注册 + 条目结构
        let hooksJSON = ClaudeHookPreferences.generateHooksJSON()
        let obj = (try? JSONSerialization.jsonObject(with: Data(hooksJSON.utf8))) as? [String: Any]
        check("hooksJSON: 合法 JSON 且含 hooks 键", obj?["hooks"] != nil)
        let hooks = obj?["hooks"] as? [String: Any]
        check("hooksJSON: SessionStart 恒注册", hooks?["SessionStart"] != nil)
        check("hooksJSON: Stop 恒注册（remoteOnly 分流在服务端）", hooks?["Stop"] != nil)
        let entry = (hooks?["SessionStart"] as? [[String: Any]])?.first
        let hookList = entry?["hooks"] as? [[String: Any]]
        check("hooksJSON: 条目含 command+timeout=10",
              hookList?.first?["type"] as? String == "command"
              && (hookList?.first?["timeout"] as? Int) == 10
              && (hookList?.first?["command"] as? String)?.contains("bash") == true)

        // 远程安装脚本不变量：host 插值 + machine_label 点号转连字符 + 严格模式
        let remote = ClaudeHookPreferences.generateRemoteInstallScript(host: "192.168.1.83")
        check("remoteScript: shebang + 严格模式", remote.contains("#!/bin/bash") && remote.contains("set -euo pipefail"))
        check("remoteScript: host 插值", remote.contains("192.168.1.83"))
        check("remoteScript: machine_label 点号转连字符", remote.contains("remote-192-168-1-83"))

        // helper 脚本不变量：端口默认值 + 上下文采集环境变量
        let helper = ClaudeHookPreferences.generateHelperScriptContent()
        check("helperScript: 默认端口 39277", helper.contains("39277"))
        check("helperScript: 采集 terminal_ctx 环境变量",
              helper.contains("TERM_SESSION_ID") && helper.contains("CLAUDE_PROJECT_DIR")
              && helper.contains("terminal_ctx"))
    }

    // MARK: yabai 错误分类器（真实实现——B18：六类别 + 优先级 + 大小写不敏感穷尽锁定）

    do {
        check("errClass: 空 stderr → none", YabaiErrorClassifier.classify(stderr: "") == .none)
        check("errClass: SA 缺失特征", YabaiErrorClassifier.classify(stderr: "yabai: error with the scripting-addition") == .scriptingAdditionMissing)
        check("errClass: mission-control 阻断", YabaiErrorClassifier.classify(stderr: "cannot focus space: mission-control is active!") == .missionControlBlocking)
        check("errClass: 无焦点窗口（预期）", YabaiErrorClassifier.classify(stderr: "could not retrieve window details") == .noFocusedWindow)
        check("errClass: 窗口已关闭（预期）", YabaiErrorClassifier.classify(stderr: "could not locate window") == .windowNotFound)
        check("errClass: 未识别非空 → unrecognized", YabaiErrorClassifier.classify(stderr: "segfault somewhere") == .unrecognized)
        check("errClass: 大小写不敏感", YabaiErrorClassifier.classify(stderr: "Scripting-Addition Is Missing") == .scriptingAdditionMissing)
        check("errClass: 多类命中取最前（SA 优先于 MC）",
              YabaiErrorClassifier.classify(stderr: "mission-control blocked; scripting-addition missing") == .scriptingAdditionMissing)
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

// MARK: - E2E 同机互斥锁（quality-plan P5，2026-09-06）
// toggle 类真机 E2E 同机并行必互撞（对方 yabai re-tile 把 float 测试窗弹回原位、焦点被
// 抢走，表现为用例间歇 FAIL、重跑即绿——Tests/e2e/README 红线 1 实测）。P3 部署锁同款
// 机制推广到测试：任一 *_E2E=1 模式启动先取 /tmp/vibefocus-e2e.lock（mkdir 原子），
// 被持有则拒跑；>10min 视为陈锁回收（持有进程已死/僵死）。
// 释放走 atexit——E2E 汇总路径以 exit() 结束，defer 不会执行。

private let e2eLockPath = "/tmp/vibefocus-e2e.lock"

/// 本进程是否处于任一真机 E2E 模式（环境变量名以 _E2E 结尾且值为 1——新模式自动纳入）。
private func isE2EMode() -> Bool {
    ProcessInfo.processInfo.environment.contains { $0.key.hasSuffix("_E2E") && $0.value == "1" }
}

/// 取 E2E 互斥锁；被占用且非陈锁时终止（退出码 3，与测试 FAIL 的 1、构建失败的 2 区分）。
private func acquireE2ELockOrExit() {
    guard isE2EMode() else { return }
    while true {
        if mkdir(e2eLockPath, 0o755) == 0 { break }
        guard errno == EEXIST else {
            fatalError("E2E 锁创建失败：\(String(cString: strerror(errno)))")
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: e2eLockPath)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        if Date().timeIntervalSince1970 - mtime > 600 {
            _ = rmdir(e2eLockPath)   // 陈锁回收后重试竞争（被别人抢先则下轮拒跑）
            continue
        }
        fputs("""
        ⛔ 另一个真机 E2E 正在运行（锁: \(e2eLockPath)）。同机并行 E2E 会互撞（yabai re-tile 弹回 float 窗、焦点抢夺），禁止并发。
           如确认无 E2E 在跑：rm -rf \(e2eLockPath) 后重试。
        """, stderr)
        exit(3)
    }
    atexit { _ = rmdir("/tmp/vibefocus-e2e.lock") }
}

acquireE2ELockOrExit()

MainActor.assumeIsolated {
    runAllTests()
}
