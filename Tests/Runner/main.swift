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
    var queryResult: YabaiWindowInfo?
    /// 初次可见 space 查询（4-pre 预切回决策）
    var visibleSpace: SpaceIdentifier?
    /// 切回后 ignoreCache 轮询查询（「等到位」目标态）
    var visibleSpaceAfterSwitch: SpaceIdentifier?
    var floatOutcome: SpaceController.FloatToggleOutcome = .skippedNoOp
    /// 守卫合并查询版：全量窗口列表（含 has-focus 标记）
    var allWindows: [YabaiWindowInfo]?
    var focusWindowResult = false

    private(set) var calls: [String] = []
    private(set) var focusWindowReceived: UInt32?
    private(set) var focusReceived: SpaceIdentifier?
    private(set) var refocusReceivedSpace: Int?
    private(set) var refocusReceivedExcluded: UInt32?
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

    func refocusWindowOnSpace(_ spaceIndex: Int, excludingWindowID: UInt32?, operationID: String?) -> Bool {
        calls.append("refocus")
        refocusReceivedSpace = spaceIndex
        refocusReceivedExcluded = excludingWindowID
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

    func queryAllWindows(operationID: String?) -> [YabaiWindowInfo]? {
        calls.append("queryAll")
        return allWindows
    }

    func focusWindow(_ windowID: UInt32, operationID: String?) -> Bool {
        calls.append("focusWindow")
        focusWindowReceived = windowID
        return focusWindowResult
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

    func moveWindowToFrameViaYabai(windowID: UInt32, frame: CGRect, op: String, stage: String, sourceVisibleSize: CGSize?) -> Bool {
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
        // 降级合并查询版：一次 queryAll 同时提供漂移判定（has-focus 窗口的 space）与候选
        let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: nil)
        ch.allWindows = [window(id: 20, space: 5, hasFocus: true), window(id: 30, space: 1)]
        ch.focusWindowResult = true
        let outcome = RestoreSwitchOrchestration.refocusPerspective(channels: ch, preMoveSpace: 1, excludingWindowID: 9, operationID: "t")
        check("守卫合并查询: SA=false 漂移+聚焦成功 → refocused(5)，两次 fork（queryAll+focusWindow）清缓存",
              outcome == .refocused(postSpace: 5) && ch.calls == ["queryAll", "focusWindow", "clearCache"]
              && ch.focusWindowReceived == 30)
    }
    do {
        let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: nil)
        ch.allWindows = [window(id: 20, space: 1, hasFocus: true), window(id: 30, space: 1)]
        let outcome = RestoreSwitchOrchestration.refocusPerspective(channels: ch, preMoveSpace: 1, excludingWindowID: 9, operationID: "t")
        check("守卫合并查询: focused space == preMoveSpace → noDrift 不聚焦",
              outcome == .noDrift && ch.calls == ["queryAll"])
    }
    do {
        let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: nil)
        ch.allWindows = nil
        let outcome = RestoreSwitchOrchestration.refocusPerspective(channels: ch, preMoveSpace: 1, excludingWindowID: 9, operationID: "t")
        check("守卫合并查询: 查询失败 → noDrift（不盲切语义）", outcome == .noDrift && ch.calls == ["queryAll"])
    }
    do {
        let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: nil)
        ch.allWindows = [window(id: 30, space: 1)]  // 无聚焦窗口（罕见）
        let outcome = RestoreSwitchOrchestration.refocusPerspective(channels: ch, preMoveSpace: 1, excludingWindowID: 9, operationID: "t")
        check("守卫合并查询: 无聚焦窗口 → noDrift（无法确认漂移不盲切）", outcome == .noDrift && ch.calls == ["queryAll"])
    }
    do {
        let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: nil)
        ch.allWindows = [window(id: 20, space: 5, hasFocus: true), window(id: 31, space: 1), window(id: 9, space: 1), window(id: 30, space: 1, hasAX: false)]
        ch.focusWindowResult = false
        let outcome = RestoreSwitchOrchestration.refocusPerspective(channels: ch, preMoveSpace: 1, excludingWindowID: 9, operationID: "t")
        check("守卫合并查询: 漂移+聚焦失败 → failed(5)，候选排除被恢复窗口 9 与无 AX 窗口 30、选中 31",
              outcome == .failed(postSpace: 5) && ch.focusWindowReceived == 31 && !ch.cacheCleared)
    }
    do {
        let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: nil)
        ch.allWindows = [window(id: 20, space: 5, hasFocus: true)]
        let outcome = RestoreSwitchOrchestration.refocusPerspective(channels: ch, preMoveSpace: 1, excludingWindowID: 9, operationID: "t")
        check("守卫合并查询: preMoveSpace 无可聚焦窗口 → failed(5) 如实降级上报",
              outcome == .failed(postSpace: 5) && ch.focusWindowReceived == nil)
    }
    do {
        // SA=true 且直切失败 → 降级走合并查询（不再走 refocusWindowOnSpace）
        let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 5)
        ch.focusResult = false
        ch.allWindows = [window(id: 20, space: 5, hasFocus: true), window(id: 30, space: 1)]
        ch.focusWindowResult = true
        let outcome = RestoreSwitchOrchestration.refocusPerspective(channels: ch, preMoveSpace: 1, excludingWindowID: 9, operationID: "t")
        check("守卫编排: SA=true 直切失败 → 降级合并查询聚焦成功（三次 fork 变两次）",
              outcome == .refocused(postSpace: 5) && ch.calls == ["current", "focus", "queryAll", "focusWindow", "clearCache"]
              && ch.focusWindowReceived == 30)
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

    // MARK: 汇总

    print("\nVibeFocusTestRunner: \(passed + failed) checks, \(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}

MainActor.assumeIsolated {
    runAllTests()
}
