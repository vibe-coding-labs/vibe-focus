import Foundation
import Cocoa

// MARK: - Restore Logic (Simplified)
//
// Design: yabai space move → float → AX frame. One shot, no retries.
// The old mechanism had 4 strategies, polling loops, a watchdog, and 642 lines
// to do what these 3 steps accomplish.

@MainActor
extension ToggleEngine {

    /// Pure decision: which record to use for restore, and which window ID to look up?
    /// Returns (record, axLookupWindowID) or nil if no record found.
    static func resolveRestoreRecord(
        windowID: UInt32,
        fallbackPID: Int32?,
        loadByWindowID: (UInt32) -> ToggleRecord?,
        loadByPID: (Int32) -> ToggleRecord?
    ) -> (record: ToggleRecord, axLookupID: UInt32)? {
        var record = loadByWindowID(windowID)
        if record == nil, let pid = fallbackPID {
            record = loadByPID(pid)
        }
        guard let record else { return nil }
        let axLookupID = (record.windowID != windowID) ? windowID : record.windowID
        return (record, axLookupID)
    }

    @discardableResult
    func restore(windowID: UInt32, fallbackPID: Int32? = nil, triggerSource: String, traceID: String? = nil) -> Bool {
        let trace = traceID ?? makeOperationID(prefix: "te")

        // 1. Load record (PID fallback for CGWindowNumber instability)
        var record = load(windowID: windowID)
        if record == nil, let pid = fallbackPID {
            record = loadByPID(pid: pid)
        }
        guard let record else {
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
            "sourceSpace": String(record.sourceSpace),
            "triggerSource": triggerSource,
            "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y)) \(Int(record.origFrame.width))x\(Int(record.origFrame.height))"
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
