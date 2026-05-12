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
            AuditLogger.shared.record(
                eventType: "restore_failed",
                windowID: currentWindowID,
                pid: record.pid,
                details: ["reason": "corrupted_record", "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y))"]
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
        guard let currentFrame = readAccurateFrame(windowID: currentWindowID, axElement: window) else {
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

        var spaceReady = false

        if let current = displayCurrentSpace, current == targetSpace {
            // Display 已经在目标 Space，只需移动窗口
            log("[WindowManager] restore: display already on target space, moving window", fields: [
                "op": op, "targetSpace": String(targetSpace)
            ])
            let moved = spaceController.moveWindow(currentWindowID, toSpaceIndex: targetSpace, focus: false, operationID: op)
            if moved {
                // 快速验证窗口已到达目标 Space
                let started = Date()
                while Date().timeIntervalSince(started) < 0.2 {
                    if let s = spaceController.windowSpaceIndex(windowID: currentWindowID), s == targetSpace { break }
                    usleep(20_000)
                }
                spaceReady = true
            } else {
                log("[WindowManager] restore: moveWindow failed (display on target space)", level: .warn, fields: [
                    "op": op, "windowID": String(currentWindowID), "targetSpace": String(targetSpace)
                ])
            }
        } else if let current = displayCurrentSpace, current != targetSpace {
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

                // 移动窗口到目标 Space
                let moved = spaceController.moveWindow(currentWindowID, toSpaceIndex: targetSpace, focus: triggerSource == "carbon_hotkey", operationID: op)
                if moved {
                    let started = Date()
                    while Date().timeIntervalSince(started) < 0.2 {
                        if let s = spaceController.windowSpaceIndex(windowID: currentWindowID), s == targetSpace { break }
                        usleep(20_000)
                    }
                    spaceReady = true
                } else {
                    log("[WindowManager] restore: moveWindow failed after display switch", level: .warn, fields: [
                        "op": op, "windowID": String(currentWindowID), "targetSpace": String(targetSpace)
                    ])
                }
            } else {
                log("[WindowManager] restore: switchDisplayToSpace failed", level: .warn, fields: [
                    "op": op, "targetSpace": String(targetSpace)
                ])
            }
        } else {
            log("[WindowManager] restore: could not determine display current space", level: .warn, fields: [
                "op": op, "targetDisplay": String(targetDisplay)
            ])
        }

        if !spaceReady {
            log("[WindowManager] restore: window not on target space, aborting to avoid wrong-screen coordinates", level: .error, fields: [
                "op": op,
                "windowID": String(currentWindowID),
                "targetSpace": String(targetSpace),
                "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y)) \(Int(origFrame.size.width))x\(Int(origFrame.size.height))"
            ])
            return
        }

        // 9. Space 切换后重新获取 AX element（引用可能失效）
        guard let restoreAX = findWindowByPID(record.pid, windowID: currentWindowID) else {
            log("[WindowManager] restore failed: AX element lost after space switch", level: .error, fields: [
                "op": op, "windowID": String(currentWindowID), "pid": String(record.pid)
            ])
            CrashContextRecorder.shared.record("restore_failed_ax_lost_after_space_switch op=\(op)")
            return
        }

        // 10. Apply frame
        log("[WindowManager] restore: applying frame", fields: [
            "op": op,
            "currentFrame": String(describing: currentFrame),
            "targetOrigFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y)) \(Int(origFrame.size.width))x\(Int(origFrame.size.height))",
            "targetSpace": String(targetSpace),
            "targetDisplay": String(targetDisplay)
        ])
        guard apply(frame: origFrame, to: restoreAX, operationID: op, stage: "restore_apply_frame") else {
            log("[WindowManager] restore failed: apply frame failed", level: .error, fields: [
                "op": op,
                "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y))",
                "currentFrame": String(describing: currentFrame)
            ])
            CrashContextRecorder.shared.record("restore_failed_apply_frame op=\(op)")
            return
        }

        // 11. 验证 frame
        // AX-safe: window was just moved to original position, target space is now visible
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
                    "actual": String(describing: restoredFrame),
                    "preApplyFrame": String(describing: currentFrame),
                    "targetSpace": String(targetSpace)
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
                let spaceMatch = postApplySpace == targetSpace
                log("[WindowManager] restore: following window to Space \(postApplySpace)", fields: [
                    "op": op, "windowID": String(currentWindowID), "currentSpace": String(currentSpace),
                    "targetSpace": String(targetSpace), "spaceMatchTarget": String(spaceMatch)
                ])
                _ = spaceController.focusWindow(currentWindowID, operationID: op)
                if !spaceMatch {
                    log("[WindowManager] restore: window ended up on unexpected Space \(postApplySpace) (expected \(targetSpace))", level: .warn, fields: [
                        "op": op, "windowID": String(currentWindowID)
                    ])
                }
            }
        }

        // 13. 清理 — 清除 SQLite toggle record（先记录原始数据）
        log(
            "[WindowManager] restore: clearing toggle record",
            level: .debug,
            fields: [
                "op": op,
                "windowID": String(currentWindowID),
                "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y)) \(Int(origFrame.size.width))x\(Int(origFrame.size.height))",
                "sourceSpace": String(targetSpace),
                "sourceYabaiDisp": String(targetDisplay),
                "restoredFrame": String(describing: restoredFrame)
            ]
        )
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
        AuditLogger.shared.record(
            eventType: "restore_success",
            windowID: currentWindowID,
            pid: record.pid,
            sessionID: record.sessionID,
            details: [
                "sourceSpace": String(targetSpace),
                "sourceYabaiDisp": String(targetDisplay),
                "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y))",
                "durationMs": String(finalDurationMs)
            ]
        )
        CrashContextRecorder.shared.record("restore_success op=\(op) outcome=restored durationMs=\(finalDurationMs)")
    }
}
