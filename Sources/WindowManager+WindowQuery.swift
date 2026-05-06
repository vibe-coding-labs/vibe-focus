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

    func restoreWindow(using token: WindowToken) -> AXUIElement? {
        log(
            "[WindowManager] restoreWindow called",
            level: .debug,
            fields: [
                "stateID": token.stateID,
                "pid": String(token.pid),
                "bundleID": token.bundleIdentifier ?? "nil",
                "windowID": String(describing: token.windowID),
                "title": truncateForLog(token.title ?? "", limit: 60)
            ]
        )
        // 第一级匹配：通过 windowID 匹配当前聚焦窗口
        if let focused = focusedWindow(for: token.pid),
           let currentWindowID = windowHandle(for: focused),
           currentWindowID == token.windowID {
            log("Restoring using focused window handle match")
            return focused
        }

        // 第二级匹配：通过 windowID 匹配缓存的窗口引用（先验证有效性）
        if let lastWindowElement {
            if isValidAXElement(lastWindowElement),
               let currentWindowID = windowHandle(for: lastWindowElement),
               currentWindowID == token.windowID {
                log("Restoring using saved AX handle match")
                return lastWindowElement
            } else {
                // 缓存的 AX 元素已失效，立即清除
                log("Cached AX element is stale, clearing", level: .warn, fields: [
                    "tokenWindowID": String(describing: token.windowID)
                ])
                self.lastWindowElement = nil
                if let stateID = lastWindowToken?.stateID {
                    windowElementsByStateID.removeValue(forKey: stateID)
                }
            }
        }

        // 第二级-B：主动按 PID 遍历所有窗口查找匹配 windowID
        // 这解决了 hook 路径中 hydrateMemory(window:nil) 导致缓存元素过期的问题
        if let resolvedByPID = findWindowByPID(token.pid, windowID: token.windowID) {
            log("Restoring using PID-based window enumeration")
            return resolvedByPID
        }

        // 第三级匹配：备用匹配（PID + 标题 + 大致位置）
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           let focused = focusedWindow(for: frontApp.processIdentifier),
           let currentTitle = title(of: focused),
           let currentFrame = frame(of: focused),
           let lastTarget = lastTargetFrame {
            // 检查当前窗口是否匹配 token 的描述
            let pidMatches = frontApp.processIdentifier == token.pid
            let titleMatches = (token.title ?? "") == currentTitle
            let positionMatches = abs(currentFrame.origin.x - lastTarget.origin.x) <= 50 &&
                                 abs(currentFrame.origin.y - lastTarget.origin.y) <= 50

            if pidMatches && titleMatches && positionMatches {
                log("Restoring using fallback matching (PID+title+position)")
                return focused
            }
        }

        log(
            "[WindowManager] restoreWindow: no match found at any level",
            level: .debug,
            fields: [
                "stateID": token.stateID,
                "windowID": String(describing: token.windowID)
            ]
        )
        return nil
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
