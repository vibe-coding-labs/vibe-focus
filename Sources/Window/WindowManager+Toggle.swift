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
            if let id = winID {
                toggleContext["windowID"] = String(id)
            }
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
            restore(operationID: op, triggerSource: triggerSource)
            // 设置冷却期：防止 Stop 事件立即把刚恢复的窗口再次拉到主屏
            if let winIDStr = toggleContext["windowID"], let winID = UInt32(winIDStr) {
                HookEventHandler.shared.setMoveCooldown(windowID: winID)
            }
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
            moveToMainScreen(operationID: op, triggerSource: triggerSource)
            if let winIDStr = toggleContext["windowID"], let winID = UInt32(winIDStr) {
                AuditLogger.shared.record(
                    eventType: "toggle_move_to_main",
                    windowID: winID,
                    details: ["mode": "move_to_main", "source": triggerSource]
                )
            }
        }

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
        if durationMs >= 650 {
            CrashContextRecorder.shared.record("toggle_slow op=\(op) durationMs=\(durationMs) mode=\(mode)")
        }
    }

    private func moveStuckWindowToSecondaryScreen(operationID: String, triggerSource: String) {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let focusedWin = focusedWindow(for: frontApp.processIdentifier),
              let windowID = windowHandle(for: focusedWin) else {
            log("[WindowManager] moveStuckWindowToSecondaryScreen: no focused window", level: .warn)
            return
        }

        let spaceController = SpaceController.shared

        // 优先使用 yabai space move（让 yabai 追踪窗口位置）
        // 找到副屏当前可见的 space
        let screens = NSScreen.screens
        let mainScreen = getMainScreen()
        let secondaryScreen = screens.first { screen in
            mainScreen.map { !$0.frame.contains(CGPoint(x: screen.frame.midX, y: screen.frame.midY)) } ?? false
        }
        if let secondaryScreen,
           let secDisplayID = displayID(for: secondaryScreen),
           let secDisplayIndex = displayIndex(forDisplayID: secDisplayID),
           let targetSpace = spaceController.displayVisibleSpace(displayIndex: .yabai(secDisplayIndex)) {
            let moved = spaceController.moveWindow(
                windowID,
                toSpace: targetSpace,
                focus: false,
                operationID: operationID
            )
            log(
                "[WindowManager] moveStuckWindowToSecondaryScreen: yabai space move",
                fields: [
                    "op": operationID,
                    "windowID": String(windowID),
                    "targetSpace": String(describing: targetSpace),
                    "moved": String(moved)
                ]
            )
            if moved { return }
        }

        log(
            "[WindowManager] moveStuckWindowToSecondaryScreen: yabai space move failed, no fallback",
            level: .warn,
            fields: ["op": operationID, "windowID": String(windowID)]
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

        if !axTrusted {
            log(
                "[WindowManager] move_to_main failed: accessibility denied",
                level: .warn,
                fields: [
                    "op": op
                ]
            )
            CrashContextRecorder.shared.record("move_to_main_ax_denied op=\(op)")
            logDiagnostics("ax_trusted_false_move")
            notifyAccessibilityPermissionRequired()
            return
        }
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
        let moved = moveWindowToMainScreen(
            identity: identity,
            reason: .manualHotkey,
            sessionID: nil,
            operationID: op
        )
        HookEventHandler.shared.clearAutoRestoreCooldown(windowID: identity.windowID)
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

    /// Restore decision — extracted for testability
    enum RestoreDecision {
        case restore                // window on main + valid toggle record
        case moveToMain             // window on secondary screen
        case noRecord               // no toggle record found
        case corruptedClearWindowID(UInt32)  // record exists but invalid
        case noFocusedWindow        // cannot identify focused window
        case noMainScreen           // cannot get main screen frame
    }

    /// Pure decision logic for shouldRestoreCurrentWindow.
    /// Separates the decision tree from system I/O for unit testing.
    static func decideRestore(
        focusedOnMain: Bool?,
        recordByWindowID: ToggleRecord?,
        mainScreenFrame: CGRect?
    ) -> RestoreDecision {
        guard let focusedOnMain else {
            return .noFocusedWindow
        }
        if !focusedOnMain {
            return .moveToMain
        }
        guard let record = recordByWindowID else {
            return .noRecord
        }
        guard let mainScreenFrame else {
            return .noMainScreen
        }
        if !record.isValid(mainScreenFrame: mainScreenFrame) {
            return .corruptedClearWindowID(record.windowID)
        }
        return .restore
    }

    func shouldRestoreCurrentWindow() -> Bool {
        return shouldRestoreCurrentWindow(store: ToggleEngine.shared)
    }

    /// Testable overload that accepts an injected ToggleRecordStore.
    func shouldRestoreCurrentWindow(store: ToggleRecordStore) -> Bool {
        if !hasAccessibilityPermission() {
            log(
                "[WindowManager] shouldRestoreCurrentWindow: no AX permission, cannot determine",
                level: .debug
            )
            return false
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
        guard let record = store.load(windowID: currentWindowID) else {
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
                fields: [
                    "windowID": String(currentWindowID),
                    "storedWindowID": String(record.windowID)
                ]
            )
            store.clear(windowID: record.windowID)
            return false
        }

        // isNearTarget 守卫已移除 — yabai tiling 引擎会移动窗口导致偏移，
        // 此时恰恰是需要 restore 的场景。isValid 检查已足够防止 corrupted data。

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
