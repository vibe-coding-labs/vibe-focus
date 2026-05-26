import Foundation
import Cocoa

// MARK: - Restore Logic (Simplified)
//
// Design: yabai space move → float → AX frame. One shot, no retries.
// The old mechanism had 4 strategies, polling loops, a watchdog, and 642 lines
// to do what these 3 steps accomplish.

@MainActor
extension ToggleEngine {

    /// Pure decision: which record to use for restore?
    /// Returns record or nil if not found. No PID fallback — same-PID windows
    /// (e.g. all iTerm2 windows) would return the wrong record.
    static func resolveRestoreRecord(
        windowID: UInt32,
        loadByWindowID: (UInt32) -> ToggleRecord?
    ) -> ToggleRecord? {
        return loadByWindowID(windowID)
    }

    @discardableResult
    func restore(windowID: UInt32, triggerSource: String, traceID: String? = nil) -> Bool {
        let trace = traceID ?? makeOperationID(prefix: "te")

        // 1. Load record — windowID only, no PID fallback
        guard let record = load(windowID: windowID) else {
            log("[ToggleEngine] restore: no toggle record", level: .warn, fields: [
                "traceID": trace, "windowID": String(windowID)
            ])
            return false
        }

        let wm = WindowManager.shared
        let sc = SpaceController.shared

        // 3. Resolve AX window
        let axLookupID = (record.windowID != windowID) ? windowID : record.windowID
        guard let windowAX = wm.findWindowByPID(record.pid, windowID: axLookupID) else {
            log("[ToggleEngine] restore: AX window not found", level: .warn, fields: [
                "traceID": trace, "windowID": String(windowID), "pid": String(record.pid)
            ])
            return false
        }

        log("[ToggleEngine] restore: starting", fields: [
            "traceID": trace,
            "windowID": String(windowID),
            "recordWindowID": String(record.windowID),
            "pid": String(record.pid),
            "sourceSpace": String(record.sourceSpace),
            "triggerSource": triggerSource,
            "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y)) \(Int(record.origFrame.width))x\(Int(record.origFrame.height))",
            "targetFrame": "\(Int(record.targetFrame.origin.x)),\(Int(record.targetFrame.origin.y)) \(Int(record.targetFrame.width))x\(Int(record.targetFrame.height))"
        ])

        // 4. Move to original space via yabai (skip if sourceSpace=0 — no space info available)
        var moved = false
        if record.sourceSpace > 0 {
            moved = sc.moveWindow(
                axLookupID,
                toSpace: .yabai(record.sourceSpace),
                focus: triggerSource == "carbon_hotkey",
                operationID: trace
            )
            log("[ToggleEngine] restore: space move result", fields: [
                "traceID": trace, "moved": String(moved), "sourceSpace": String(record.sourceSpace)
            ])
        } else {
            log("[ToggleEngine] restore: sourceSpace=0, skipping yabai space move (no space info)", fields: [
                "traceID": trace, "windowID": String(windowID)
            ])
        }

        // 5. Float on target space — prevents yabai from tiling
        sc.setWindowFloat(axLookupID, operationID: trace)

        // 6. Apply original frame via AX
        if !wm.apply(frame: record.origFrame, to: windowAX, operationID: trace, stage: "restore") {
            log("[ToggleEngine] restore: AX frame apply failed", level: .warn, fields: [
                "traceID": trace, "windowID": String(windowID)
            ])
        }

        // 7. Clear record
        clear(windowID: record.windowID)

        log("[ToggleEngine] restore: completed", fields: [
            "traceID": trace,
            "windowID": String(windowID),
            "targetSpace": String(record.sourceSpace),
            "spaceMoveResult": String(moved),
            "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y))"
        ])

        AuditLogger.shared.record(
            eventType: "restore_success",
            windowID: windowID,
            pid: record.pid,
            details: ["triggerSource": triggerSource, "targetSpace": String(record.sourceSpace)]
        )

        return true
    }
}
