import SwiftUI
import AppKit
import ApplicationServices.HIServices
import Foundation

// MARK: - Window Move Operations
@MainActor
extension WindowManager {

    func runShellCommand(_ executable: String, args: [String]) -> String? {
        return ShellRunner.run(executable: executable, arguments: args)?.stdout
    }

    func resolveWindow(identity: WindowIdentity) -> AXUIElement? {
        let pid = pid_t(identity.pid)
        if let focused = focusedWindow(for: pid),
           let focusedID = windowHandle(for: focused),
           focusedID == identity.windowID {
            return focused
        }

        let windows = allWindows(for: pid)
        if let exactID = windows.first(where: { window in
            guard let currentID = windowHandle(for: window) else { return false }
            return currentID == identity.windowID
        }) {
            return exactID
        }

        if let number = identity.windowNumber,
           let matched = windows.first(where: { windowNumber(for: $0) == number }) {
            return matched
        }

        if let expectedTitle = identity.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !expectedTitle.isEmpty,
           let matched = windows.first(where: {
               self.title(of: $0)?.trimmingCharacters(in: .whitespacesAndNewlines) == expectedTitle
           }) {
            return matched
        }

        return windows.first
    }

    @discardableResult
    func moveWindowToMainScreen(
        identity: WindowIdentity,
        reason: WindowMoveReason,
        sessionID: String?,
        operationID: String? = nil
    ) -> Bool {
        let op = operationID ?? makeOperationID(prefix: "move")
        let startedAt = Date()
        log("[WindowManager] moveWindowToMainScreen started", fields: [
            "op": op,
            "windowID": String(identity.windowID),
            "pid": String(identity.pid),
            "reason": reason.rawValue,
            "sessionID": sessionID ?? "nil"
        ])

        guard hasAccessibilityPermission() else {
            log("moveWindowToMainScreen failed: accessibility not granted", level: .error, fields: ["op": op])
            notifyAccessibilityPermissionRequired()
            return false
        }

        guard let windowAX = resolveWindow(identity: identity) else {
            log("moveWindowToMainScreen failed: cannot resolve window", level: .error, fields: ["op": op])
            return false
        }

        guard let origFrame = frame(of: windowAX) else {
            log("moveWindowToMainScreen failed: cannot read current frame", level: .error, fields: ["op": op])
            return false
        }

        // Skip if already on main screen
        let yabaiDisplay = spaceController.windowDisplayIndex(windowID: identity.windowID)
        if let display = yabaiDisplay?.yabaiIndex, display == 1 {
            if let mainScreen = getMainScreen() {
                let windowCenter = CGPoint(x: origFrame.midX, y: origFrame.midY)
                if mainScreen.frame.contains(windowCenter) {
                    log("[WindowManager] moveWindowToMainScreen skipped: already on main screen", fields: [
                        "op": op, "windowID": String(identity.windowID)
                    ])
                    return true
                }
            }
        }

        guard isAttributeSettable(windowAX, attribute: kAXPositionAttribute),
              isAttributeSettable(windowAX, attribute: kAXSizeAttribute) else {
            log("moveWindowToMainScreen failed: window attributes not settable", level: .error, fields: ["op": op])
            return false
        }

        let spaceContext = spaceController.captureSpaceContext(windowID: identity.windowID, operationID: op)

        log("[WindowManager] moveWindowToMainScreen: space context captured", fields: [
            "op": op,
            "windowID": String(identity.windowID),
            "sourceSpaceIndex": spaceContext.sourceSpaceIndex.map { String(describing: $0) } ?? "nil",
            "sourceDisplayIndex": spaceContext.sourceDisplayIndex.map { String(describing: $0) } ?? "nil",
            "sourceDisplaySpaceIndex": String(spaceContext.sourceDisplaySpaceIndex ?? -1),
            "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y)) \(Int(origFrame.width))x\(Int(origFrame.height))"
        ])

        guard let mainScreen = getMainScreen() else {
            log("moveWindowToMainScreen failed: cannot determine main screen", level: .error, fields: ["op": op])
            return false
        }

        let targetFrame = axFrame(forVisibleFrameOf: mainScreen)
        let targetDisplayID = displayID(for: mainScreen)
        let targetDisplayIndex = displayIndex(forDisplayID: targetDisplayID)

        // AX apply: move window to main screen
        guard apply(frame: targetFrame, to: windowAX, operationID: op, stage: "move_to_main") else {
            log("moveWindowToMainScreen failed: AX apply failed", level: .error, fields: [
                "op": op, "targetFrame": String(describing: targetFrame)
            ])
            return false
        }

        // Float on main screen to prevent yabai tiling
        let effectiveWindowID = windowHandle(for: windowAX) ?? identity.windowID
        spaceController.setWindowFloat(effectiveWindowID, operationID: op)

        // Save toggle record — always save, even when yabai can't determine space
        // (sourceSpace=0 signals "no space info, skip yabai space move on restore")
        let actualTargetFrame = frame(of: windowAX) ?? targetFrame
        let sourceSpaceIndex = spaceContext.sourceSpaceIndex ?? .yabai(0)
        let sourceContext = displayContext(for: origFrame)
        let teSourceDisplay: DisplayIdentifier = spaceContext.sourceDisplayIndex ?? sourceContext.index.map { .yabai($0) } ?? .yabai(0)
        let postMoveWindowID = windowHandle(for: windowAX) ?? effectiveWindowID
        if postMoveWindowID != effectiveWindowID {
            SessionWindowRegistry.shared.remapWindowID(oldWindowID: effectiveWindowID, newWindowID: postMoveWindowID)
        }
        ToggleEngine.shared.save(
            windowID: postMoveWindowID,
            pid: identity.pid,
            bundleIdentifier: identity.bundleIdentifier,
            appName: identity.appName,
            origFrame: origFrame,
            sourceSpace: sourceSpaceIndex,
            sourceDisplay: teSourceDisplay,
            sourceYabaiDisp: spaceContext.sourceDisplayIndex ?? .yabai(0),
            sourceDispSpace: spaceContext.sourceDisplaySpaceIndex ?? 0,
            targetFrame: actualTargetFrame,
            targetDisplay: targetDisplayIndex ?? 0,
            sessionID: sessionID
        )

        log("[WindowManager] moveWindowToMainScreen: ToggleRecord saved", fields: [
            "op": op,
            "windowID": String(postMoveWindowID),
            "sourceSpace": String(describing: sourceSpaceIndex),
            "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y))",
            "targetFrame": "\(Int(actualTargetFrame.origin.x)),\(Int(actualTargetFrame.origin.y))",
            "reason": reason.rawValue,
            "sessionID": sessionID ?? "nil"
        ])

        log("[WindowManager] moveWindowToMainScreen finished", fields: [
            "op": op,
            "windowID": String(effectiveWindowID),
            "durationMs": String(elapsedMilliseconds(since: startedAt))
        ])
        return true
    }

    private func allWindows(for pid: pid_t) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard status == .success, let windowsRef else { return [] }
        return windowsRef as? [AXUIElement] ?? []
    }
}
