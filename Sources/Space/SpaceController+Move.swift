import AppKit
import Foundation

@MainActor
extension SpaceController {

    func moveWindow(_ windowID: UInt32, toSpace space: SpaceIdentifier, focus: Bool, operationID: String? = nil) -> Bool {
        let op = operationID ?? "none"
        guard let spaceIndex = space.yabaiIndex else {
            log("[SpaceController] moveWindow: unsupported space identifier", level: .warn, fields: ["op": op])
            return false
        }
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
            return false
        }
        guard canControlSpaces else {
            markOperationError("Cannot move window to another space because cross-space control is unavailable", operationID: op)
            return false
        }

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

        let nativeAvailable = NativeSpaceBridge.isAvailable

        // 策略 1：使用 NativeSpaceBridge (CGS API) 直接移动
        NativeSpaceBridge.resetFailureCache()
        if nativeAvailable, let spaceID = nativeSpaceID(forYabaiIndex: spaceIndex) {
            if NativeSpaceBridge.moveWindow(windowID, toSpaceID: spaceID) {
                usleep(80_000)
                if verifyWindowMovedToSpace(windowID: windowID, targetSpace: spaceIndex, operationID: op) {
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
        let moveResult = runYabaiVariants(
            variants: [["-m", "window", "\(windowID)", "--space", "\(spaceIndex)"]],
            operation: "moveWindow(windowID=\(windowID), space=\(spaceIndex))",
            operationID: op
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
                    var verified = false
                    for _ in 1...8 {
                        usleep(150_000)
                        if verifyWindowMovedToSpace(windowID: windowID, targetSpace: spaceIndex, operationID: op) {
                            verified = true
                            break
                        }
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
            if focusThenMoveRetry(windowID: windowID, targetSpace: spaceIndex, focus: focus, operationID: op, label: "unverified") {
                return true
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
        if focusThenMoveRetry(windowID: windowID, targetSpace: spaceIndex, focus: focus, operationID: op, label: "fallback") {
            return true
        }

        markOperationError(
            from: moveResult.failure,
            fallback: "Failed to move window \(windowID) to space \(spaceIndex)",
            operationID: op
        )
        return false
    }

    // MARK: - Focus-Then-Move Retry

    private func focusThenMoveRetry(
        windowID: UInt32,
        targetSpace: Int,
        focus: Bool,
        operationID: String,
        label: String
    ) -> Bool {
        let focusResult = runYabai(
            arguments: ["-m", "space", "--focus", "\(targetSpace)"],
            operation: "moveWindow_focusTargetSpace_\(label)",
            operationID: operationID
        )
        guard let result = focusResult, result.exitCode == 0 else { return false }

        _ = pollUntil(timeout: 200_000, interval: 20_000) {
            self.windowSpaceIndex(windowID: windowID)?.yabaiIndex == targetSpace
        }
        let retryResult = runYabai(
            arguments: ["-m", "window", "\(windowID)", "--space", "\(targetSpace)"],
            operation: "moveWindow_focusRetry_\(label)",
            operationID: operationID
        )
        guard let retry = retryResult, retry.exitCode == 0 else { return false }

        if verifyWindowMovedToSpaceWithRetry(windowID: windowID, targetSpace: targetSpace, operationID: operationID) {
            log("[SpaceController] focus-then-move succeeded (\(label))", fields: [
                "op": operationID, "windowID": String(windowID), "targetSpace": String(targetSpace)
            ])
            if focus {
                _ = focusWindow(windowID, operationID: operationID)
            }
            return true
        }
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
        let startTime = Date()
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
                    "targetSpace": String(targetSpace),
                    "elapsedMs": String(elapsedMilliseconds(since: startTime))
                ]
            )
        }
        return verified
    }

    func setWindowFloat(_ windowID: UInt32, operationID: String? = nil) {
        let op = operationID ?? "none"
        guard isEnabled else { return }

        if let info = queryWindow(windowID: windowID) {
            if info.isFloating {
                return
            }
        } else {
            log("setWindowFloat: queryWindow returned nil, skipping toggle", level: .warn, fields: [
                "op": op,
                "windowID": String(windowID)
            ])
            return
        }

        _ = runYabai(
            arguments: ["-m", "window", "\(windowID)", "--toggle", "float"],
            operation: "setWindowFloat",
            operationID: op
        )
    }

    func focusWindow(_ windowID: UInt32, operationID: String? = nil) -> Bool {
        let op = operationID ?? "none"
        refreshAvailabilityIfNeeded()
        guard isEnabled else {
            return false
        }

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

    func displayVisibleSpace(displayIndex: DisplayIdentifier?) -> SpaceIdentifier? {
        guard let idx = displayIndex?.yabaiIndex else { return nil }
        return visibleSpaceIndex(forDisplayIndex: idx)
    }
}
