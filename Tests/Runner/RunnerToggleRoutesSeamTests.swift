import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerToggleRoutesSeamTests.swift
// 靶：toggle 路由三动作全链（ToggleRoutesEnvironment 注入）——
// moveStuckWindowToSecondaryScreen（焦点窗解析/目标屏选择/尺寸保持/回滚）、
// moveToMainScreen（AX 门/身份解析/管线/焦点）、
// maximizeFocusedWindowOnSingleDisplay（orig 快照门/主屏门/记录落账/焦点）。
// 全程零真实窗口移动、零 AX 写入、零文件快照。

final class ToggleRoutesSeamState: @unchecked Sendable {
    var frontmostPID: pid_t? = 4242
    var handle: UInt32? = 8101
    var windowInfo: YabaiWindowInfo? = YabaiWindowInfo(
        id: 8101, pid: 4242, app: "Terminal", title: "t",
        space: 1, display: 1,
        frame: YabaiWindowInfo.Frame(x: 0, y: 0, w: 900, h: 700),
        isFloatingRaw: false, hasAXReferenceRaw: true)
    var spaces: [YabaiSpaceInfo] = [
        YabaiSpaceInfo(id: 1, index: 1, display: 1, isVisible: true),
        YabaiSpaceInfo(id: 2, index: 2, display: 2, isVisible: true),
    ]
    var bounds: CGRect? = CGRect(x: 0, y: 0, width: 900, height: 700)
    var floatCalls = 0
    var moveCalls: [(windowID: UInt32, frame: CGRect, stage: String)] = []
    var moveResult = true
    var axTrusted = true
    var notifyCalls = 0
    var identity: WindowIdentity? = WindowIdentity(
        windowID: 8101, pid: 4242, bundleIdentifier: "com.apple.Terminal",
        appName: "Terminal", windowNumber: 8101, title: "t")
    var pipelineCalls = 0
    var pipelineResult = true
    var focusCalls = 0
    var savedRecords: [(windowID: UInt32, origFrame: CGRect, targetFrame: CGRect, targetDisplayIndex: Int?)] = []
    var perfMetrics: [String] = []
    var perfSnapshots: [String] = []
}

