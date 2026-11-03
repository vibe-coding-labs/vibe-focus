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
final class RestoreSeqLog {
    var events: [String] = []
    func add(_ e: String) { events.append(e) }
}

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

    /// 焦点 display 队列（守卫「焦点换屏=跨屏跟随」判据；空队列=查询失败→守卫走旧行为）
    var focusedDisplayQueue: [Int?] = []

    func focusedDisplayIndex() -> Int? {
        calls.append("focusedDisplay")
        guard !focusedDisplayQueue.isEmpty else { return nil }
        return focusedDisplayQueue.removeFirst()
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
    /// 环境不具备而整域跳过的计数（不计 PASS/FAIL，汇总单列）。
    var skipped = 0
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

    /// B228：等 B180 异步 availability 探测落地。探测 fork 在 utility 线程、结果经
    /// MainActor.run 回主线程——E2E 同步上下文占着主线程，必须泵 RunLoop 才收得到
    /// （B154 短片泵铁律同源）。返回最终 isEnabled。
    func waitForSpaceAvailability(timeout: TimeInterval = 15) -> Bool {
        SpaceController.shared.refreshAvailability(force: true)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if SpaceController.shared.isEnabled { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return SpaceController.shared.isEnabled
    }

    /// 弹真实 UI 的测试域统一门（2026-09-26 用户明令）：这台机器多人/多 Agent 共用，
    /// 默认套件绝不允许弹任何面板/弹窗/置前窗口——历史上一跑套件气泡历史面板、
    /// 标题编辑弹窗就会打到用户真实前台窗上（实测实录）。要跑这些域必须显式
    /// 设 VIBEFOCUS_UI_E2E=1（只应在机器空闲时人工执行）。
    func runUIGated(_ name: String, _ body: () -> Void) {
        if ProcessInfo.processInfo.environment["VIBEFOCUS_UI_E2E"] == "1" {
            body()
        } else {
            check("uiGate: \(name) 跳过（默认零弹窗；要跑请设 VIBEFOCUS_UI_E2E=1）", true)
        }
    }

    /// UI 域注册：既走域过滤（逐域采集时只在选中进程里求值），又保留弹窗门。
    /// 未选中时 runDomain 直接返回，不会落到 runUIGated 的 skip 分支。
    func runDomainUIGated(_ name: String, _ body: () -> Void) {
        runDomain(name) { runUIGated(name, body) }
    }

    /// 域过滤（2026-11-03）：CI 覆盖/定向回归用 `VIBEFOCUS_RUNNER_DOMAINS=runA,runB`
    /// 只跑指定域；未设置或为空 = 全量（真机门禁口径不变）。
    private lazy var requestedDomains: Set<String>? = {
        guard let raw = ProcessInfo.processInfo.environment["VIBEFOCUS_RUNNER_DOMAINS"] else { return nil }
        let names = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return names.isEmpty ? nil : Set(names)
    }()

    /// CI 无 yabai/AX/真实终端进程时的整域跳过名单（`VIBEFOCUS_RUNNER_SKIP_DOMAINS`）；
    /// 真机门禁不设此变量 = 全跑。跳过计入 skipped，汇总单列。
    private lazy var skippedDomains: Set<String> = {
        guard let raw = ProcessInfo.processInfo.environment["VIBEFOCUS_RUNNER_SKIP_DOMAINS"] else { return [] }
        return Set(raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }()

    func runDomain(_ name: String, _ body: () -> Void) {
        if let requested = requestedDomains, !requested.contains(name) { return }
        if skippedDomains.contains(name) {
            skipped += 1
            print("  SKIP: \(name)（环境不具备：\(ProcessInfo.processInfo.environment["VIBEFOCUS_SKIP_REASON"] ?? "见 VIBEFOCUS_RUNNER_SKIP_DOMAINS")）")
            return
        }
        print("=== \(name) ===")
        body()
    }

    func runAllTests() {
        // 全局静音保险丝（2026-09-26 用户明令）：非 UI E2E 模式拔掉气泡自动唤起三开关
        // ——防任何单例 tick/观察者把气泡打到共享机器用户的前台窗（Runner 域偏好，
        // 不影响装机 App）。uiGate 门控之外的纵深防御。
        if ProcessInfo.processInfo.environment["VIBEFOCUS_UI_E2E"] != "1" {
            InputBubblePreferences.isEnabled = false
            InputBubblePreferences.autoShowOnFocus = false
            InputBubblePreferences.autoShowOnMoveToMain = false
        }
        runDomain("runRestoreOrchestrationTests") { runRestoreOrchestrationTests() }
        runDomain("runRestoreStageTests") { runRestoreStageTests() }
        runDomain("runRestoreStageClampTests") { runRestoreStageClampTests() }
        runDomain("runLayoutGridTests") { runLayoutGridTests() }
        runDomain("runGridTargetE2E") { runGridTargetE2E() }
        runDomain("runGridTargetLogicTests") { runGridTargetLogicTests() }
        runDomain("runGridSpaceE2E") { runGridSpaceE2E() }
        runDomain("runSizeE2E") { runSizeE2E() }
        runDomain("runAXWriteE2E") { runAXWriteE2E() }
        runDomain("runBubblePanelE2E") { runBubblePanelE2E() }
        runDomain("runFloatSettleE2E") { runFloatSettleE2E() }
        runDomain("runConvergencePipelineTests") { runConvergencePipelineTests() }
        runDomain("runTitleE2E") { runTitleE2E() }
        runDomain("runTerminalGridUnitTests") { runTerminalGridUnitTests() }
        runDomain("runGridTargetResolveInstanceTests") { runGridTargetResolveInstanceTests() }
        runDomain("runBubblePanelGeometryTests") { runBubblePanelGeometryTests() }
        runDomain("runShellRunnerTests") { runShellRunnerTests() }
        runDomain("runRemoteDeployTests") { runRemoteDeployTests() }
        runDomain("runJournalAppendTests") { runJournalAppendTests() }
        runDomain("runJournalProductionPathTests") { runJournalProductionPathTests() }
        runDomain("runLocatorParseEdgeTests") { runLocatorParseEdgeTests() }
        runDomain("runRecordExitTests") { runRecordExitTests() }
        runDomain("runJournalB145Tests") { runJournalB145Tests() }
        runDomain("runJournalFDTests") { runJournalFDTests() }
        runDomain("runHelperInstallTests") { runHelperInstallTests() }
        runDomain("runB134SmallTopUps") { runB134SmallTopUps() }
        runDomain("runDisplayWorkAreaTests") { runDisplayWorkAreaTests() }
        runDomain("runTerminalDialectTests") { runTerminalDialectTests() }
        runDomain("runSoundVoiceHookTests") { runSoundVoiceHookTests() }
        runDomain("runRegistryStoreTests") { runRegistryStoreTests() }
        runDomain("runStorePreferenceKVTests") { runStorePreferenceKVTests() }
        runDomain("runCGWindowEntryEdgeTests") { runCGWindowEntryEdgeTests() }
        runDomain("runRegistryPurgeTests") { runRegistryPurgeTests() }
        runDomain("runHookWalkTests") { runHookWalkTests() }
        runDomain("runRestoreInFlightTests") { runRestoreInFlightTests() }
        runDomain("runRegistryFindPIDTests") { runRegistryFindPIDTests() }
        runDomain("runWindowMoveExecuteTests") { runWindowMoveExecuteTests() }
        runDomain("runWindowResolutionFallbackTests") { runWindowResolutionFallbackTests() }
        runDomain("runHookInstallHomeTests") { runHookInstallHomeTests() }
        runDomain("runHookClaudeSettingsHomeTests") { runHookClaudeSettingsHomeTests() }
        runDomain("runSettingsSectionRenderTests") { runSettingsSectionRenderTests() }
        runDomain("runAgentAccessTests") { runAgentAccessTests() }
        runDomain("runAgentAccessLoopbackTests") { runAgentAccessLoopbackTests() }
        runDomain("runMCPRegistrationTests") { runMCPRegistrationTests() }
        runDomain("runAgentSettingsWriteTests") { runAgentSettingsWriteTests() }
        runDomain("runAgentOnboardingTests") { runAgentOnboardingTests() }
        runDomain("runAuditBubbleSessionRestoreTests") { runAuditBubbleSessionRestoreTests() }
        runDomain("runAuditWindowHotkeyTests") { runAuditWindowHotkeyTests() }
        runDomain("runSoundVoiceChannelSemanticsTests") { runSoundVoiceChannelSemanticsTests() }
        runDomain("runSettingsSectionDeepRenderTests") { runSettingsSectionDeepRenderTests() }
        runDomain("runSettingsSectionDeepRender2Tests") { runSettingsSectionDeepRender2Tests() }
        runDomain("runTGEmptySnapshotRenderTests") { runTGEmptySnapshotRenderTests() }
        runDomain("runSessionListsAndWorkspaceRenderTests") { runSessionListsAndWorkspaceRenderTests() }
        runDomain("runSessionListsAndSettingsUIRenderTests") { runSessionListsAndSettingsUIRenderTests() }
        runDomain("runSettingsCommonSectionRenderTests") { runSettingsCommonSectionRenderTests() }
        runDomain("runWorkspaceAndSessionRenderTests") { runWorkspaceAndSessionRenderTests() }
        runDomain("runAllSectionsRenderTests") { runAllSectionsRenderTests() }
        runDomain("runSoundSectionDeepRenderTests") { runSoundSectionDeepRenderTests() }
        runDomain("runLANViewDeepRenderTests") { runLANViewDeepRenderTests() }
        runDomain("runSettingsSectionStateMatrixTests") { runSettingsSectionStateMatrixTests() }
        runDomain("runSettingsSectionStateRenderTests") { runSettingsSectionStateRenderTests() }
        runDomain("runSettingsSectionDeepRender3Tests") { runSettingsSectionDeepRender3Tests() }
        runDomain("runHotKeyOfflineRouteTests") { runHotKeyOfflineRouteTests() }
        runDomain("runHookModelsTests") { runHookModelsTests() }
        runDomain("runSpaceIndexTests") { runSpaceIndexTests() }
        runDomain("runSpaceContextTests") { runSpaceContextTests() }
        runDomain("runSpaceQueryShapeTests") { runSpaceQueryShapeTests() }
        runDomain("runSpaceSwitchQueryShapeTests") { runSpaceSwitchQueryShapeTests() }
        runDomain("runYabaiUtilsTests") { runYabaiUtilsTests() }
        runDomain("runCoordinateTypesTests") { runCoordinateTypesTests() }
        runDomain("runSpaceIdentityTests") { runSpaceIdentityTests() }
        runDomain("runScreenIndexPrefsMigrationTests") { runScreenIndexPrefsMigrationTests() }
        runDomain("runYabaiModelTests") { runYabaiModelTests() }
        runDomain("runPruneExpiryTests") { runPruneExpiryTests() }
        runDomain("runSessionRestoreTests") { runSessionRestoreTests() }
        runDomain("runSessionRestoreCoverageTopUps") { runSessionRestoreCoverageTopUps() }
        runDomain("runSessionRestoreControllerTests") { runSessionRestoreControllerTests() }
        runDomain("runAutoRestoreTaskBodyTests") { runAutoRestoreTaskBodyTests() }
        runDomain("runSessionRestoreExecutorTests") { runSessionRestoreExecutorTests() }
        runDomain("runSessionRestoreE2E") { runSessionRestoreE2E() }
        runDomain("runUsageTableTests") { runUsageTableTests() }
        runDomain("runPureSweepA") { runPureSweepA() }
        runDomain("runPureSweepB") { runPureSweepB() }
        runDomain("runAppIdentityTests") { runAppIdentityTests() }
        runDomain("runHotKeyDisplayTests") { runHotKeyDisplayTests() }
        runDomain("runHotKeyEventMatchTests") { runHotKeyEventMatchTests() }
        runDomain("runHotKeyRealMachineE2E") { runHotKeyRealMachineE2E() }
        runDomain("runToggleDecisionTests") { runToggleDecisionTests() }
        runDomain("runSingleDisplayToggleTests") { runSingleDisplayToggleTests() }
        runDomain("runStuckRoutingTests") { runStuckRoutingTests() }
        runDomain("runAXSelfHealTests") { runAXSelfHealTests() }
        runDomain("runWatcherSpawnTests") { runWatcherSpawnTests() }
        runDomain("runRemoteInstallTests") { runRemoteInstallTests() }
        runDomain("runForwarderBehaviorTests") { runForwarderBehaviorTests() }
        runDomain("runSpoolDrainTests") { runSpoolDrainTests() }
        runDomain("runInputBubbleTests") { runInputBubbleTests() }
        runDomain("runInputBubbleMarkdownTests") { runInputBubbleMarkdownTests() }
        runDomain("runBubbleHotkeyRecorderTests") { runBubbleHotkeyRecorderTests() }
        runDomain("runBubbleResizeTests") { runBubbleResizeTests() }
        runDomain("runBubbleScrollPolicyTests") { runBubbleScrollPolicyTests() }
        runDomain("runBubbleHistoryTests") { runBubbleHistoryTests() }
        runDomain("runBubbleHistoryPanelTests") { runBubbleHistoryPanelTests() }
        runDomain("runBubbleHistorySearchTests") { runBubbleHistorySearchTests() }
        runDomain("runBubbleHistoryPanelKeyTests") { runBubbleHistoryPanelKeyTests() }
        runDomain("runBubblePanelPureTests") { runBubblePanelPureTests() }
        runDomain("runBubbleActivationPlanTests") { runBubbleActivationPlanTests() }
        runDomain("runPerfMonitorTests") { runPerfMonitorTests() }
        runDomain("runPerfPureTailTests") { runPerfPureTailTests() }
        runDomain("runMenuBarTests") { runMenuBarTests() }
        runDomain("runSpaceSwitchTests") { runSpaceSwitchTests() }
        runDomain("runSpaceQueryYabaiTests") { runSpaceQueryYabaiTests() }
        runDomain("runSpaceRefreshThrottleTests") { runSpaceRefreshThrottleTests() }
        runDomain("runSpaceFloatSkipTests") { runSpaceFloatSkipTests() }
        runDomain("runYabaiPathDiscoveryTests") { runYabaiPathDiscoveryTests() }
        runDomain("runSpoolDrainSeamTests") { runSpoolDrainSeamTests() }
        runDomain("runSpoolDrainLifecycleTests") { runSpoolDrainLifecycleTests() }
        runDomain("runVoiceLLMSummaryTests") { runVoiceLLMSummaryTests() }
        runDomain("runOverlaySignalTests") { runOverlaySignalTests() }
        runDomain("runStorageSweepTests") { runStorageSweepTests() }
        runDomain("runHookInstallSweepTests") { runHookInstallSweepTests() }
        runDomain("runDoctorYabaiSweepTests") { runDoctorYabaiSweepTests() }
        runDomain("runDecisionPrefSweepTests") { runDecisionPrefSweepTests() }
        runDomain("runRegistryGeomSweepTests") { runRegistryGeomSweepTests() }
        runDomain("runServerWidgetSweepTests") { runServerWidgetSweepTests() }
        runDomain("runDrawGuardSweepTests") { runDrawGuardSweepTests() }
        runDomain("runBubbleMouseNavSweepTests") { runBubbleMouseNavSweepTests() }
        runDomain("runRemoteResolvedSweepTests") { runRemoteResolvedSweepTests() }
        runDomain("runOverlayQuerySweepTests") { runOverlayQuerySweepTests() }
        runDomain("runSignalNavTailTests") { runSignalNavTailTests() }
        runDomain("runRestoreGuardSweepTests") { runRestoreGuardSweepTests() }
        runDomain("runGateSweepTests") { runGateSweepTests() }
        runDomain("runTargetResolveTailTests") { runTargetResolveTailTests() }
        runDomain("runSpaceReadOnlySweepTests") { runSpaceReadOnlySweepTests() }
        runDomain("runTerminalRegistryCoverageTests") { runTerminalRegistryCoverageTests() }
        runDomain("runSessionActivityCoverageTests") { runSessionActivityCoverageTests() }
        runDomain("runSessionActivityPruneParseTests") { runSessionActivityPruneParseTests() }
        runDomain("runSessionActivityPersistTests") { runSessionActivityPersistTests() }
        runDomain("runAuditLoggerCoverageTests") { runAuditLoggerCoverageTests() }
        runDomain("runPrefModelsCoverageTests") { runPrefModelsCoverageTests() }
        runDomain("runScreenIndexPrefsSandboxTests") { runScreenIndexPrefsSandboxTests() }
        runDomain("runOverlayWakeRebuildTests") { runOverlayWakeRebuildTests() }
        runDomain("runAppVersionTests") { runAppVersionTests() }
        runDomain("runWindowWorkExecutorTests") { runWindowWorkExecutorTests() }
        runDomain("runNativeSpaceBridgeTests") { runNativeSpaceBridgeTests() }
        runDomain("runNotificationPosterTests") { runNotificationPosterTests() }
        runDomain("runSigtermGracefulTests") { runSigtermGracefulTests() }
        runDomain("runDockBadgeTests") { runDockBadgeTests() }
        runDomain("runVoicePrefsPersistenceTests") { runVoicePrefsPersistenceTests() }
        runDomain("runBubbleClipboardIOTests") { runBubbleClipboardIOTests() }
        runDomain("runDiagnosticsTests") { runDiagnosticsTests() }
        runDomain("runDiagnosticPathTests") { runDiagnosticPathTests() }
        runDomain("runScreenPositionTests") { runScreenPositionTests() }
        runDomain("runLoginItemRefreshTests") { runLoginItemRefreshTests() }
        runDomain("runTitleEditorChannelTests") { runTitleEditorChannelTests() }
        runDomain("runTTYWriterErrorBranchTests") { runTTYWriterErrorBranchTests() }
        runDomain("runVoiceQueueTests") { runVoiceQueueTests() }
        runDomain("runVoiceQueueAdvanceTests") { runVoiceQueueAdvanceTests() }
        runDomain("runKeyEventPosterTests") { runKeyEventPosterTests() }
        runDomain("runHotKeyCarbonEventTests") { runHotKeyCarbonEventTests() }
        runDomain("runBubbleIdleGuardTests") { runBubbleIdleGuardTests() }
        runDomainUIGated("BubbleSubmitPipeline") {
            runBubbleSubmitPipelineTests()
        }
        runDomainUIGated("BubbleLifecyclePanel") {
            runBubbleLifecyclePanelTests()
        }
        runDomainUIGated("BubbleHistoryPanelController") {
            runBubbleHistoryPanelControllerTests()
        }
        runDomainUIGated("BubbleCoverageSweep") {
            runBubbleCoverageSweepTests()
        }
        runDomainUIGated("BubbleCoverageTail") {
            runBubbleCoverageTailTests()
        }
        runDomainUIGated("BubbleCoverageFinale") {
            runBubbleCoverageFinaleTests()
        }
        runDomain("runYabaiAsyncAndVoicePersistTests") { runYabaiAsyncAndVoicePersistTests() }
        runDomainUIGated("AutoShowStart") {
            runAutoShowStartTests()
        }
        runDomain("runVoiceDelegateCallbackTests") { runVoiceDelegateCallbackTests() }
        runDomain("runAXWriteRetryTests") { runAXWriteRetryTests() }
        runDomain("runSpaceMoveSkipTests") { runSpaceMoveSkipTests() }
        runDomain("runSpaceQueryReadOnlyTests") { runSpaceQueryReadOnlyTests() }
        runDomain("runTargetResolveTests") { runTargetResolveTests() }
        runDomain("runHookTestAndAXReadTests") { runHookTestAndAXReadTests() }
        runDomain("runLoginItemCleanupTests") { runLoginItemCleanupTests() }
        runDomain("runAXWriteFailPathTests") { runAXWriteFailPathTests() }
        runDomain("runRestoreGuardTests") { runRestoreGuardTests() }
        runDomain("runCodexTestEventTests") { runCodexTestEventTests() }
        runDomain("runScriptExecutorTests") { runScriptExecutorTests() }
        runDomain("runAppDelegateInstanceTests") { runAppDelegateInstanceTests() }
        runDomain("runAppDelegateTerminateTests") { runAppDelegateTerminateTests() }
        runDomain("runAppDelegateLaunchStepTests") { runAppDelegateLaunchStepTests() }
        runDomain("runInstalledVersionTests") { runInstalledVersionTests() }
        runDomain("runHotKeyTriggerGuardTests") { runHotKeyTriggerGuardTests() }
        runDomain("runPlayAudioFileRealWavTests") { runPlayAudioFileRealWavTests() }
        runDomain("runInstallationsFailPathTests") { runInstallationsFailPathTests() }
        runDomain("runCaptureFocusedWindowTests") { runCaptureFocusedWindowTests() }
        runDomain("runAppleScriptDirectedTests") { runAppleScriptDirectedTests() }
        runDomain("runBubbleButtonCursorTests") { runBubbleButtonCursorTests() }
        runDomain("runSelectionRefreshTests") { runSelectionRefreshTests() }
        runDomain("runHotKeyManagerStateTests") { runHotKeyManagerStateTests() }
        runDomainUIGated("BubbleHistoryPanelGuard") {
            runBubbleHistoryPanelGuardTests()
        }
        runDomain("runToggleEngineStoreTests") { runToggleEngineStoreTests() }
        runDomain("runBubblePreferencesBranchTests") { runBubblePreferencesBranchTests() }
        runDomain("runBindingVerifierTests") { runBindingVerifierTests() }
        runDomain("runSettingsDesignSystemTests") { runSettingsDesignSystemTests() }
        runDomain("runSessionRestoreStoreIOTests") { runSessionRestoreStoreIOTests() }
        runDomain("runAuditLoggerTests") { runAuditLoggerTests() }
        runDomain("runCrashContextTests") { runCrashContextTests() }
        runDomain("runCrashContextBootstrapTests") { runCrashContextBootstrapTests() }
        runDomain("runCrashFatalCaptureTests") { runCrashFatalCaptureTests() }
        runDomain("runVoiceAnnouncementTests") { runVoiceAnnouncementTests() }
        runDomain("runHookPrefsSweepTests") { runHookPrefsSweepTests() }
        runDomain("runSpoolProcessTests") { runSpoolProcessTests() }
        runDomain("runHookDispatchTests") { runHookDispatchTests() }
        runDomain("runHookServerPortGuardTests") { runHookServerPortGuardTests() }
        runDomain("runHookServerRestartGuardTests") { runHookServerRestartGuardTests() }
        runDomain("runToggleFallbackTests") { runToggleFallbackTests() }
        runDomain("runStuckRouteEarlyExitTests") { runStuckRouteEarlyExitTests() }
        runDomain("runToggleDecisionInputTests") { runToggleDecisionInputTests() }
        runDomain("runWindowCoreReadTests") { runWindowCoreReadTests() }
        runDomain("runClaudeCodeFindingTests") { runClaudeCodeFindingTests() }
        runDomain("runResolveWindowEdgeTests") { runResolveWindowEdgeTests() }
        runDomain("runCrashSnapshotBufferTests") { runCrashSnapshotBufferTests() }
        runDomain("runTerminalContextMatchTests") { runTerminalContextMatchTests() }
        runDomain("runDiagnosticsSamplerTests") { runDiagnosticsSamplerTests() }
        runDomain("runAutomationGuardTests") { runAutomationGuardTests() }
        runDomain("runBindingResolutionTests") { runBindingResolutionTests() }
        runDomain("runFocusResolutionTests") { runFocusResolutionTests() }
        runDomain("runGeneratorDoctorTailTests") { runGeneratorDoctorTailTests() }
        runDomain("runDoctorReportTailTests") { runDoctorReportTailTests() }
        runDomain("runPrimaryScreenAuditTests") { runPrimaryScreenAuditTests() }
        runDomain("runLANSettingsViewTests") { runLANSettingsViewTests() }
        runDomain("runBacktraceSamplerTests") { runBacktraceSamplerTests() }
        runDomain("runOverlaySpaceQueryTests") { runOverlaySpaceQueryTests() }
        runDomain("runInstanceGuardTests") { runInstanceGuardTests() }
        runDomain("runBubblePreferencesIOTests") { runBubblePreferencesIOTests() }
        runDomain("runBubbleFollowNavTests") { runBubbleFollowNavTests() }
        runDomain("runBubbleDraftFlushTests") { runBubbleDraftFlushTests() }
        runDomain("runLayoutPreferencesTests") { runLayoutPreferencesTests() }
        runDomain("runSessionRestoreModelCountsTests") { runSessionRestoreModelCountsTests() }
        runDomain("runTerminalRegistryIdentityTests") { runTerminalRegistryIdentityTests() }
        runDomain("runCoordinateScreenQueryTests") { runCoordinateScreenQueryTests() }
        runDomain("runBindingsStoreCoverageTests") { runBindingsStoreCoverageTests() }
        runDomain("runTerminalScriptStragglerTests") { runTerminalScriptStragglerTests() }
        runDomain("runLANLegacyBindingsTests") { runLANLegacyBindingsTests() }
        runDomain("runAnnouncementDescriptionTests") { runAnnouncementDescriptionTests() }
        runDomain("runCrashIPSParserTests") { runCrashIPSParserTests() }
        runDomain("runCrashForensicsIOTests") { runCrashForensicsIOTests() }
        runDomain("runSessionStartNoContextTests") { runSessionStartNoContextTests() }
        runDomain("runItermEnumerateSessionsScriptTests") { runItermEnumerateSessionsScriptTests() }
        runDomain("runDiagnosticsSmallTests") { runDiagnosticsSmallTests() }
        runDomain("runLayoutManagerProbeTests") { runLayoutManagerProbeTests() }
        runDomain("runMoveToMainIdentityWrapperTests") { runMoveToMainIdentityWrapperTests() }
        runDomain("runWindowQueryTests") { runWindowQueryTests() }
        runDomain("runHookGuardTests") { runHookGuardTests() }
        runDomain("runCrashSignalTests") { runCrashSignalTests() }
        runDomain("runSARecoveryStateTests") { runSARecoveryStateTests() }
        runDomain("runSARecoveryGateTests") { runSARecoveryGateTests() }
        runDomain("runSessionSnapshotDerivedTests") { runSessionSnapshotDerivedTests() }
        runDomain("runCapturableWindowTests") { runCapturableWindowTests() }
        runDomain("runBundleIDMappingTests") { runBundleIDMappingTests() }
        runDomain("runJoinPanesTests") { runJoinPanesTests() }
        runDomain("runPaneResolveTests") { runPaneResolveTests() }
        runDomain("runAuditLoggerPureMemoryTests") { runAuditLoggerPureMemoryTests() }
        runDomain("runTitleEditorServiceTests") { runTitleEditorServiceTests() }
        runDomain("runLocatorSeamTests") { runLocatorSeamTests() }
        runDomain("runHookTestPureTests") { runHookTestPureTests() }
        runDomain("runCrashIOReadTests") { runCrashIOReadTests() }
        runDomain("runBubbleAutoShowOrchestrationTests") { runBubbleAutoShowOrchestrationTests() }
        runDomain("runLLMSummaryFallbackTests") { runLLMSummaryFallbackTests() }
        runDomain("runBubbleHistoryPanelViewTests") { runBubbleHistoryPanelViewTests() }
        runDomain("runReadOnlySweepTests") { runReadOnlySweepTests() }
        runDomain("runCaptureSeamTests") { runCaptureSeamTests() }
        runDomain("runSettingsViewSectionBodyTests") { runSettingsViewSectionBodyTests() }
        runDomain("runSoundRulesBodyTests") { runSoundRulesBodyTests() }
        runDomain("runSoundPrefsClampTests") { runSoundPrefsClampTests() }
        runDomain("runWorkspaceSectionBranchTests") { runWorkspaceSectionBranchTests() }
        runDomain("runGridSectionPanelTests") { runGridSectionPanelTests() }
        runDomain("runSettingsRenderPilotTests") { runSettingsRenderPilotTests() }
        runDomain("runSettingsCoverageRenderTests") { runSettingsCoverageRenderTests() }
        // 单分区独立成域：避免 B288 一次渲染 8 段被其中一段拖到整域超时（零 profraw）。
        runDomain("runSettingsRenderOverlaySectionTests") { runSettingsRenderOverlaySectionTests() }
        runDomain("runSettingsRenderWorkspaceSectionTests") { runSettingsRenderWorkspaceSectionTests() }
        runDomain("runSettingsRenderAntiDisturbTests") { runSettingsRenderAntiDisturbTests() }
        runDomain("runSettingsRenderProjectRulesTests") { runSettingsRenderProjectRulesTests() }
        runDomain("runSettingsRenderCustomAudioTests") { runSettingsRenderCustomAudioTests() }
        runDomain("runSettingsRenderCodexTests") { runSettingsRenderCodexTests() }
        runDomain("runSettingsRenderPermissionsDuplicatesTests") { runSettingsRenderPermissionsDuplicatesTests() }
        // 每个 tab 独立成域：B239 单域全 tab 循环在 CI 超时会连带丢掉已渲染 tab 的 profraw。
        runDomain("runSettingsTabGeneralRenderTests") { runSettingsTabGeneralRenderTests() }
        runDomain("runSettingsTabWorkspaceRenderTests") { runSettingsTabWorkspaceRenderTests() }
        runDomain("runSettingsTabOrchestrationRenderTests") { runSettingsTabOrchestrationRenderTests() }
        runDomain("runSettingsTabClaudeIntegrationRenderTests") { runSettingsTabClaudeIntegrationRenderTests() }
        runDomain("runSettingsTabCodexIntegrationRenderTests") { runSettingsTabCodexIntegrationRenderTests() }
        runDomain("runSettingsTabAgentAccessRenderTests") { runSettingsTabAgentAccessRenderTests() }
        runDomain("runSettingsTabAppearanceRenderTests") { runSettingsTabAppearanceRenderTests() }
        runDomainUIGated("SettingsWindowController") {
            runSettingsWindowControllerTests()
        }
        runDomain("runSettingsSnapshotRenderTests") { runSettingsSnapshotRenderTests() }
        runDomain("runHookPayloadBuilderTests") { runHookPayloadBuilderTests() }
        runDomain("runHookTestFailurePathTests") { runHookTestFailurePathTests() }
        runDomain("runMiscStragglerTests") { runMiscStragglerTests() }
        runDomain("runScreenMinimapViewTests") { runScreenMinimapViewTests() }
        runDomain("runSettingsTerminalGridTabRenderTests") { runSettingsTerminalGridTabRenderTests() }
        runDomain("runScreenIndexPrefsTests") { runScreenIndexPrefsTests() }
        runDomain("runSettingsDGroupTests") { runSettingsDGroupTests() }
        runDomain("runLLMRequestTests") { runLLMRequestTests() }
        runDomain("runSettingsPrefUpdateTests") { runSettingsPrefUpdateTests() }
        runDomain("runPerfInstanceTests") { runPerfInstanceTests() }
        runDomain("runMinimapLabelTests") { runMinimapLabelTests() }
        runDomain("runSoundGateSilentTests") { runSoundGateSilentTests() }
        runDomain("runTitleEditorAXWriteTests") { runTitleEditorAXWriteTests() }
        runDomain("runSoundResolveAndCrashStateTests") { runSoundResolveAndCrashStateTests() }
        runDomain("runFindingMakeIdentityTests") { runFindingMakeIdentityTests() }
        runDomain("runFindingMatchedIdentityTests") { runFindingMatchedIdentityTests() }
        runDomain("runStoreDatabaseTests") { runStoreDatabaseTests() }
        runDomain("runTitleEditorCaptureTests") { runTitleEditorCaptureTests() }
        runDomain("runAudioEngineProtocolTests") { runAudioEngineProtocolTests() }
        runDomain("runSoundScreenPrefsResidueTests") { runSoundScreenPrefsResidueTests() }
        runDomain("runReadOnlyTailTests") { runReadOnlyTailTests() }
        runDomain("runSessionActivityWriteTests") { runSessionActivityWriteTests() }
        runDomain("runSettingsFullRenderTests") { runSettingsFullRenderTests() }
        runDomain("runSpaceDisplayLocalTests") { runSpaceDisplayLocalTests() }
        runDomain("runGridSnapshotRowTests") { runGridSnapshotRowTests() }
        runDomain("runBStateSweepTests") { runBStateSweepTests() }
        runDomain("runAXDirectMoveTests") { runAXDirectMoveTests() }
        runDomain("runOverlayWindowE2ETests") { runOverlayWindowE2ETests() }
        // B244：看门狗最后启动——冻结主线程的采样类测试已跑完，零干扰。
        // 2026-11-03：登记为独立域（原先直接调用），逐域覆盖率采集下也只跑一次。
        runDomain("runPerfWatchdogTests") { runPerfWatchdogTests() }
    // MARK: 汇总

    let skippedNote = skipped > 0 ? ", \(skipped) domains skipped" : ""
    print("\nVibeFocusTestRunner: \(passed + failed) checks, \(passed) passed, \(failed) failed\(skippedNote)")
    exit(failed == 0 ? 0 : 1)
    }
}

// E2E 模式必须在任何 store 初始化前切隔离 DB（快照与真机实例互扰，实测教训），
// 并清空上次运行残留，保证每次 E2E 从空快照开始。
// 注意：DB 路径由调用方以 shell 环境变量 VIBEFOCUS_DB_PATH=/tmp/vibefocus-grid-e2e.db
// 注入——进程内 setenv() 不会更新 ProcessInfo.environment（启动时快照），实测无效。
if ProcessInfo.processInfo.environment["VIBEFOCUS_GRID_E2E"] == "1"
    || ProcessInfo.processInfo.environment["VIBEFOCUS_GRID_TARGET_E2E"] == "1"
    || ProcessInfo.processInfo.environment["VIBEFOCUS_SESSION_RESTORE_E2E"] == "1" {
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

// 逐域隔离模式（VIBEFOCUS_RUNNER_DOMAINS）每个进程只跑一个域，没有前序域帮忙
// 初始化 AppKit——DockBadge 的 dockTile、气泡收尾的 activationPolicy 等直接摸
// NSApp 的代码会因隐式解包 nil 崩溃（2026-11-03 逐域采集实测两处）。单进程全量
// 模式本来就由前面的域完成初始化，这里补上不改变任何可见行为（不建窗口/不置前）。
_ = NSApplication.shared

MainActor.assumeIsolated {
    RunnerHarness().runAllTests()
}
