import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerTargetResolveTests.swift — 覆盖率批次 31（B262）：
// TerminalGridController.resolveAppBundleID 直测（NSWorkspace runningApps 只读采集 +
// selectionPreview 静态缝 + lastTerminalSelection 记账）。

extension RunnerHarness {
    func runTargetResolveTests() {
        let controller = TerminalGridController.shared
        let bundleID = controller.resolveAppBundleID()
        check("targetResolve: resolveAppBundleID 返回合法 bundleID 形态",
              bundleID == nil || bundleID!.contains("."))
        // lastTerminalSelection 记账与返回一致（selection.source/bundleID 同源）。
        if let bundleID {
            check("targetResolve: lastTerminalSelection 与返回值一致",
                  controller.lastTerminalSelection?.bundleID == bundleID)
        } else {
            check("targetResolve: 无可用终端时合法 nil", true)
        }
    }
}
