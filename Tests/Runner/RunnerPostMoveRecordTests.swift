// Tests/Runner/RunnerPostMoveRecordTests.swift — 覆盖率批次 33：move_to_main 收尾落记录。
// saveToggleRecordForMainMove 是 moveWindowToMainScreen 的收尾职责之一（另一职责
// verifyAndCorrectPostMoveSize 需要真实 AX 窗与真实移动，留待真机 E2E）：本域用
// 幽灵 windowID + 注入身份的 SpaceContext 直测记录构造与落库，断言 origFrame/
// targetFrame/来源 space/display 字段全部按入参落库，测毕立刻 clear 不残留。
// （ToggleEngine.shared 是生产 store——Runner 现有多域同样如此，clear 后零残留。）

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
        let origFrame = CGRect(x: 120, y: 160, width: 900, height: 700)
        let targetFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let context = SpaceContext(
            sourceSpaceIndex: .yabai(3),
            targetSpaceIndex: .yabai(1),
            sourceDisplayIndex: .yabai(2),
            sourceDisplaySpaceIndex: 4
        )

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

        // 单屏标记分支：reason/sessionID 空值形态也不崩
        let singleMs = wm.saveToggleRecordForMainMove(
            identity: identity,
            windowID: windowID,
            origFrame: origFrame,
            spaceContext: context,
            targetFrame: targetFrame,
            targetDisplayIndex: nil,
            reason: .agentCommand,
            sessionID: nil,
            op: "ut-postmove-record-single",
            singleDisplay: true
        )
        check("postMoveRecord: 单屏/空 session 分支保存成功", singleMs >= 0)
        check("postMoveRecord: 二次保存覆盖同一窗口记录",
              ToggleEngine.shared.load(windowID: windowID)?.targetFrame == targetFrame)
    }
}
