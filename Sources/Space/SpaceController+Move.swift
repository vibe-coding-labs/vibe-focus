import AppKit
import Foundation

@MainActor
extension SpaceController {

    func moveWindow(_ windowID: UInt32, toSpaceIndex spaceIndex: Int, focus: Bool, operationID: String? = nil) -> Bool {
        let op = operationID ?? "none"
        log(
            "[moveWindow] called",
            level: .debug,
            fields: [
                "op": op,
                "windowID": String(windowID),
                "targetSpace": String(spaceIndex),
                "focus": String(focus)
            ]
        )
        AuditLogger.shared.record(
            eventType: "space_move",
            windowID: windowID,
            details: [
                "targetSpace": String(spaceIndex),
                "focus": String(focus),
                "op": op
            ]
        )
        refreshAvailabilityIfNeeded()
        guard isEnabled else {
            log(
                "[moveWindow] aborted: space integration not enabled",
                level: .debug,
                fields: ["op": op]
            )
            return false
        }
        guard canControlSpaces else {
            markOperationError("Cannot move window to another space because cross-space control is unavailable", operationID: op)
            return false
        }

        // 安全检查 + 上下文记录合并为一次 queryWindow 调用
        log(
            "[moveWindow] querying window info for safety check",
            level: .debug,
            fields: ["op": op, "windowID": String(windowID)]
        )
        let windowInfo = queryWindow(windowID: windowID)
        if windowInfo == nil {
            log(
                "[SpaceController] moveWindow aborted: window does not exist",
                level: .warn,
                fields: [
                    "op": op,
                    "windowID": String(windowID),
                    "targetSpace": String(spaceIndex)
                ]
            )
            return false
        }

        log(
            "[SpaceController] moveWindow called",
            fields: [
                "op": op,
                "windowID": String(windowID),
                "targetSpace": String(spaceIndex),
                "windowCurrentSpace": String(describing: windowInfo?.space),
                "windowCurrentDisplay": String(describing: windowInfo?.display),
                "focus": String(focus)
            ]
        )

        let nativeAvailable = NativeSpaceBridge.isAvailable

        log(
            "[moveWindow] checking NativeSpaceBridge availability",
            level: .debug,
            fields: [
                "op": op,
                "nativeAvailable": String(nativeAvailable)
            ]
        )

        // 策略 1：使用 NativeSpaceBridge (CGS API) 直接移动
        // 这比 yabai 更可靠，不依赖 scripting-addition
        // 清除失败缓存，给本次操作全新机会
        NativeSpaceBridge.resetFailureCache()
        if nativeAvailable, let spaceID = nativeSpaceID(forYabaiIndex: spaceIndex) {
            log(
                "[SpaceController] trying NativeSpaceBridge first",
                fields: [
                    "op": op,
                    "windowID": String(windowID),
                    "yabaiIndex": String(spaceIndex),
                    "nativeSpaceID": String(spaceID)
                ]
            )
            if NativeSpaceBridge.moveWindow(windowID, toSpaceID: spaceID) {
                log(
                    "[moveWindow] NativeSpaceBridge moveWindow returned true, waiting 200ms",
                    level: .debug,
                    fields: ["op": op, "spaceID": String(spaceID)]
                )
                usleep(80_000) // 等待移动生效
                if verifyWindowMovedToSpace(windowID: windowID, targetSpace: spaceIndex, operationID: op) {
                    log(
                        "[SpaceController] NativeSpaceBridge move succeeded and verified",
                        fields: [
                            "op": op,
                            "windowID": String(windowID),
                            "targetSpace": String(spaceIndex)
                        ]
                    )
                    if focus {
                        _ = focusWindow(windowID, operationID: op)
                    }
                    return true
                }
                log(
                    "[SpaceController] NativeSpaceBridge move executed but verification failed, trying yabai",
                    level: .warn,
                    fields: [
                        "op": op,
                        "windowID": String(windowID),
                        "targetSpace": String(spaceIndex)
                    ]
                )
            }
        }

        // 策略 2：yabai 命令（带后置验证重试）
        log(
            "[moveWindow] strategy 2: trying yabai command",
            level: .debug,
            fields: [
                "op": op,
                "windowID": String(windowID),
                "targetSpace": String(spaceIndex)
            ]
        )
        let moveResult = runYabaiVariants(
            variants: [["-m", "window", "\(windowID)", "--space", "\(spaceIndex)"]],
            operation: "moveWindow(windowID=\(windowID), space=\(spaceIndex))",
            operationID: op
        )
        log(
            "[moveWindow] yabai runYabaiVariants returned",
            level: .debug,
            fields: [
                "op": op,
                "success": String(moveResult.success)
            ]
        )
        if moveResult.success {
            if verifyWindowMovedToSpaceWithRetry(windowID: windowID, targetSpace: spaceIndex, operationID: op) {
                if focus {
                    _ = focusWindow(windowID, operationID: op)
                }
                return true
            }
            // yabai 报成功但窗口实际未移动 — 尝试 NativeSpaceBridge fallback
            if nativeAvailable, let spaceID = nativeSpaceID(forYabaiIndex: spaceIndex) {
                NativeSpaceBridge.resetFailureCache()
                log(
                    "[SpaceController] yabai move unverified, trying NativeSpaceBridge fallback",
                    fields: [
                        "op": op,
                        "windowID": String(windowID),
                        "targetSpace": String(spaceIndex)
                    ]
                )
                if NativeSpaceBridge.moveWindow(windowID, toSpaceID: spaceID) {
                    // 等待更长时间让 CGS API 生效（最多 1200ms）
                    var verified = false
                    for attempt in 1...8 {
                        usleep(150_000) // 150ms per attempt
                        if verifyWindowMovedToSpace(windowID: windowID, targetSpace: spaceIndex, operationID: op) {
                            verified = true
                            break
                        }
                        log(
                            "[SpaceController] NativeSpaceBridge fallback verification attempt \(attempt) failed",
                            level: .debug,
                            fields: ["op": op, "windowID": String(windowID), "targetSpace": String(spaceIndex)]
                        )
                    }
                    if verified {
                        if focus {
                            _ = focusWindow(windowID, operationID: op)
                        }
                        return true
                    }
                }
            }
            // yabai + NativeSpaceBridge 都失败 — 尝试 focus 目标 space 再重试
            log(
                "[SpaceController] trying focus-then-move strategy (yabai unverified branch)",
                fields: [
                    "op": op,
                    "windowID": String(windowID),
                    "targetSpace": String(spaceIndex)
                ]
            )
            let focusResult = runYabai(
                arguments: ["-m", "space", "--focus", "\(spaceIndex)"],
                operation: "moveWindow_focusTargetSpace_unverified",
                operationID: op
            )
            if let result = focusResult, result.exitCode == 0 {
                pollUntil(timeout: 200_000, interval: 20_000) {
                    self.windowSpaceIndex(windowID: windowID) == spaceIndex
                }
                let retryResult = runYabai(
                    arguments: ["-m", "window", "\(windowID)", "--space", "\(spaceIndex)"],
                    operation: "moveWindow_focusRetry_unverified",
                    operationID: op
                )
                if let retry = retryResult, retry.exitCode == 0 {
                    if verifyWindowMovedToSpaceWithRetry(windowID: windowID, targetSpace: spaceIndex, operationID: op) {
                        log(
                            "[SpaceController] focus-then-move succeeded (unverified branch)",
                            fields: ["op": op, "windowID": String(windowID), "targetSpace": String(spaceIndex)]
                        )
                        if focus {
                            _ = focusWindow(windowID, operationID: op)
                        }
                        return true
                    }
                }
            }

            log(
                "[SpaceController] moveWindow failed: all strategies including focus-then-move could not move window to target space",
                level: .warn,
                fields: [
                    "op": op,
                    "windowID": String(windowID),
                    "targetSpace": String(spaceIndex)
                ]
            )
            return false
        }

        // 策略 3：yabai 失败时尝试 NativeSpaceBridge
        if !nativeAvailable {
            markOperationError(
                from: moveResult.failure,
                fallback: "Failed to move window \(windowID) to space \(spaceIndex)",
                operationID: op
            )
            return false
        }

        guard let spaceID = nativeSpaceID(forYabaiIndex: spaceIndex) else {
            markOperationError(
                from: moveResult.failure,
                fallback: "Failed to move window \(windowID) to space \(spaceIndex)",
                operationID: op
            )
            return false
        }

        log(
            "[SpaceController] yabai moveWindow failed, trying native fallback",
            fields: [
                "op": op,
                "windowID": String(windowID),
                "yabaiIndex": String(spaceIndex),
                "nativeSpaceID": String(spaceID),
            ]
        )
        NativeSpaceBridge.resetFailureCache()
        if NativeSpaceBridge.moveWindow(windowID, toSpaceID: spaceID) {
            if focus {
                _ = focusWindow(windowID, operationID: op)
            }
            return true
        }

        // 策略 4：先 focus 目标 space，再重试 yabai move
        // 窗口跨 display 移动时，yabai 需要目标 space 是当前焦点才能成功移动窗口
        log(
            "[SpaceController] trying focus-then-move strategy: focus target space then retry yabai",
            fields: [
                "op": op,
                "windowID": String(windowID),
                "targetSpace": String(spaceIndex)
            ]
        )
        let focusResult = runYabai(
            arguments: ["-m", "space", "--focus", "\(spaceIndex)"],
            operation: "moveWindow_focusTargetSpace",
            operationID: op
        )
        if let result = focusResult, result.exitCode == 0 {
            pollUntil(timeout: 200_000, interval: 20_000) {
                self.windowSpaceIndex(windowID: windowID) == spaceIndex
            }
            let retryResult = runYabai(
                arguments: ["-m", "window", "\(windowID)", "--space", "\(spaceIndex)"],
                operation: "moveWindow_focusRetry",
                operationID: op
            )
            if let retry = retryResult, retry.exitCode == 0 {
                if verifyWindowMovedToSpaceWithRetry(windowID: windowID, targetSpace: spaceIndex, operationID: op) {
                    log(
                        "[SpaceController] focus-then-move strategy succeeded",
                        fields: ["op": op, "windowID": String(windowID), "targetSpace": String(spaceIndex)]
                    )
                    if focus {
                        _ = focusWindow(windowID, operationID: op)
                    }
                    return true
                }
            }
        }

        markOperationError(
            from: moveResult.failure,
            fallback: "Failed to move window \(windowID) to space \(spaceIndex)",
            operationID: op
        )
        return false
    }

