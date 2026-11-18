// Tests/Runner/RunnerPostMoveRecordTests.swift — 覆盖率批次 33：move_to_main 收尾落记录。
// saveToggleRecordForMainMove 是 moveWindowToMainScreen 的收尾职责之一（另一职责
// verifyAndCorrectPostMoveSize 需要真实 AX 窗与真实移动，留待真机 E2E）：本域用
// 幽灵 windowID + 注入身份的 SpaceContext 直测记录构造与落库，覆盖：
//   ① 主屏外 origFrame → 记录正常落库（orig/target frame、来源 space/display、身份）；
//   ② origFrame 落在主屏 → 拒收门拦截（ToggleEngine.shouldRejectSave，数据异常防护）；
//   ③ 单屏机（singleDisplay=true）→ 主屏内 origFrame 也放行（同屏最大化常态）。
// 测毕立刻 clear，不留残余记录。（ToggleEngine.shared 是生产 store——Runner 现有多域
// 同样如此，clear 后零残留。）

import AppKit
import Foundation

@testable import VibeFocusKit

extension RunnerHarness {
    func runPostMoveRecordTests() {
        print("\n=== PostMoveRecord ===")
        let wm = WindowManager.shared
        let windowID: UInt32 = 987_654
        defer { ToggleEngine.shared.clear(windowID: windowID) }

        let identity = WindowIdentity(
            windowID: windowID,
            pid: getpid(),
            bundleIdentifier: "com.vibefocus.runner",
            appName: "VibeFocusTestRunner",
            windowNumber: Int(windowID),
            title: "postmove-record"
        )
        // 主屏外坐标（Cocoa 全域负方向），保证不被 shouldRejectSave 拒收
        let origFrame = CGRect(x: -5000, y: -5000, width: 900, height: 700)
        let targetFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let context = SpaceContext(
            sourceSpaceIndex: .yabai(3),
            targetSpaceIndex: .yabai(1),
            sourceDisplayIndex: .yabai(2),
            sourceDisplaySpaceIndex: 4
        )

        // --- ① 正常落库 ---
        let saveMs = wm.saveToggleRecordForMainMove(
            identity: identity,
            windowID: windowID,
            origFrame: origFrame,
            spaceContext: context,
            targetFrame: targetFrame,
            targetDisplayIndex: 1,
            reason: .manualHotkey,
            sessionID: "ut-postmove-record",
            op: "ut-postmove-record",
            singleDisplay: false
        )
        check("postMoveRecord: 保存耗时非负", saveMs >= 0)

        let record = ToggleEngine.shared.load(windowID: windowID)
        check("postMoveRecord: 记录落库", record != nil)
        check("postMoveRecord: orig/target frame 按入参落库",
              record?.origFrame == origFrame && record?.targetFrame == targetFrame)
        check("postMoveRecord: 来源 space/display 归属正确",
              record?.sourceSpace == 3
              && record?.sourceYabaiDisp == 2
              && record?.sourceDispSpace == 4)
        check("postMoveRecord: 身份字段透传",
              record?.pid == getpid() && record?.bundleIdentifier == "com.vibefocus.runner")

        // --- ② 主屏内 origFrame（非单屏）→ 拒收门拦截，记录不落库 ---
        ToggleEngine.shared.clear(windowID: windowID)
        guard let mainFrame = CoordinateKit.primaryScreen?.frame ?? NSScreen.screens.first?.frame else {
            check("postMoveRecord: 无 NSScreen 环境，跳过错屏/单屏断言", true)
            return
        }
        let onMainOrig = CGRect(
            x: mainFrame.midX - 100, y: mainFrame.midY - 100, width: 200, height: 200)
        _ = wm.saveToggleRecordForMainMove(
            identity: identity,
            windowID: windowID,
            origFrame: onMainOrig,
            spaceContext: context,
            targetFrame: targetFrame,
            targetDisplayIndex: 1,
            reason: .userPromptSubmit,
            sessionID: nil,
            op: "ut-postmove-reject",
            singleDisplay: false
        )
        check("postMoveRecord: 主屏内 origFrame → 拒收门拦截零落库",
              ToggleEngine.shared.load(windowID: windowID) == nil)

        // --- ③ 单屏机：主屏内 origFrame 放行（同屏最大化常态） ---
        let singleMs = wm.saveToggleRecordForMainMove(
            identity: identity,
            windowID: windowID,
            origFrame: onMainOrig,
            spaceContext: context,
            targetFrame: targetFrame,
            targetDisplayIndex: nil,
            reason: .agentCommand,
            sessionID: nil,
            op: "ut-postmove-single",
            singleDisplay: true
        )
        check("postMoveRecord: 单屏/空 session 分支保存成功", singleMs >= 0)
        check("postMoveRecord: 单屏分支记录落库且帧一致",
              ToggleEngine.shared.load(windowID: windowID)?.origFrame == onMainOrig)
    }
}
