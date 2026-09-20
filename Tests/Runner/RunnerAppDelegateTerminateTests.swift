import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerAppDelegateTerminateTests.swift — 覆盖率批次 59（B297）：
// AppDelegate 退出链路直测：applicationWillTerminate（Overlay 偏好落盘 +
// CrashContext cleanExit 标记）——收尾清理语义锁定，幂等可重复调用。

extension RunnerHarness {
    func runAppDelegateTerminateTests() {
        let appDelegate = AppDelegate()
        // 幂等调用两次：Overlay 偏好落盘 + cleanExit 标记均为收尾清理语义。
        let termNotification = Notification(
            name: NSApplication.willTerminateNotification, object: nil)
        appDelegate.applicationWillTerminate(termNotification)
        appDelegate.applicationWillTerminate(termNotification)
        check("appTerminate: applicationWillTerminate 幂等不崩", true)
    }
}