    func moveWindowToSpace(windowID: UInt32, targetSpace: Int, operationID: String?) -> Bool {
        let op = operationID ?? "none"

        // 查询窗口当前所在的 space
        guard let currentSpace = windowSpaceIndex(windowID: windowID) else {
            log(
                "[SpaceController] moveWindowToSpace: cannot query window space",
                level: .warn,
                fields: ["op": op, "windowID": String(windowID)]
            )
            return false
        }

        guard currentSpace != targetSpace else {
            log(
                "[SpaceController] moveWindowToSpace: already on target space",
                fields: ["op": op, "windowID": String(windowID), "space": String(targetSpace)]
            )
            return true
        }

        log(
            "[SpaceController] moveWindowToSpace: need to move window",
            fields: [
                "op": op,
                "windowID": String(windowID),
                "currentSpace": String(currentSpace),
                "targetSpace": String(targetSpace)
            ]
        )

        // 策略 1: yabai -m window <id> --space <target>
        let moveResult = runYabai(
            arguments: ["-m", "window", String(windowID), "--space", String(targetSpace)],
            operation: "moveWindowToSpace",
            operationID: op
        )
        if let result = moveResult, result.exitCode == 0 {
            let verified = pollUntil(timeout: 200_000, interval: 20_000) {
                self.windowSpaceIndex(windowID: windowID) == targetSpace
            }
            if verified {
                log(
                    "[SpaceController] moveWindowToSpace: yabai window --space succeeded",
                    fields: ["op": op, "windowID": String(windowID), "targetSpace": String(targetSpace)]
                )
                return true
            }
            log(
                "[SpaceController] moveWindowToSpace: yabai executed but window not on target, trying space focus first",
                level: .warn,
                fields: ["op": op, "windowID": String(windowID), "targetSpace": String(targetSpace)]
            )
        }

        // 策略 2: 先切目标 space 所在 Display 到目标 space，再移窗口
        let focusResult = runYabai(
            arguments: ["-m", "space", "--focus", String(targetSpace)],
            operation: "moveWindowToSpace_focusTargetSpace",
            operationID: op
        )
        if let result = focusResult, result.exitCode == 0 {
            // 等待 space focus 生效
            pollUntil(timeout: 200_000, interval: 20_000) {
                self.displayVisibleSpace(displayIndex: nil) == targetSpace
            }

            let retryResult = runYabai(
                arguments: ["-m", "window", String(windowID), "--space", String(targetSpace)],
                operation: "moveWindowToSpace_retry",
                operationID: op
            )
            if let retry = retryResult, retry.exitCode == 0 {
                let verified = pollUntil(timeout: 200_000, interval: 20_000) {
                    self.windowSpaceIndex(windowID: windowID) == targetSpace
                }
                if verified {
                    log(
                        "[SpaceController] moveWindowToSpace: space focus + window move succeeded",
                        fields: ["op": op, "windowID": String(windowID)]
                    )
                    return true
                }
            }
        }

        // 策略 3: NativeSpaceBridge
        if let spaceID = nativeSpaceID(forYabaiIndex: targetSpace) {
            log(
                "[SpaceController] moveWindowToSpace: trying NativeSpaceBridge",
                fields: ["op": op, "windowID": String(windowID), "targetSpace": String(targetSpace), "nativeSpaceID": String(spaceID)]
            )
            NativeSpaceBridge.resetFailureCache()
            if NativeSpaceBridge.moveWindow(windowID, toSpaceID: spaceID) {
                let verified = pollUntil(timeout: 500_000, interval: 50_000) {
                    self.windowSpaceIndex(windowID: windowID) == targetSpace
                }
                if verified {
                    log(
                        "[SpaceController] moveWindowToSpace: NativeSpaceBridge verified",
                        fields: ["op": op, "windowID": String(windowID)]
                    )
                    return true
                }
            }
        }

        let finalSpace = windowSpaceIndex(windowID: windowID)
        log(
            "[SpaceController] moveWindowToSpace: all strategies failed",
            level: .error,
            fields: ["op": op, "windowID": String(windowID), "targetSpace": String(targetSpace), "finalSpace": String(describing: finalSpace)]
        )
        return false
    }

