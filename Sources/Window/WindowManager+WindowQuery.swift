import AppKit
import Foundation

@MainActor
extension WindowManager {

    /// 通过 CGWindowID focus 窗口 — yabai focus 失败时的 fallback。
    /// 使用 AXUIElement raise + focus，不依赖 Carbon 私有 API。
    func focusWindowByCGWindowID(_ windowID: UInt32) -> Bool {
        // 从 CGWindowList 获取窗口的 PID
        let cgWindows = CGWindowListCopyWindowInfo(.optionAll, 0) as? [[String: Any]] ?? []
        guard let match = cgWindows.first(where: {
            ($0[kCGWindowNumber as String] as? Int) == Int(windowID)
        }), let pid = match[kCGWindowOwnerPID as String] as? pid_t else {
            log("[WindowManager] focusWindowByCGWindowID: window not found in CG list", level: .warn, fields: [
                "windowID": String(windowID)
            ])
            return false
        }

        // 找到 AX element
        guard let axWindow = findWindowByPID(pid, windowID: windowID) else {
            log("[WindowManager] focusWindowByCGWindowID: AX element not found", level: .warn, fields: [
                "windowID": String(windowID), "pid": String(pid)
            ])
            return false
        }

        // raise + focus
        _ = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        let focusResult = AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, true as CFTypeRef)
        let success = focusResult == .success
        if !success {
            log("[WindowManager] focusWindowByCGWindowID: AX focus failed", level: .warn, fields: [
                "windowID": String(windowID), "axResult": String(focusResult.rawValue)
            ])
        }
        return success
    }

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
