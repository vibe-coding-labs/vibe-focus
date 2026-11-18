import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerLayoutApplySeamTests.swift
// 靶：WindowManager.applyLayoutAction 全分支（LayoutApplyEnvironment 注入）——
// 授权门、焦点窗解析失败、frame 读取失败、原生全屏跳过、源屏解析失败、
// nextDisplay 单屏拒绝、同屏 AX 成功/失败、AX 解析失败、跨屏通道（多屏时）。
// 纪律：零权限探测、零 AX 写入、零窗口移动、零真实提示音。

/// 用例状态盒（闭包共享）
final class LayoutSeamState: @unchecked Sendable {
    var permission = true
    var notified = 0
    var resolution: ToggleWindowResolution!
    var liveFrame: CGRect? = CGRect(x: 100, y: 100, width: 800, height: 600)
    var fullscreen = false
    var displayID: UInt32? = 1
    var screensList: [NSScreen] = []
    var axForIdentity: AXUIElement?
    var applyResult = true
    var appliedFrames: [CGRect] = []
    var beeped = 0
    var records: [String] = []
    var floatWrites: [CGRect] = []
}

extension RunnerHarness {
    func runLayoutApplySeamTests() {
        guard let screen = NSScreen.screens.first else {
            check("layoutSeam A0: 无 NSScreen 环境，跳过", true)
            return
        }
        let state = LayoutSeamState()
        state.screensList = [screen]
        let identity = WindowIdentity(
            windowID: 42, pid: 100, bundleIdentifier: "com.test.app",
            appName: "Test", windowNumber: nil, title: "t")
        let fakeAX = AXUIElementCreateSystemWide()

        func resolution(windowID: UInt32?, ax: AXUIElement?, frame: CGRect?) -> ToggleWindowResolution {
            ToggleWindowResolution(
                windowID: windowID,
                windowAX: ax,
                identity: windowID == nil ? nil : identity,
                windowFrame: frame,
                onMainScreen: nil,
                source: "test",
                branchMs: 0)
        }
        state.resolution = resolution(windowID: 42, ax: fakeAX, frame: CGRect(x: 100, y: 100, width: 800, height: 600))

        let env = LayoutApplyEnvironment(
            hasAccessibilityPermission: { state.permission },
            notifyPermissionRequired: { state.notified += 1 },
            frontmostApplication: { nil },
            mainScreen: { state.displayID == nil ? nil : state.screensList.first },
            resolveFocusedWindow: { _, _ in (state.resolution, ["probe": "seam"]) },
            cgWindowFrame: { _ in state.liveFrame },
            isNativeFullscreen: { _ in state.fullscreen },
            displayContextDisplayID: { _ in state.displayID },
            nsScreenForDisplayID: { _ in state.screensList.first },
            screens: { state.screensList },
            visibleFrame: { _ in CGRect(x: 0, y: 0, width: 1440, height: 900) },
            snapGap: { 8 },
            resolveAX: { _ in state.axForIdentity },
            applyFrame: { frame, _, _ in
                state.appliedFrames.append(frame)
                return state.applyResult
            },
            floatWriteFrame: { _, frame, _ in
                state.floatWrites.append(frame)
                return true
            },
            beep: { state.beeped += 1 },
            record: { state.records.append($0) })

        let wm = WindowManager.shared
        func apply(_ action: LayoutAction = .leftHalf) -> Bool {
            wm.applyLayoutAction(action, triggerSource: "ut", operationID: "ut-op", environment: env)
        }

        // A. 授权门
        state.permission = false
        let denied = apply()
        check("layoutSeam A1: 无授权 → false 且弹权提示被调用", denied == false && state.notified == 1)
        state.permission = true

        // B. 焦点窗解析失败
        state.resolution = resolution(windowID: nil, ax: nil, frame: nil)
        let beepsBefore = state.beeped
        check("layoutSeam B1: 无焦点窗 → false + beep",
              apply() == false && state.beeped == beepsBefore + 1)

        // C. frame 读取失败
        state.resolution = resolution(windowID: 42, ax: nil, frame: nil)
        state.liveFrame = nil
        let beepsBeforeC = state.beeped
        check("layoutSeam C1: 焦点窗与实时 frame 都读不到 → false + beep",
              apply() == false && state.beeped == beepsBeforeC + 1)
        state.liveFrame = CGRect(x: 100, y: 100, width: 800, height: 600)

        // D. 原生全屏跳过
        state.resolution = resolution(windowID: 42, ax: fakeAX, frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        state.fullscreen = true
        let beepsBeforeD = state.beeped
        check("layoutSeam D1: 原生全屏窗 → false + beep（不写 AX）",
              apply() == false && state.beeped == beepsBeforeD + 1 && state.appliedFrames.isEmpty)
        state.fullscreen = false

        // E. 源屏解析失败
        state.displayID = nil
        check("layoutSeam E1: 源屏无法解析 → false（无 beep）",
              apply() == false && state.displayID == nil)
        state.displayID = 1

        // F. nextDisplay 单屏拒绝
        let beepsBeforeF = state.beeped
        check("layoutSeam F1: 单屏 nextDisplay → false + beep",
              apply(.nextDisplay) == false && state.beeped == beepsBeforeF + 1)

        // G. 同屏成功
        state.appliedFrames = []
        state.records = []
        check("layoutSeam G1: 同屏 leftHalf → true 且 AX 写入一次",
              apply() == true && state.appliedFrames.count == 1
              && state.records.last?.contains("ok=true") == true)
        check("layoutSeam G2: 目标 frame 落在可见区内",
              state.appliedFrames.first.map { $0.minX >= 0 && $0.maxX <= 1440 } == true)

        // H. AX 解析失败（windowAX nil + resolveAX nil）
        state.resolution = resolution(windowID: 42, ax: nil, frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        state.axForIdentity = nil
        let beepsBeforeH = state.beeped
        check("layoutSeam H1: AX 解析失败 → false + beep",
              apply() == false && state.beeped == beepsBeforeH + 1)

        // I. AX 写入失败 → 审计 ok=false + beep
        state.resolution = resolution(windowID: 42, ax: fakeAX, frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        state.applyResult = false
        state.records = []
        let beepsBeforeI = state.beeped
        check("layoutSeam I1: AX 写入失败 → false + 审计记账 + beep",
              apply() == false && state.beeped == beepsBeforeI + 1
              && state.records.last?.contains("ok=false") == true)
        state.applyResult = true

        // J. 跨屏（仅多屏环境）：走 float 直写通道
        if NSScreen.screens.count > 1 {
            state.displayID = 1
            state.screensList = [NSScreen.screens[0], NSScreen.screens[1]]
            state.floatWrites = []
            state.appliedFrames = []
            check("layoutSeam J1: 跨屏 nextDisplay → float 直写通道（不走同屏 AX）",
                  apply(.nextDisplay) == true && state.floatWrites.count == 1
                  && state.appliedFrames.isEmpty)
        } else {
            check("layoutSeam J1: 单屏环境，跨屏通道用例跳过", true)
        }

        // 生产入口（environment=nil）不做调用：真机前台窗会被实摆，交给 E2E 通道。
    }
}
