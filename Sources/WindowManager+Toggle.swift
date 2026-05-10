import AppKit
import Foundation

@MainActor
extension WindowManager {

    func toggle(operationID: String? = nil, triggerSource: String = "unknown") {
        let op = operationID ?? makeOperationID(prefix: "toggle")
        let startedAt = Date()
        let frontBefore = frontmostAppDescriptor()
        updateCrashSnapshotFromRuntime()
        logRuntimeStateSnapshot(context: "toggle_start")

        // 采集当前窗口上下文
        var toggleContext: [String: String] = [
            "op": op,
            "source": triggerSource,
            "savedStates": String(savedWindowStates.count),
            "frontBefore": frontBefore
        ]
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           let focusedWin = focusedWindow(for: frontApp.processIdentifier) {
            let winTitle = title(of: focusedWin) ?? ""
            let winFrame = frame(of: focusedWin)
            let winID = windowHandle(for: focusedWin)
            toggleContext["windowID"] = String(describing: winID)
            toggleContext["windowTitle"] = truncateForLog(winTitle, limit: 60)
            toggleContext["windowFrame"] = String(describing: winFrame)
            // 判断窗口在哪个屏幕上
            if let winFrame,
               let mainScreen = getMainScreen() {
                let windowCenter = CGPoint(x: winFrame.midX, y: winFrame.midY)
                let onMainScreen = mainScreen.frame.contains(windowCenter)
                toggleContext["onMainScreen"] = String(onMainScreen)
            }
        }
        log(
            "[WindowManager] toggle started",
            fields: toggleContext
        )

        let shouldRestore = shouldRestoreCurrentWindow()
        log(
            "[WindowManager] toggle shouldRestoreCurrentWindow returned",
            level: .debug,
            fields: [
                "op": op,
                "shouldRestore": String(shouldRestore)
            ]
        )
        let mode = shouldRestore ? "restore" : "move_to_main"

        // 采集 toggle record 状态用于决策日志
        var decisionFields: [String: String] = [
            "op": op,
            "source": triggerSource,
            "mode": mode,
            "windowFrame": toggleContext["windowFrame"] ?? "nil",
            "onMainScreen": toggleContext["onMainScreen"] ?? "nil",
            "windowID": toggleContext["windowID"] ?? "nil"
        ]
        if let winIDStr = toggleContext["windowID"], let winID = UInt32(winIDStr) {
            if let record = ToggleEngine.shared.load(windowID: winID) {
                decisionFields["toggleRecordExists"] = "true"
                decisionFields["toggleRecordOrigFrame"] = "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y)) \(Int(record.origFrame.size.width))x\(Int(record.origFrame.size.height))"
                decisionFields["toggleRecordSourceSpace"] = String(record.sourceSpace)
                if let mainScreen = getMainScreen() {
                    decisionFields["toggleRecordValid"] = String(record.isValid(mainScreenFrame: mainScreen.frame))
                }
            } else {
                decisionFields["toggleRecordExists"] = "false"
            }
        }
        log(
            "[WindowManager] toggle decision",
            fields: decisionFields
        )

        if shouldRestore {
            log(
                "[WindowManager] toggle branching to restore",
                level: .debug,
                fields: ["op": op]
            )
            restore(operationID: op, triggerSource: triggerSource)
        } else {
            log(
                "[WindowManager] toggle branching to moveToMainScreen",
                level: .debug,
                fields: ["op": op]
            )
            moveToMainScreen(operationID: op, triggerSource: triggerSource)
        }

        log(
            "[WindowManager] toggle branch completed, checking frontmost app",
            level: .debug,
            fields: ["op": op]
        )
        let frontAfter = frontmostAppDescriptor()
        let durationMs = logOperationDuration(
            "[WindowManager] toggle finished",
            startedAt: startedAt,
            operationID: op,
            warnThresholdMs: 650,
            fields: [
                "source": triggerSource,
                "mode": mode,
                "frontBefore": frontBefore,
                "frontAfter": frontAfter
            ]
        )
        if frontBefore != frontAfter {
            log(
                "[WindowManager] frontmost app changed during toggle",
                level: .warn,
                fields: [
                    "op": op,
                    "source": triggerSource,
                    "mode": mode,
                    "frontBefore": frontBefore,
                    "frontAfter": frontAfter
                ]
            )
        }
        log(
            "[WindowManager] toggle checking slow threshold",
            level: .debug,
            fields: [
                "op": op,
                "durationMs": String(durationMs),
                "threshold": "650"
            ]
        )
        if durationMs >= 650 {
            CrashContextRecorder.shared.record("toggle_slow op=\(op) durationMs=\(durationMs) mode=\(mode)")
        }
    }

