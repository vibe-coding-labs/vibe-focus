import AppKit
import Foundation

@MainActor
extension WindowManager {

    /// 通过 CGWindowID focus 窗口 — yabai focus 失败时的 fallback。
    /// 使用 AXUIElement raise + focus，不依赖 Carbon 私有 API。
    func focusWindowByCGWindowID(_ windowID: UInt32) -> Bool {
        // P-INST-22: focusWindowByCGWindowID 内部细分（cgListMs 非阻塞 ~5ms，axLookupMs findWindowByPID，axFocusMs AX raise+focus 可能阻塞）。
        let cgListStart = Date()
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
        let cgListMs = elapsedMilliseconds(since: cgListStart)

        // 找到 AX element
        let axLookupStart = Date()
        guard let axWindow = findWindowByPID(pid, windowID: windowID) else {
            log("[WindowManager] focusWindowByCGWindowID: AX element not found", level: .warn, fields: [
                "windowID": String(windowID), "pid": String(pid),
                "cgListMs": String(cgListMs), "axLookupMs": String(elapsedMilliseconds(since: axLookupStart))
            ])
            return false
        }
        let axLookupMs = elapsedMilliseconds(since: axLookupStart)

        // raise + focus
        let axFocusStart = Date()
        _ = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        let focusResult = AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, true as CFTypeRef)
        let axFocusMs = elapsedMilliseconds(since: axFocusStart)
        let success = focusResult == .success
        log("[WindowManager] focusWindowByCGWindowID result", level: success ? .debug : .warn, fields: [
            "windowID": String(windowID), "pid": String(pid),
            "cgListMs": String(cgListMs), "axLookupMs": String(axLookupMs), "axFocusMs": String(axFocusMs),
            "success": String(success)
        ])
        return success
    }

    func focusedWindow(for pid: pid_t) -> AXUIElement? {
        // P-INST-52: AX focusedWindow 读取耗时（kAXFocusedWindowAttribute；resolveWindow fast path / hook 路径调用，跨屏可阻塞 1-2s；slow-op ≥50ms warn）。
        let fwAxStart = Date()
        let appElement = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef)
        let fwDurMs = elapsedMilliseconds(since: fwAxStart)
        if fwDurMs >= 50 {
            log("[WindowManager] focusedWindow slow AX", level: .warn, fields: ["pid": String(pid), "durationMs": String(fwDurMs)])
        }
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
        // P-INST-21: findWindowByPID 耗时（fast path 应 <5ms，全量遍历 fallback 跨屏阻塞可 ~2s，restore gap3 归因关键）。
        let fwpStart = Date()
        log(
            "[WindowManager] findWindowByPID called",
            level: .debug,
            fields: ["pid": String(pid), "windowID": String(windowID)]
        )
        // Fast path：若该窗口是 pid 的当前聚焦窗口，直接返回，跳过全量 AX windows 遍历。
        // restore 路径中，被 restore 的窗口通常是聚焦窗口（用户刚 toggle 它到主屏再送回）。
        // 全量 kAXWindowsAttribute 遍历在 space 动画/跨屏时阻塞（实测 restore 偶发 ~2s）。
        // 聚焦窗口的精确 windowID 匹配与全量遍历结果等价（聚焦窗口必在 windows 列表内，
        // 全量遍历也会返回它）。不聚焦时 fallback 到全量遍历，行为不变。
        // 注意：这里不做 title/number fallback（区别于 resolveWindow），保持精确 windowID 匹配语义。
        if let focused = focusedWindow(for: pid),
           let focusedID = windowHandle(for: focused),
           focusedID == windowID {
            log(
                "[WindowManager] findWindowByPID: focused fast path hit",
                level: .debug,
                fields: [
                    "pid": String(pid), "windowID": String(windowID),
                    "durationMs": String(elapsedMilliseconds(since: fwpStart)),
                    "path": "fast"
                ]
            )
            return focused
        }
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
                "found": String(found != nil),
                "durationMs": String(elapsedMilliseconds(since: fwpStart)),
                "path": "fallback"
            ]
        )
        return found
    }
}
