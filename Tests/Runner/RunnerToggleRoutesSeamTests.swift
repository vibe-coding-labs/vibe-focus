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
    /// 逐次消费的 moveFrame 结果队列（非空时优先于 moveResult）
    var moveResults: [Bool] = []
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
    var screensList: [NSScreen] = []
    var mainScreenNil = false
    var nsScreenNil = false
    var focusResult = true
    var identityCalls = 0
    var pipelineArgs: [(windowID: UInt32, ax: AXUIElement?, orig: CGRect?)] = []
    var sourceFrames: [CGRect?] = []
}

extension RunnerHarness {
    func runToggleRoutesSeamTests() {
        guard let screen = NSScreen.screens.first else {
            check("toggleRoutes A0: 无 NSScreen 环境，跳过实屏映射用例", true)
            return
        }
        let state = ToggleRoutesSeamState()
        state.screensList = [screen]
        let fakeAX = AXUIElementCreateSystemWide()
        let secondaryVisible = CGRect(x: 1440, y: 0, width: 1440, height: 900)

        func makeEnv() -> ToggleRoutesEnvironment {
            ToggleRoutesEnvironment(
                screens: { state.screensList },
                frontmostPID: { state.frontmostPID },
                focusedWindow: { _ in fakeAX },
                windowHandle: { _ in state.handle },
                queryWindow: { _ in state.windowInfo },
                querySpaces: { state.spaces },
                nsScreen: { _ in state.nsScreenNil ? nil : screen },
                cgWindowBounds: { _ in state.bounds },
                floatAndSettle: { _, _, _ in state.floatCalls += 1 },
                moveFrame: { windowID, frame, _, stage, source in
                    state.moveCalls.append((windowID, frame, stage))
                    state.sourceFrames.append(source)
                    if !state.moveResults.isEmpty { return state.moveResults.removeFirst() }
                    return state.moveResult
                },
                mainScreen: { state.mainScreenNil ? nil : screen },
                quartzVisibleFrame: { _ in secondaryVisible },
                hasAccessibilityPermission: { state.axTrusted },
                notifyPermission: { state.notifyCalls += 1 },
                captureIdentity: {
                    state.identityCalls += 1
                    return state.identity
                },
                moveToMainPipeline: { identity, ax, orig in
                    state.pipelineCalls += 1
                    state.pipelineArgs.append((identity.windowID, ax, orig))
                    return state.pipelineResult
                },
                focusWindow: { _ in
                    state.focusCalls += 1
                    return state.focusResult
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
            state.moveResults = []
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
            state.screensList = [screen]
            state.mainScreenNil = false
            state.nsScreenNil = false
            state.focusResult = true
            state.identityCalls = 0
            state.pipelineArgs = []
            state.sourceFrames = []
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
        state.moveResults = [false, true]
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

        // A2. 前台 PID 在但 AX 句柄解析不到 → 同样早退
        reset()
        state.handle = nil
        wm.moveStuckWindowToSecondaryScreen(operationID: "ut-stuck-e", triggerSource: "ut", environment: makeEnv())
        check("toggleRoutes A2: 有前台 PID 无窗口句柄 → 早退（零 float 零移动）",
              state.moveCalls.isEmpty && state.floatCalls == 0)

        // B4. 目标屏映射失败且无回退屏 → 副屏缺失早退
        reset()
        state.nsScreenNil = true
        state.screensList = []
        wm.moveStuckWindowToSecondaryScreen(operationID: "ut-stuck-f", triggerSource: "ut", environment: makeEnv())
        check("toggleRoutes B4: 无可映射副屏且无回退屏 → 早退（零 float 零移动）",
              state.moveCalls.isEmpty && state.floatCalls == 0)

        // C3. 回滚也失败 → rollback.failed
        reset()
        state.moveResults = [false, false]
        wm.moveStuckWindowToSecondaryScreen(operationID: "ut-stuck-h", triggerSource: "ut", environment: makeEnv())
        check("toggleRoutes C3: 回滚失败 → move.rollback.failed 仍落快照",
              state.perfMetrics == ["move.rollback.failed"] && state.perfSnapshots == ["rollback"])

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

        // E5. 已知身份/AX/orig 透传管线，跳过身份捕获
        reset()
        let knownOrig = CGRect(x: 10, y: 20, width: 640, height: 480)
        wm.moveToMainScreen(
            operationID: "ut-main-e", knownIdentity: state.identity,
            knownWindowAX: fakeAX, knownOrigFrame: knownOrig, environment: makeEnv())
        check("toggleRoutes E5: knownIdentity/AX/orig 原样透传管线且零身份捕获",
              state.identityCalls == 0 && state.pipelineArgs.count == 1
              && state.pipelineArgs[0].windowID == 8101
              && state.pipelineArgs[0].ax != nil
              && state.pipelineArgs[0].orig == knownOrig)

        // E6. 焦点回补失败不影响管线结果记账
        reset()
        state.focusResult = false
        wm.moveToMainScreen(operationID: "ut-main-f", environment: makeEnv())
        check("toggleRoutes E6: 焦点回补失败仍只尝试一次",
              state.pipelineCalls == 1 && state.focusCalls == 1)

        // F7. 无主屏 → 早退
        reset()
        state.mainScreenNil = true
        wm.maximizeFocusedWindowOnSingleDisplay(operationID: "ut-max-f", environment: makeEnv())
        check("toggleRoutes F7: 无主屏 → 早退（零 float 零移动零记录）",
              state.floatCalls == 0 && state.moveCalls.isEmpty && state.savedRecords.isEmpty)

        // F8. 实时 bounds 读不到但已知 orig 帧 → 照常最大化
        reset()
        state.bounds = nil
        wm.maximizeFocusedWindowOnSingleDisplay(
            operationID: "ut-max-g", knownIdentity: state.identity,
            knownOrigFrame: knownOrig, environment: makeEnv())
        check("toggleRoutes F8: knownOrigFrame 兜底 → 照常 float + 直写 + 落记录",
              state.floatCalls == 1 && state.moveCalls.count == 1
              && state.savedRecords.count == 1 && state.savedRecords[0].origFrame == knownOrig)

        // F9. 窗口无 display → 源屏可视区缺失（直写收到 nil source）
        reset()
        state.windowInfo = YabaiWindowInfo(
            id: 8101, pid: 4242, app: "Terminal", title: "t",
            space: 1, display: nil,
            frame: YabaiWindowInfo.Frame(x: 0, y: 0, w: 900, h: 700),
            isFloatingRaw: false, hasAXReferenceRaw: true)
        wm.maximizeFocusedWindowOnSingleDisplay(operationID: "ut-max-h", environment: makeEnv())
        check("toggleRoutes F9: 源窗无 display → 直写源屏可视区为 nil",
              state.moveCalls.count == 1 && state.sourceFrames.count == 1
              && state.sourceFrames[0] == nil)
        state.windowInfo = YabaiWindowInfo(
            id: 8101, pid: 4242, app: "Terminal", title: "t",
            space: 1, display: 1,
            frame: YabaiWindowInfo.Frame(x: 0, y: 0, w: 900, h: 700),
            isFloatingRaw: false, hasAXReferenceRaw: true)
    }
}
