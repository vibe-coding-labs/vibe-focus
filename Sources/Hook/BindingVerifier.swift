// BindingVerifier.swift
// VibeFocus — 绑定验证逻辑
// 从 SessionWindowRegistry.swift 中提取，职责：验证窗口绑定是否仍然有效

import AppKit
import Foundation

// MARK: - Binding Verification

extension SessionWindowRegistry {

    /// Binding verification decision — extracted for testability.
    enum BindingVerificationResult {
        case valid
        case pidNoLongerExists
        case windowNotFound
        case windowPIDMismatch(expectedPID: Int32, actualPID: Int32)
    }

    /// Pure decision logic for verifyBinding.
    static func decideBindingVerification(
        pidExists: Bool,
        windowEntry: CGWindowEntry?,
        expectedPID: Int32
    ) -> BindingVerificationResult {
        guard pidExists else { return .pidNoLongerExists }
        guard let entry = windowEntry else { return .windowNotFound }
        guard entry.ownerPID == expectedPID else {
            return .windowPIDMismatch(expectedPID: expectedPID, actualPID: entry.ownerPID)
        }
        return .valid
    }

    func verifyBinding(_ state: WindowState) -> Bool {
        // P-INST-38: verifyBinding 耗时（cgWindowListAll + NSRunningApplication；hook 路径 resolveWindowIdentity/handleWindowMoveTrigger 每次调用，归因 hook 验证阻塞）。
        let vbStart = Date()
        let expectedPID = state.pid
        let windowID = state.windowID

        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: state.bundleIdentifier ?? "")
        let pidMatches = runningApps.contains { $0.processIdentifier == expectedPID }
        let pidExists: Bool
        if pidMatches {
            pidExists = true
        } else {
            pidExists = kill(expectedPID, 0) == 0
        }

        let windows = cgWindowListAll()
        let windowEntry = windows.first(where: { $0.windowID == windowID })

        let result = Self.decideBindingVerification(
            pidExists: pidExists,
            windowEntry: windowEntry,
            expectedPID: expectedPID
        )

        defer {
            log("[SessionWindowRegistry] verifyBinding finished", level: .debug, fields: [
                "windowID": String(windowID),
                "expectedPID": String(expectedPID),
                "result": String(describing: result),
                "durationMs": String(elapsedMilliseconds(since: vbStart))
            ])
        }

        switch result {
        case .valid:
            return true
        case .pidNoLongerExists:
            log("[SessionWindowRegistry] verifyBinding failed: PID \(expectedPID) no longer exists", level: .warn, fields: [
                "windowID": String(windowID),
                "bundleIdentifier": state.bundleIdentifier ?? "nil"
            ])
            return false
        case .windowNotFound:
            log("[SessionWindowRegistry] verifyBinding failed: windowID \(windowID) not found in CGWindowList", level: .warn, fields: [
                "windowID": String(windowID),
                "expectedPID": String(expectedPID)
            ])
            return false
        case .windowPIDMismatch(let expected, let actual):
            log("[SessionWindowRegistry] verifyBinding failed: window owner PID mismatch", level: .warn, fields: [
                "windowID": String(windowID),
                "expectedPID": String(expected),
                "actualPID": String(actual)
            ])
            return false
        }
    }
}
