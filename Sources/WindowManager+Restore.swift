import AppKit
import Foundation

@MainActor
extension WindowManager {

    func restore(operationID: String? = nil, triggerSource: String = "unknown") {
        let op = operationID ?? makeOperationID(prefix: "restore")
        let startedAt = Date()
        updateCrashSnapshotFromRuntime()
        logRuntimeStateSnapshot(context: "restore_start")

        // === 直接从 ToggleEngine (SQLite) 读取状态，不依赖内存变量 ===
        // 找到当前焦点窗口的 windowID，用它查 SQLite
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

        // 1. 拿到焦点窗口的 windowID
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

        // 2. 从 SQLite 读取 toggle record（单一事实来源）
        let engine = ToggleEngine.shared
        guard let record = engine.load(windowID: currentWindowID) else {
            log(
                "[WindowManager] restore failed: no toggle record in SQLite",
                level: .warn,
                fields: ["op": op, "windowID": String(currentWindowID)]
            )
            return
        }

        // 3. 验证 record 有效性
        guard let mainScreen = getMainScreen() else {
            log("[WindowManager] restore failed: no main screen", level: .error, fields: ["op": op])
            return
        }
        guard record.isValid(mainScreenFrame: mainScreen.frame) else {
            log(
                "[WindowManager] restore failed: toggle record corrupted (origFrame on main screen)",
                level: .warn,
                fields: ["op": op, "windowID": String(currentWindowID)]
            )
            engine.clear(windowID: currentWindowID)
            return
        }

        let origFrame = record.origFrame
        let targetSpace = record.sourceSpace
        let targetDisplay = record.sourceYabaiDisp

        log(
            "[WindowManager] restore: loaded toggle record from SQLite",
            level: .info,
            fields: [
                "op": op,
                "windowID": String(currentWindowID),
                "pid": String(record.pid),
                "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y)) \(Int(origFrame.size.width))x\(Int(origFrame.size.height))",
                "sourceSpace": String(targetSpace),
                "sourceYabaiDisp": String(targetDisplay)
            ]
        )

        // 4. 找到窗口 AX element
        guard let window = findWindowByPID(record.pid, windowID: currentWindowID) else {
            log(
                "[WindowManager] restore: AX query failed, falling back to System Events",
                level: .warn,
                fields: ["op": op, "windowID": String(currentWindowID), "pid": String(record.pid)]
            )
            restoreViaSystemEvents()
            return
        }

        // 5. 验证窗口确实在 targetFrame 附近（确认这个窗口确实被 toggle 过来）
        guard let currentFrame = self.frame(of: window) else {
            log("[WindowManager] restore failed: cannot read current frame", level: .error, fields: ["op": op])
            return
        }
        if !record.isNearTarget(currentFrame: currentFrame) {
            log(
                "[WindowManager] restore skipped: window not at toggle target position",
                level: .warn,
                fields: [
                    "op": op,
                    "windowID": String(currentWindowID),
                    "currentX": String(Int(currentFrame.origin.x)),
                    "currentY": String(Int(currentFrame.origin.y)),
                    "targetX": String(Int(record.targetFrame.origin.x)),
                    "targetY": String(Int(record.targetFrame.origin.y))
                ]
            )
            return
        }

        // 6. 预检：窗口已在原始位置 → 跳过
        if framesMatch(currentFrame, origFrame) {
            log(
                "[WindowManager] restore skipped: window already at original position",
                fields: ["op": op]
            )
            engine.clear(windowID: currentWindowID)
            CrashContextRecorder.shared.record("restore_skipped_already_at_original op=\(op)")
            return
        }

        // 7. AX 属性检查
        guard isAttributeSettable(window, attribute: kAXPositionAttribute),
              isAttributeSettable(window, attribute: kAXSizeAttribute) else {
            log(
                "[WindowManager] restore failed: AX attributes not settable",
                level: .error,
                fields: ["op": op]
            )
            CrashContextRecorder.shared.record("restore_failed_ax_not_settable op=\(op)")
            return
        }

        // 8. Space 预切换（在 apply frame 之前，因为坐标相对于 Display）
        let displayCurrentSpace = spaceController.displayVisibleSpace(displayIndex: targetDisplay)
        log("[WindowManager] restore: pre-apply space check", fields: [
            "op": op,
            "targetSpace": String(targetSpace),
            "targetDisplay": String(targetDisplay),
            "displayCurrentSpace": String(describing: displayCurrentSpace)
        ])

        if let current = displayCurrentSpace, current != targetSpace {
            log("[WindowManager] restore: switching display from space \(current) to \(targetSpace)", level: .info, fields: [
                "op": op, "targetDisplay": String(targetDisplay)
            ])
            let switched = spaceController.switchDisplayToSpace(targetSpace: targetSpace, operationID: op)
            if switched {
                // 轮询等待 display 到达目标 space（替代固定 400ms sleep）
                let td = targetDisplay
                let started = Date()
                while Date().timeIntervalSince(started) < 0.4 {
                    if spaceController.displayVisibleSpace(displayIndex: td) == targetSpace { break }
                    usleep(30_000)
                }
            }
            log("[WindowManager] restore: space switch result", fields: [
                "op": op, "switched": String(switched)
            ])
        } else {
            log("[WindowManager] restore: display already on target space, no switch needed", fields: [
                "op": op
            ])
        }

        // 9. Space 切换后重新获取 AX element（引用可能失效）
        let restoreAX = findWindowByPID(record.pid, windowID: currentWindowID) ?? window

        // 10. Apply frame
        guard apply(frame: origFrame, to: restoreAX, operationID: op, stage: "restore_apply_frame") else {
            log("[WindowManager] restore failed: apply frame failed", level: .error, fields: ["op": op])
            CrashContextRecorder.shared.record("restore_failed_apply_frame op=\(op)")
            return
        }

        // 11. 验证 frame
        guard let restoredFrame = self.frame(of: restoreAX) else {
            log("[WindowManager] restore failed: cannot read back frame", level: .error, fields: ["op": op])
            CrashContextRecorder.shared.record("restore_failed_readback op=\(op)")
            return
        }

        guard framesMatch(restoredFrame, origFrame) else {
            log(
                "[WindowManager] restore failed: frame mismatch",
                level: .error,
                fields: [
                    "op": op,
                    "expected": String(describing: origFrame),
                    "actual": String(describing: restoredFrame)
                ]
            )
            CrashContextRecorder.shared.record("restore_failed_frame_mismatch op=\(op)")
            return
        }

        // 12. 焦点跟随（仅 carbon_hotkey 触发）
        if triggerSource == "carbon_hotkey" {
            if let postApplySpace = spaceController.windowSpaceIndex(windowID: currentWindowID),
               let currentSpace = spaceController.currentSpaceIndex(),
               postApplySpace != currentSpace {
                log("[WindowManager] restore: following window to Space \(postApplySpace)", fields: [
                    "op": op, "windowID": String(currentWindowID), "currentSpace": String(currentSpace)
                ])
                _ = spaceController.focusWindow(currentWindowID, operationID: op)
            }
        }

        // 13. 清理 — 清除 SQLite toggle record
        engine.clear(windowID: currentWindowID)
        SessionWindowRegistry.shared.clearToggleState(windowID: currentWindowID)

        let finalDurationMs = elapsedMilliseconds(since: startedAt)
        log(
            "[WindowManager] restore finished",
            fields: [
                "op": op,
                "outcome": "restored",
                "durationMs": String(finalDurationMs)
            ]
        )
        CrashContextRecorder.shared.record("restore_success op=\(op) outcome=restored durationMs=\(finalDurationMs)")
    }
}
