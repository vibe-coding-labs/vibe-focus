// Tests/Runner/RunnerLayoutGuardTests.swift — 覆盖率批次 33：无授权环境的守卫路径。
// CI/无辅助功能授权时（AXIsProcessTrusted == false），Layout 摆位与 AX 直写通道的
// 入口守卫必须「快速失败不半写」：
//   - applyLayoutAction：全部 11 个 LayoutAction 在无授权时都返回 false（不碰窗口）；
//   - moveWindowToFrameViaAX：CGWindowList 查无此窗（幽灵 id）时返回 false，不进 AX 写。
// 有授权的真机上本域整域跳过——摆位动作会真的移动用户前台窗口，测试绝不能在
// 真机上执行（断言只在无授权世界成立）。授权缺失时 notifyAccessibilityPermissionRequired
// 会 beep 一次并尝试打开系统设置（产品真实行为，CI 无桌面会话时 open 空转）。

import AppKit
import Foundation

@testable import VibeFocusKit

extension RunnerHarness {
    func runLayoutGuardTests() {
        print("\n=== LayoutGuard ===")
        let wm = WindowManager.shared
        guard !wm.hasAccessibilityPermission() else {
            // 有授权：绝不能调用 applyLayoutAction（会真移动用户前台窗口）
            check("layoutGuard: 有授权环境跳过摆位（防真机误移窗口）", true)
            return
        }

        // --- A. 全部布局动作在无授权时快速失败且不崩溃 ---
        for action in LayoutAction.allCases {
            let ok = wm.applyLayoutAction(action, triggerSource: "runner-guard", operationID: "layout-guard-\(action.rawValue)")
            check("layoutGuard: \(action.rawValue) 无授权返回 false", ok == false)
        }

        // --- B. AX 直写通道：幽灵窗口不在 CGWindowList → 守卫失败，不发起 AX 写 ---
        let ghostOK = wm.moveWindowToFrameViaAX(
            windowID: 0xFFFF_FFF0,
            frame: CGRect(x: 0, y: 0, width: 320, height: 200),
            op: "layout-guard-ax",
            stage: "guard",
            sourceVisibleFrame: nil
        )
        check("layoutGuard: AX 直写幽灵窗口守卫返回 false", ghostOK == false)

        // --- C. yabai 通道入口：幽灵窗口 → queryWindow nil → AX 直写分流 → 同上守卫 ---
        let viaYabaiOK = wm.moveWindowToFrameViaYabai(
            windowID: 0xFFFF_FFF1,
            frame: CGRect(x: 0, y: 0, width: 320, height: 200),
            op: "layout-guard-yabai",
            stage: "guard",
            sourceVisibleFrame: nil
        )
        check("layoutGuard: yabai 入口幽灵窗口分流后守卫返回 false", viaYabaiOK == false)
    }
}
