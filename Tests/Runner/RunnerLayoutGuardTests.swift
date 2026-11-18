// Tests/Runner/RunnerLayoutGuardTests.swift — 覆盖率批次 35：Rectangle 摆位执行层
// （WindowManager+Layout.swift）的无目标/无授权臂。
//
// 真摆位（apply / float 脱管 / 跨屏直写）必须有真实焦点窗，归真机 E2E 口径；
// 本域只覆盖「不会动任何真实窗口」的入口与守卫：
//   - placeWindow（grid 编排原语）幽灵窗 → FloatSettle 空转 + yabai 直写守卫 false；
//   - 无辅助功能授权：全部 LayoutAction + AX 直写 + yabai 入口守卫；
//   - 有授权但前台无窗（CI 常态）：applyLayoutAction 走到「无焦点窗」降级，
//     绝不摆位。前台存在他属窗时跳过（防在用户真机上误移窗口）。

import AppKit
import Foundation

@testable import VibeFocusKit

extension RunnerHarness {
    func runLayoutGuardTests() {
        print("\n=== LayoutGuard ===")
        let wm = WindowManager.shared
        let ghostID: UInt32 = 0xFFFF_FFF0
        let ghostFrame = CGRect(x: 0, y: 0, width: 320, height: 200)
        let gestureFrames = [ghostFrame, CGRect(x: 10, y: 10, width: 400, height: 300)]

        // --- A. placeWindow 原语：幽灵窗零真实窗操作（FloatSettle 空转 + 直写守卫） ---
        var anyPlaced = false
        for (i, frame) in gestureFrames.enumerated() {
            let ok = wm.placeWindow(windowID: ghostID, frame: frame, operationID: "layout-guard-place-\(i)")
            anyPlaced = anyPlaced || ok
        }
        check("layoutGuard: placeWindow 幽灵窗不会成功摆位", anyPlaced == false)

        // --- B. 无授权：全动作 + 两条直写入口守卫 ---
        if !wm.hasAccessibilityPermission() {
            for action in LayoutAction.allCases {
                let ok = wm.applyLayoutAction(
                    action,
                    triggerSource: "runner-guard",
                    operationID: "layout-guard-\(action.rawValue)"
                )
                check("layoutGuard: \(action.rawValue) 无授权返回 false", ok == false)
            }
            let axOK = wm.moveWindowToFrameViaAX(
                windowID: ghostID,
                frame: ghostFrame,
                op: "layout-guard-ax",
                stage: "guard",
                sourceVisibleFrame: nil
            )
            check("layoutGuard: AX 直写幽灵窗口守卫返回 false", axOK == false)
            let yabaiOK = wm.moveWindowToFrameViaYabai(
                windowID: ghostID + 1,
                frame: ghostFrame,
                op: "layout-guard-yabai",
                stage: "guard",
                sourceVisibleFrame: nil
            )
            check("layoutGuard: yabai 入口幽灵窗口分流后守卫返回 false", yabaiOK == false)
            return
        }

        // --- C. 有授权（CI runner 常态）：前台无窗时 applyLayoutAction 降级，不摆位 ---
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let frontCandidateCount = frontPID.map {
            ToggleFocusBranching.cgListFocusCandidates(
                snapshot: cgWindowListAll(), ownerPID: $0
            ).count
        } ?? 0
        guard frontCandidateCount == 0 else {
            // 真机上前台有他属窗：实摆会移动用户窗口，跳过（采信 E2E 口径）
            check("layoutGuard: 前台有他属窗，跳过 applyLayoutAction 实摆（防真机误移）", true)
            return
        }
        // operationID 传 nil 走 makeOperationID 分支；显式传值走另一分支——两种都要过
        let nilOp = wm.applyLayoutAction(.leftHalf, triggerSource: "runner-guard")
        check("layoutGuard: 无焦点窗 → leftHalf 降级 false（nil op）", nilOp == false)
        let explicitOp = wm.applyLayoutAction(
            .nextDisplay,
            triggerSource: "runner-guard",
            operationID: "layout-guard-next-display"
        )
        check("layoutGuard: 无焦点窗 → nextDisplay 降级 false（显式 op）", explicitOp == false)
    }
}
