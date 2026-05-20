import AppKit
import Foundation

@MainActor
extension WindowManager {

    func focusedWindow(for pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef)
        guard status == .success, let windowRef else {
            log(
                "[WindowManager] focusedWindow: AX query failed",
                level: .debug,
                fields: [
                    "pid": String(pid),
                    "axStatus": String(status.rawValue)
                ]
            )
            return nil
        }
        return unsafeBitCast(windowRef, to: AXUIElement.self)
    }

    func validateWindowExists(windowID: UInt32?) -> Bool {
        guard let windowID else { return false }
        log(
            "[WindowManager] validateWindowExists called",
            level: .debug,
            fields: ["windowID": String(windowID)]
        )
        let options = CGWindowListOption(arrayLiteral: .optionAll)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            log(
                "[WindowManager] validateWindowExists: CGWindowList returned nil",
                level: .debug,
                fields: ["windowID": String(windowID)]
            )
            return false
        }
        let exists = windowList.contains { window in
            (window[kCGWindowNumber as String] as? UInt32) == windowID
        }
        log(
            "[WindowManager] validateWindowExists result",
            level: .debug,
            fields: ["windowID": String(windowID), "exists": String(exists)]
        )
        return exists
    }

    func findWindowByPID(_ pid: pid_t, windowID: UInt32?) -> AXUIElement? {
        guard let windowID else { return nil }
        log(
            "[WindowManager] findWindowByPID called",
            level: .debug,
            fields: ["pid": String(pid), "windowID": String(windowID)]
        )
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard status == .success, let windows = windowsRef as? [AXUIElement] else {
            log(
                "[WindowManager] findWindowByPID: AX windows query failed",
                level: .debug,
                fields: ["pid": String(pid), "axStatus": String(status.rawValue)]
            )
            return nil
        }
        let found = windows.first { window in
            windowHandle(for: window) == windowID
        }
        log(
            "[WindowManager] findWindowByPID result",
            level: .debug,
            fields: [
                "pid": String(pid),
                "windowID": String(windowID),
                "windowsChecked": String(windows.count),
                "found": String(found != nil)
            ]
        )
        return found
    }
}
