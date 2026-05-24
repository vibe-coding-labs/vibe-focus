import Foundation
import Cocoa

// MARK: - Restore Logic (Simplified)
//
// Design: yabai space move → float → AX frame. One shot, no retries.
// The old mechanism had 4 strategies, polling loops, a watchdog, and 642 lines
// to do what these 3 steps accomplish.

@MainActor
extension ToggleEngine {

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

        // 2. Validate origFrame is on a known screen
        let origCenter = CGPoint(x: record.origFrame.midX, y: record.origFrame.midY)
        let onScreen = NSScreen.screens.contains { $0.frame.insetBy(dx: -200, dy: -200).contains(origCenter) }
        guard onScreen else {
            log("[ToggleEngine] restore: origFrame off-screen", level: .warn, fields: [
                "traceID": trace, "origFrame": "\(record.origFrame)"
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

        // 4. Move to original space via yabai (one shot)
        let moved = sc.moveWindow(
            axLookupID,
            toSpace: .yabai(record.sourceSpace),
            focus: triggerSource == "carbon_hotkey",
            operationID: trace
        )

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
