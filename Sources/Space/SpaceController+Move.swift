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
            details: ["targetSpace": String(spaceIndex), "focus": String(focus), "op": op]
        )
        refreshAvailabilityIfNeeded()
        guard isEnabled else { return false }
        guard canControlSpaces else {
            markOperationError("Cannot move window to another space because cross-space control is unavailable", operationID: op)
            return false
        }

        guard queryWindow(windowID: windowID) != nil else {
            log("[SpaceController] moveWindow aborted: window does not exist", level: .warn, fields: [
                "op": op, "windowID": String(windowID), "targetSpace": String(spaceIndex)
            ])
            return false
        }

        // Strategy 1: yabai command
        let result = runYabaiVariants(
            variants: [["-m", "window", "\(windowID)", "--space", "\(spaceIndex)"]],
            operation: "moveWindow(windowID=\(windowID), space=\(spaceIndex))",
            operationID: op
        )
        if result.success {
            if focus { _ = focusWindow(windowID, operationID: op) }
            return true
        }

        // Strategy 2: NativeSpaceBridge fallback
        if NativeSpaceBridge.isAvailable, let spaceID = nativeSpaceID(forYabaiIndex: spaceIndex) {
            NativeSpaceBridge.resetFailureCache()
            if NativeSpaceBridge.moveWindow(windowID, toSpaceID: spaceID) {
                if focus { _ = focusWindow(windowID, operationID: op) }
                return true
            }
        }

        markOperationError(from: result.failure, fallback: "Failed to move window \(windowID) to space \(spaceIndex)", operationID: op)
        return false
    }

    func setWindowFloat(_ windowID: UInt32, operationID: String? = nil) {
        let op = operationID ?? "none"
        guard isEnabled else { return }

        if let info = queryWindow(windowID: windowID) {
            if info.isFloating { return }
        } else {
            log("setWindowFloat: queryWindow returned nil, skipping toggle", level: .warn, fields: [
                "op": op, "windowID": String(windowID)
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
        guard isEnabled else { return false }

        guard queryWindow(windowID: windowID) != nil else {
            log("[SpaceController] focusWindow aborted: window does not exist", level: .warn, fields: [
                "op": op, "windowID": String(windowID)
            ])
            return false
        }

        let result = runYabaiVariants(
            variants: [["-m", "window", "--focus", "\(windowID)"]],
            operation: "focusWindow(\(windowID))",
            operationID: op
        )
        if result.success { return true }
        markOperationError(from: result.failure, fallback: "Failed to focus window \(windowID)", operationID: op)
        return false
    }

    func displayVisibleSpace(displayIndex: DisplayIdentifier?) -> SpaceIdentifier? {
        guard let idx = displayIndex?.yabaiIndex else { return nil }
        return visibleSpaceIndex(forDisplayIndex: idx)
    }
}
