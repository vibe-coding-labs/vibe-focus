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

// B56：harness 基类——check/计数器/构造助手提升至此，各域测试以 extension 分布在
// 同目录的 RunnerXxxTests.swift（并行会话冲突面收敛：新增测试改到对应域文件，不再挤 main.swift）。
@MainActor final class RunnerHarness {
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
    func runAllTests() {
        runRestoreOrchestrationTests()
        runLayoutGridTests()
        runGridTargetE2E()
        runGridTargetLogicTests()
        runGridSpaceE2E()
        runSizeE2E()
        runFloatSettleE2E()
        runConvergencePipelineTests()
        runTitleE2E()
        runTerminalGridUnitTests()
        runShellRunnerTests()
        runRemoteDeployTests()
        runJournalAppendTests()
        runLocatorParseEdgeTests()
        runRecordExitTests()
        runJournalB145Tests()
        runJournalFDTests()
        runHelperInstallTests()
        runB134SmallTopUps()
        runDisplayWorkAreaTests()
        runTerminalDialectTests()
        runSoundVoiceHookTests()
        runRegistryStoreTests()
        runRegistryPurgeTests()
        runHookWalkTests()
        runHookModelsTests()
        runSpaceIndexTests()
        runSpaceContextTests()
        runYabaiUtilsTests()
        runCoordinateTypesTests()
        runSpaceIdentityTests()
        runYabaiModelTests()
        runPruneExpiryTests()
        runCaptureFilterTests()
        runUsageTableTests()
        runPureSweepA()
        runPureSweepB()
        runAppIdentityTests()
        runHotKeyDisplayTests()
        runHotKeyEventMatchTests()
        runToggleDecisionTests()
        runAXSelfHealTests()
        runRemoteInstallTests()
        runForwarderBehaviorTests()
        runSpoolDrainTests()
        runInputBubbleTests()
        runBubbleHotkeyRecorderTests()
        runBubbleResizeTests()
        runBubbleScrollPolicyTests()
    // MARK: 汇总

    print("\nVibeFocusTestRunner: \(passed + failed) checks, \(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
    }
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
    RunnerHarness().runAllTests()
}