    func verifyWindowMovedToSpace(windowID: UInt32, targetSpace: Int, operationID: String) -> Bool {
        let windowAfter = queryWindow(windowID: windowID)
        let verified = windowAfter?.space == targetSpace
        if !verified {
            log(
                "[SpaceController] verifyWindowMovedToSpace: not on target",
                level: .warn,
                fields: [
                    "op": operationID,
                    "windowID": String(windowID),
                    "targetSpace": String(targetSpace),
                    "actualSpace": String(describing: windowAfter?.space)
                ]
            )
        }
        return verified
    }

    func verifyWindowMovedToSpaceWithRetry(windowID: UInt32, targetSpace: Int, operationID: String) -> Bool {
        let verified = pollUntil(timeout: 300_000, interval: 20_000) {
            self.verifyWindowMovedToSpace(windowID: windowID, targetSpace: targetSpace, operationID: operationID)
        }
        if !verified {
            log(
                "[SpaceController] moveWindow verification failed after polling",
                level: .warn,
                fields: [
                    "op": operationID,
                    "windowID": String(windowID),
                    "targetSpace": String(targetSpace)
                ]
            )
        }
        return verified
    }

    func focusWindow(_ windowID: UInt32, operationID: String? = nil) -> Bool {
        let op = operationID ?? "none"
        refreshAvailabilityIfNeeded()
        guard isEnabled else {
            return false
        }

        let beforeApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil"

        // 安全检查：验证窗口是否存在
        let windowCheck = queryWindow(windowID: windowID)
        if windowCheck == nil {
            log(
                "[SpaceController] focusWindow aborted: window does not exist",
                level: .warn,
                fields: [
                    "op": op,
                    "windowID": String(windowID)
                ]
            )
            return false
        }

        let variants = [
            ["-m", "window", "--focus", "\(windowID)"]
        ]
        let result = runYabaiVariants(variants: variants, operation: "focusWindow(\(windowID))", operationID: op)
        if result.success {
            let afterApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil"
            log(
                "[SpaceController] focusWindow completed",
                fields: [
                    "op": op,
                    "windowID": String(windowID),
                    "beforeApp": beforeApp,
                    "afterApp": afterApp,
                    "focusChanged": String(beforeApp != afterApp)
                ]
            )
            return true
        }
        markOperationError(from: result.failure, fallback: "Failed to focus window \(windowID)", operationID: op)
        return false
    }

    func pollUntil(
        timeout: useconds_t,
        interval: useconds_t = 10_000,
        condition: () -> Bool
    ) -> Bool {
        let start = Date()
        let timeoutSec = Double(timeout) / 1_000_000
        while Date().timeIntervalSince(start) < timeoutSec {
            if condition() { return true }
            usleep(interval)
        }
        return condition()
    }

    func displayVisibleSpace(displayIndex: Int?) -> Int? {
        return visibleSpaceIndex(forDisplayIndex: displayIndex)
    }
}
