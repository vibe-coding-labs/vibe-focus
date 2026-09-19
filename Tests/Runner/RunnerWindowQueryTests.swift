// Tests/Runner/RunnerWindowQueryTests.swift
// B221 覆盖堆叠·窗口查询守卫域：WindowManager+WindowQuery 的 CG/AX 查询守卫路。
// 全部用幻影 windowID/pid——真实窗口会触发 raise/focus 抢用户焦点，绝不碰。

import AppKit
import ApplicationServices
import Foundation
@testable import VibeFocusKit

extension RunnerHarness {

    func runWindowQueryTests() {
        print("\n=== WindowQuery (B221) ===")
        let wm = WindowManager.shared

        // focusWindowByCGWindowID：幻影 ID 在 CGWindowList 必不命中 → false（不聚焦任何窗）
        check("winQuery: 幻影 ID 聚焦失败", wm.focusWindowByCGWindowID(0xB221) == false)

        // focusedWindow(for:)：幻影 pid 的 AX 应用元素无焦点窗 → nil
        check("winQuery: 幻影 pid 焦点窗 nil", wm.focusedWindow(for: 999_999) == nil)

        // findWindowByPID：windowID nil 直接 nil（守卫）；幻影 pid + 幻影 ID → nil
        check("winQuery: windowID nil 直通 nil", wm.findWindowByPID(99_998, windowID: nil) == nil)
        check("winQuery: 幻影 pid+ID 无 AX 元素", wm.findWindowByPID(999_999, windowID: 0xB221) == nil)
    }
}