extension RunnerHarness {
    func runToggleRoutesSeamTests() {
        guard let screen = NSScreen.screens.first else {
            check("toggleRoutes A0: 无 NSScreen 环境，跳过实屏映射用例", true)
            return
        }
        let state = ToggleRoutesSeamState()
        let fakeAX = AXUIElementCreateSystemWide()
        let secondaryVisible = CGRect(x: 1440, y: 0, width: 1440, height: 900)

        func makeEnv() -> ToggleRoutesEnvironment {
            ToggleRoutesEnvironment(
                screens: { [screen] },
                frontmostPID: { state.frontmostPID },
                focusedWindow: { _ in fakeAX },
                windowHandle: { _ in state.handle },
                queryWindow: { _ in state.windowInfo },
                querySpaces: { state.spaces },
                nsScreen: { _ in screen },
                cgWindowBounds: { _ in state.bounds },
                floatAndSettle: { _, _, _ in state.floatCalls += 1 },
                moveFrame: { windowID, frame, _, stage, _ in
                    state.moveCalls.append((windowID, frame, stage))
                    return state.moveResult
                },
                mainScreen: { screen },
                quartzVisibleFrame: { _ in secondaryVisible },
                hasAccessibilityPermission: { state.axTrusted },
                notifyPermission: { state.notifyCalls += 1 },
                captureIdentity: { state.identity },
                moveToMainPipeline: { _, _, _ in
                    state.pipelineCalls += 1
                    return state.pipelineResult
                },
                focusWindow: { _ in
                    state.focusCalls += 1
                    return true
                },
                captureSpaceContext: { _, _ in
                    SpaceContext(
                        sourceSpaceIndex: nil, targetSpaceIndex: nil,
                        sourceDisplayIndex: nil, sourceDisplaySpaceIndex: nil)
                },
                saveSingleDisplayRecord: { _, windowID, origFrame, _, targetFrame, displayIndex in
                    state.savedRecords.append((windowID, origFrame, targetFrame, displayIndex))
                },
                displayIDForScreen: { _ in 7 },
                displayIndexOfDisplayID: { _ in 7 },
                recordPerf: { metric, _ in state.perfMetrics.append(metric) },
                writePerfSnapshot: { reason in state.perfSnapshots.append(reason) }
            )
        }
        let wm = WindowManager.shared
        func reset() {
            state.frontmostPID = 4242
            state.handle = 8101
            state.bounds = CGRect(x: 0, y: 0, width: 900, height: 700)
            state.floatCalls = 0
            state.moveCalls = []
            state.moveResult = true
            state.axTrusted = true
            state.notifyCalls = 0
            state.identity = WindowIdentity(
                windowID: 8101, pid: 4242, bundleIdentifier: "com.apple.Terminal",
                appName: "Terminal", windowNumber: 8101, title: "t")
            state.pipelineCalls = 0
            state.pipelineResult = true
            state.focusCalls = 0
            state.savedRecords = []
            state.perfMetrics = []
            state.perfSnapshots = []
        }

        // ===== moveStuckWindowToSecondaryScreen =====
        reset()
        state.frontmostPID = nil
        state.handle = nil
        wm.moveStuckWindowToSecondaryScreen(operationID: "ut-stuck-a", triggerSource: "ut", environment: makeEnv())
        check("toggleRoutes A1: 无焦点窗可解析 → 早退（零移动、零 float）",
              state.moveCalls.isEmpty && state.floatCalls == 0)

        reset()
        wm.moveStuckWindowToSecondaryScreen(operationID: "ut-stuck-b", triggerSource: "ut", environment: makeEnv())
        check("toggleRoutes B1: 解堵走 float + frame 直写",
              state.floatCalls == 1 && state.moveCalls.count == 1
              && state.moveCalls[0].stage == "move_to_secondary_stuck")
        check("toggleRoutes B2: 目标帧保持当前尺寸并夹紧到副屏可视区",
              state.moveCalls[0].frame.size == CGSize(width: 900, height: 700)
              && secondaryVisible.contains(state.moveCalls[0].frame))
        check("toggleRoutes B3: 成功移动不触发回滚", state.perfMetrics.isEmpty && state.perfSnapshots.isEmpty)

        reset()
        state.moveResult = false
        wm.moveStuckWindowToSecondaryScreen(operationID: "ut-stuck-c", triggerSource: "ut", environment: makeEnv())
        check("toggleRoutes C1: 移动失败 → 回滚原帧（第二次直写）",
              state.moveCalls.count == 2 && state.moveCalls[1].stage == "move_to_secondary_rollback")
        check("toggleRoutes C2: 回滚结果落计数与快照",
              state.perfMetrics.contains("move.rollback.ok") && state.perfSnapshots == ["rollback"])

        // 已知 windowID 跳过前台解析
        reset()
        state.frontmostPID = nil
        wm.moveStuckWindowToSecondaryScreen(
            operationID: "ut-stuck-d", triggerSource: "ut", windowID: 8101, environment: makeEnv())
        check("toggleRoutes D1: 传入 knownWindowID → 不经前台解析直接移动",
              state.moveCalls.count == 1)

        // ===== moveToMainScreen =====
        reset()
        state.axTrusted = false
        wm.moveToMainScreen(operationID: "ut-main-a", environment: makeEnv())
        check("toggleRoutes E1: AX 未授权 → 提示后早退（零管线）",
              state.notifyCalls == 1 && state.pipelineCalls == 0)

        reset()
        state.identity = nil
        wm.moveToMainScreen(operationID: "ut-main-b", environment: makeEnv())
        check("toggleRoutes E2: 身份缺失 → 早退（零管线）",
              state.pipelineCalls == 0 && state.notifyCalls == 0)

        reset()
        wm.moveToMainScreen(operationID: "ut-main-c", environment: makeEnv())
        check("toggleRoutes E3: 管线成功 → 焦点回补",
              state.pipelineCalls == 1 && state.focusCalls == 1)

        reset()
        state.pipelineResult = false
        wm.moveToMainScreen(operationID: "ut-main-d", environment: makeEnv())
        check("toggleRoutes E4: 管线失败 → 不做焦点回补",
              state.pipelineCalls == 1 && state.focusCalls == 0)

        // ===== maximizeFocusedWindowOnSingleDisplay =====
        reset()
        state.axTrusted = false
        wm.maximizeFocusedWindowOnSingleDisplay(operationID: "ut-max-a", environment: makeEnv())
        check("toggleRoutes F1: 单屏 AX 未授权 → 提示后早退",
              state.notifyCalls == 1 && state.moveCalls.isEmpty)

        reset()
        state.identity = nil
        wm.maximizeFocusedWindowOnSingleDisplay(operationID: "ut-max-b", environment: makeEnv())
        check("toggleRoutes F2: 单屏身份缺失 → 早退（零移动）", state.moveCalls.isEmpty)

        reset()
        state.bounds = nil
        wm.maximizeFocusedWindowOnSingleDisplay(operationID: "ut-max-c", environment: makeEnv())
        check("toggleRoutes F3: 无 orig 快照 → 拒绝最大化（零移动）", state.moveCalls.isEmpty)

        reset()
        wm.maximizeFocusedWindowOnSingleDisplay(operationID: "ut-max-d", environment: makeEnv())
        check("toggleRoutes F4: 单屏最大化 → float + 直写主屏可视区",
              state.floatCalls == 1 && state.moveCalls.count == 1
              && state.moveCalls[0].frame == secondaryVisible)
        check("toggleRoutes F5: 成功 → 落单屏记录（含目标 display 索引）并回补焦点",
              state.savedRecords.count == 1 && state.savedRecords[0].targetDisplayIndex == 7
              && state.focusCalls == 1)

        reset()
        state.moveResult = false
        wm.maximizeFocusedWindowOnSingleDisplay(operationID: "ut-max-e", environment: makeEnv())
        check("toggleRoutes F6: 直写失败 → 不落记录、不回补焦点（recordKept）",
              state.savedRecords.isEmpty && state.focusCalls == 0)
    }
}
