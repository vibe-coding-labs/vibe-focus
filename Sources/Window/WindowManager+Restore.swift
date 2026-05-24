import AppKit
import Foundation

@MainActor
extension WindowManager {

    func restore(operationID: String? = nil, triggerSource: String = "unknown") {
        let op = operationID ?? makeOperationID(prefix: "restore")
        let startedAt = Date()
        updateCrashSnapshotFromRuntime()
        logRuntimeStateSnapshot(context: "restore_start")

        // 1. 前置检查：accessibility 权限 + 焦点窗口识别
        guard hasAccessibilityPermission() else {
            log(
                "[WindowManager] restore fallback: accessibility denied",
                level: .warn,
                fields: ["op": op]
            )
            CrashContextRecorder.shared.record("restore_ax_denied op=\(op)")
            logDiagnostics("ax_trusted_false_restore")
            restoreViaSystemEvents()
            return
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let focusedWindow = focusedWindow(for: frontApp.processIdentifier),
              let currentWindowID = windowHandle(for: focusedWindow) else {
            log(
                "[WindowManager] restore failed: cannot identify focused window",
                level: .error,
                fields: ["op": op]
            )
            return
        }

        let focusedOnMain = isWindowOnMainScreen(windowID: currentWindowID)
        log(
            "[WindowManager] restore started",
            fields: [
                "op": op,
                "source": triggerSource,
                "windowID": String(currentWindowID),
                "focusedOnMain": String(focusedOnMain)
            ]
        )

        guard focusedOnMain else {
            log(
                "[WindowManager] restore skipped: focused window not on main screen",
                level: .warn,
                fields: ["op": op, "windowID": String(currentWindowID)]
            )
            return
        }

        // 2. 委托 ToggleEngine 执行 restore（唯一执行入口）
        // ToggleEngine 内部处理：load record → validate → space switch → apply frame
        log("[WindowManager+Restore] delegating to ToggleEngine.restore", level: .debug, fields: [
            "op": op,
            "windowID": String(currentWindowID),
            "triggerSource": triggerSource
        ])
        let engine = ToggleEngine.shared
        let restoreSucceeded = engine.restore(
            windowID: currentWindowID,
            fallbackPID: frontApp.processIdentifier,
            triggerSource: triggerSource,
            traceID: op
        )

        guard restoreSucceeded else {
            log("[WindowManager] restore failed: ToggleEngine.restore returned false", level: .error, fields: [
                "op": op,
                "windowID": String(currentWindowID)
            ])
            CrashContextRecorder.shared.record("restore_failed_engine op=\(op)")
            return
        }

        // 3. ToggleEngine.restore() 已自动清除 toggle record，无需手动 clear

        // 4. 焦点跟随（仅 carbon_hotkey 触发）
        if triggerSource == "carbon_hotkey" {
            if let postApplySpace = spaceController.windowSpaceIndex(windowID: currentWindowID)?.yabaiIndex,
               let currentSpace = spaceController.currentSpaceIndex(),
               postApplySpace != currentSpace {
                log("[WindowManager] restore: following window to Space \(postApplySpace)", fields: [
                    "op": op, "windowID": String(currentWindowID), "currentSpace": String(currentSpace)
                ])
                _ = spaceController.focusWindow(currentWindowID, operationID: op)
            }
        }

        let finalDurationMs = elapsedMilliseconds(since: startedAt)
        log(
            "[WindowManager] restore finished",
            fields: [
                "op": op,
                "outcome": "restored",
                "durationMs": String(finalDurationMs)
            ]
        )
        AuditLogger.shared.record(
            eventType: "restore_success",
            windowID: currentWindowID,
            pid: frontApp.processIdentifier,
            details: [
                "durationMs": String(finalDurationMs)
            ]
        )
        CrashContextRecorder.shared.record("restore_success op=\(op) outcome=restored durationMs=\(finalDurationMs)")
    }
}
