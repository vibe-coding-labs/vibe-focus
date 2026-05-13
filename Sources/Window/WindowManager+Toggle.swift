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
            "frontBefore": frontBefore
        ]
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           let focusedWin = focusedWindow(for: frontApp.processIdentifier) {
            let winTitle = title(of: focusedWin) ?? ""
            // AX-safe: focused window is always visible
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
            if let winIDStr = toggleContext["windowID"], let winID = UInt32(winIDStr) {
                AuditLogger.shared.record(
                    eventType: "toggle_restore",
                    windowID: winID,
                    details: ["mode": "restore", "source": triggerSource]
                )
            }
        } else if toggleContext["onMainScreen"] == "true" {
            // Window is on main screen but has no valid toggle record → stuck state.
            // Move to secondary screen to unblock the toggle cycle.
            log(
                "[WindowManager] toggle: window stuck on main screen with no toggle record, moving to secondary",
                level: .info,
                fields: ["op": op, "windowID": toggleContext["windowID"] ?? "nil"]
            )
            moveStuckWindowToSecondaryScreen(operationID: op, triggerSource: triggerSource)
            if let winIDStr = toggleContext["windowID"], let winID = UInt32(winIDStr) {
                AuditLogger.shared.record(
                    eventType: "toggle_move_to_secondary",
                    windowID: winID,
                    details: ["mode": "move_to_secondary_stuck", "source": triggerSource]
                )
            }
        } else {
            log(
                "[WindowManager] toggle branching to moveToMainScreen",
                level: .debug,
                fields: ["op": op]
            )
            moveToMainScreen(operationID: op, triggerSource: triggerSource)
            if let winIDStr = toggleContext["windowID"], let winID = UInt32(winIDStr) {
                AuditLogger.shared.record(
                    eventType: "toggle_move_to_main",
                    windowID: winID,
                    details: ["mode": "move_to_main", "source": triggerSource]
                )
            }
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

    private func moveStuckWindowToSecondaryScreen(operationID: String, triggerSource: String) {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let focusedWin = focusedWindow(for: frontApp.processIdentifier),
              // AX-safe: focused window is always visible
              let currentFrame = frame(of: focusedWin) else {
            log("[WindowManager] moveStuckWindowToSecondaryScreen: no focused window", level: .warn)
            return
        }

        let screens = NSScreen.screens
        guard screens.count > 1, let mainScreen = getMainScreen() else {
            log("[WindowManager] moveStuckWindowToSecondaryScreen: no secondary screen available", level: .warn)
            return
        }

        let targetScreen = screens.first { screen in
            !mainScreen.frame.contains(CGPoint(x: screen.frame.midX, y: screen.frame.midY))
        }

        guard let targetScreen else {
            log("[WindowManager] moveStuckWindowToSecondaryScreen: could not find secondary screen", level: .warn)
            return
        }

        let targetVisibleFrame = targetScreen.visibleFrame
        let newX = targetVisibleFrame.origin.x + (targetVisibleFrame.width - currentFrame.width) / 2
        let newY = targetVisibleFrame.origin.y + (targetVisibleFrame.height - currentFrame.height) / 2
        let centeredFrame = CGRect(x: newX, y: newY, width: currentFrame.width, height: currentFrame.height)

        var targetOrigin = CGPoint(x: centeredFrame.origin.x, y: centeredFrame.origin.y)
        var targetSize = CGSize(width: centeredFrame.width, height: centeredFrame.height)
        guard let originValue = AXValueCreate(.cgPoint, &targetOrigin),
              let sizeValue = AXValueCreate(.cgSize, &targetSize) else {
            log("[WindowManager] moveStuckWindowToSecondaryScreen: AXValueCreate failed", level: .warn)
            return
        }
        AXUIElementSetAttributeValue(focusedWin, kAXPositionAttribute as CFString, originValue as CFTypeRef)
        AXUIElementSetAttributeValue(focusedWin, kAXSizeAttribute as CFString, sizeValue as CFTypeRef)

        log(
            "[WindowManager] moveStuckWindowToSecondaryScreen: moved window",
            fields: [
                "op": operationID,
                "windowID": String(describing: windowHandle(for: focusedWin)),
                "fromX": String(Int(currentFrame.origin.x)),
                "fromY": String(Int(currentFrame.origin.y)),
                "toX": String(Int(centeredFrame.origin.x)),
                "toY": String(Int(centeredFrame.origin.y))
            ]
        )
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
            level: .debug
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

        // AX-safe: focused window is always visible
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
}