    func moveToMainScreen(operationID: String? = nil, triggerSource: String = "unknown") {
        let op = operationID ?? makeOperationID(prefix: "move")
        let startedAt = Date()
        log(
            "[WindowManager] move_to_main started",
            fields: [
                "op": op,
                "source": triggerSource
            ]
        )

        let axTrusted = hasAccessibilityPermission()
        log(
            "[WindowManager] accessibility check",
            fields: [
                "op": op,
                "axTrusted": String(axTrusted)
            ]
        )

        if !axTrusted {
            log(
                "[WindowManager] accessibility denied, fallback to System Events",
                level: .warn,
                fields: [
                    "op": op
                ]
            )
            CrashContextRecorder.shared.record("move_to_main_ax_denied op=\(op)")
            logDiagnostics("ax_trusted_false_move")
            moveToMainScreenViaSystemEvents()
            return
        }
        log(
            "[WindowManager] move_to_main AX OK, capturing focused window identity",
            level: .debug,
            fields: ["op": op]
        )
        guard let identity = captureFocusedWindowIdentity() else {
            log(
                "[WindowManager] move_to_main failed: focused window identity missing",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            CrashContextRecorder.shared.record("move_to_main_failed_identity_missing op=\(op)")
            return
        }
        log(
            "[WindowManager] move_to_main captured identity",
            level: .debug,
            fields: [
                "op": op,
                "windowID": String(identity.windowID),
                "pid": String(identity.pid)
            ]
        )
        let moved = moveWindowToMainScreen(
            identity: identity,
            reason: .manualHotkey,
            sessionID: nil,
            operationID: op
        )
        log(
            "[WindowManager] move_to_main moveWindowToMainScreen returned",
            level: .debug,
            fields: [
                "op": op,
                "moved": String(moved)
            ]
        )
        if moved {
            // 移动窗口后 macOS 可能丢失焦点，重新 focus 被移动的窗口
            _ = spaceController.focusWindow(identity.windowID, operationID: op)
            log(
                "MOVED AND MAXIMIZED ON TARGET SCREEN",
                fields: [
                    "op": op,
                    "durationMs": String(elapsedMilliseconds(since: startedAt))
                ]
            )
        } else {
            log(
                "MOVE FAILED",
                level: .error,
                fields: [
                    "op": op,
                    "durationMs": String(elapsedMilliseconds(since: startedAt))
                ]
            )
            CrashContextRecorder.shared.record("move_to_main_failed op=\(op)")
        }
    }

    func shouldRestoreCurrentWindow() -> Bool {
        log(
            "[WindowManager] shouldRestoreCurrentWindow called",
            level: .debug,
            fields: [
                "savedStatesCount": String(savedWindowStates.count)
            ]
        )
        if !hasAccessibilityPermission() {
            log(
                "[WindowManager] shouldRestoreCurrentWindow: no AX permission, using System Events",
                level: .debug
            )
            return shouldRestoreCurrentWindowViaSystemEvents()
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let focusedWindow = focusedWindow(for: frontApp.processIdentifier),
              let currentWindowID = windowHandle(for: focusedWindow) else {
            log(
                "[WindowManager] shouldRestoreCurrentWindow: cannot identify focused window",
                level: .debug,
                fields: [
                    "savedStatesEmpty": String(savedWindowStates.isEmpty),
                    "hasFrontApp": String(NSWorkspace.shared.frontmostApplication != nil)
                ]
            )
            return false
        }

        let focusedOnMain = isWindowOnMainScreen(windowID: currentWindowID)
        log(
            "[WindowManager] shouldRestoreCurrentWindow: focused window identified",
            level: .debug,
            fields: [
                "focusedWindowID": String(currentWindowID),
                "focusedOnMainScreen": String(focusedOnMain)
            ]
        )

        if !focusedOnMain {
            log(
                "[WindowManager] shouldRestoreCurrentWindow: focused window on secondary screen → move to main",
                fields: ["windowID": String(currentWindowID)]
            )
            return false
        }

        // 聚焦窗口在主屏 → 直接查 SQLite 看有没有 toggle record
        guard let record = ToggleEngine.shared.load(windowID: currentWindowID) else {
            log(
                "[WindowManager] shouldRestoreCurrentWindow: no toggle record for window",
                level: .debug,
                fields: ["windowID": String(currentWindowID)]
            )
            return false
        }

        guard let mainScreen = getMainScreen() else { return false }
        if !record.isValid(mainScreenFrame: mainScreen.frame) {
            log(
                "[WindowManager] shouldRestoreCurrentWindow: toggle record corrupted, clearing",
                level: .warn,
                fields: ["windowID": String(currentWindowID)]
            )
            ToggleEngine.shared.clear(windowID: currentWindowID)
            return false
        }

        // 验证窗口确实在 targetFrame 附近
        if let currentFrame = self.frame(of: focusedWindow),
           !record.isNearTarget(currentFrame: currentFrame) {
            log(
                "[WindowManager] shouldRestoreCurrentWindow: window not at target position",
                level: .warn,
                fields: ["windowID": String(currentWindowID)]
            )
            return false
        }

        log(
            "[WindowManager] shouldRestoreCurrentWindow: focused window on main, has valid toggle record → restore",
            fields: [
                "windowID": String(currentWindowID),
                "pid": String(record.pid)
            ]
        )
        return true
    }

    func isSavedStateCorrupted(_ state: SavedWindowState) -> Bool {
        guard let mainScreen = getMainScreen() else {
            log(
                "[WindowManager] isSavedStateCorrupted: no main screen, returning false",
                level: .debug,
                fields: ["stateID": state.id]
            )
            return false
        }
        let mainScreenFrame = mainScreen.frame
        let originalFrame = state.originalFrame.cgRect
        let originalCenter = CGPoint(x: originalFrame.midX, y: originalFrame.midY)
        let targetFrame = state.targetFrame.cgRect
        let targetCenter = CGPoint(x: targetFrame.midX, y: targetFrame.midY)

        // originalFrame 和 targetFrame 的中心都在主屏幕上 → 被污染
        let originalOnMain = mainScreenFrame.contains(originalCenter)
        let targetOnMain = mainScreenFrame.contains(targetCenter)
        let corrupted = originalOnMain && targetOnMain
        log(
            "[WindowManager] isSavedStateCorrupted checked",
            level: .debug,
            fields: [
                "stateID": state.id,
                "originalOnMain": String(originalOnMain),
                "targetOnMain": String(targetOnMain),
                "corrupted": String(corrupted)
            ]
        )
        return corrupted
    }

    func shouldRestoreAcrossSpaces() -> Bool {
        spaceController.refreshAvailabilityIfNeeded()
        guard spaceController.isEnabled else {
            log(
                "[WindowManager] shouldRestoreAcrossSpaces: space integration disabled",
                level: .debug
            )
            return false
        }

        // 需要焦点窗口的 windowID 来查 SQLite
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let focusedWindow = focusedWindow(for: frontApp.processIdentifier),
              let currentWindowID = windowHandle(for: focusedWindow) else {
            return false
        }

        let currentSpace = spaceController.currentSpaceIndex()
        guard let record = ToggleEngine.shared.load(windowID: currentWindowID),
              let current = currentSpace,
              record.sourceSpace != current else {
            log(
                "[WindowManager] shouldRestoreAcrossSpaces: no cross-space condition met",
                level: .debug,
                fields: [
                    "currentSpace": String(describing: currentSpace)
                ]
            )
            return false
        }

        log(
            "[WindowManager] shouldRestoreAcrossSpaces: matched across spaces",
            level: .debug,
            fields: [
                "sourceSpace": String(record.sourceSpace),
                "currentSpace": String(current)
            ]
        )
        log("Detected moved window state across spaces: source=\(record.sourceSpace) current=\(current)")
        return true
    }
}
