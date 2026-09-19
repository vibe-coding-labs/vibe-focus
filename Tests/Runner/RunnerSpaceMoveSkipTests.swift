import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerSpaceMoveSkipTests.swift — 覆盖率批次 25（B256）：
// setWindowFloat/focusWindow 的 skip/disabled 分支直测（knownWindowInfo 注入，
// 零 yabai toggle/focus fork——只有 .toggled 分支会真实改窗，本批不触）。

extension RunnerHarness {
    func runSpaceMoveSkipTests() {
        let controller = SpaceController.shared
        // isEnabled 两种状态均合法：本机 yabai 可用时 shared 的后台 refresh 会置
        // true（focusWindow 走 no_window false），不可用时走 disabled false——
        // 两种状态下 skip/false 断言均成立，不做前提假设。

        // setWindowFloat：unmanaged（has-ax-reference=false）→ skip unmanaged。
        let unmanaged = YabaiWindowInfo(
            id: 1, pid: 100, app: "Terminal", title: "t", space: 1, display: 1,
            frame: YabaiWindowInfo.Frame(x: 0, y: 0, w: 800, h: 600),
            isFloatingRaw: false, hasAXReferenceRaw: false,
            isMinimizedRaw: false, hasFocusRaw: false)
        check("spaceMove: setWindowFloat unmanaged 窗 → skippedNoOp（零 fork）",
              controller.setWindowFloat(1, knownWindowInfo: unmanaged) == .skippedNoOp)

        // setWindowFloat：query nil（幽灵窗口）→ skip query_nil。
        check("spaceMove: setWindowFloat 幽灵窗 → skippedNoOp（query_nil）",
              controller.setWindowFloat(999_999) == .skippedNoOp)

        // focusWindow：disabled 守卫在前 → false（不做任何聚焦）。
        check("spaceMove: focusWindow disabled → false",
              controller.focusWindow(1) == false)
        check("spaceMove: focusWindow 幽灵窗 disabled → false",
              controller.focusWindow(999_999) == false)
    }
}
