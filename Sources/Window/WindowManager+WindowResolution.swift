import AppKit
import ApplicationServices.HIServices
import Foundation

// MARK: - AX 窗口解析层
// 把 WindowIdentity（弱引用身份：windowID/pid/windowNumber/title）重新解析回活的
// AXUIElement。唯一调用方是 moveWindowToMainScreen 的 P2 yabai 路径（窗口被 yabai
// space move 到主屏后，AX 不再被副屏阻塞，此时解析安全）。

@MainActor
extension WindowManager {

    /// 按身份解析 AXUIElement，四级匹配路径按代价递增。
    ///
    /// ## 场景
    /// - moveWindowToMainScreen P2 yabai 路径：yabai space move 之后调用；
    /// - 窗口此时已在主屏 space，AX fast path（focused 比对）应命中；窗口被 app 重排
    ///   导致 windowID 失配时逐级退化到全量遍历/编号/标题匹配。
    ///
    /// ## 匹配样例
    /// ```
    /// fast        : focused(windowID==目标) 命中，2 次 AX
    /// exactID_scan: kAXWindowsAttribute 全量遍历比 windowID（可阻塞，≥50ms 有埋点）
    /// windowNumber: CGWindowNumber 匹配（标题变动时比 title 稳）
    /// title       : trim 后精确匹配标题（最后兜底，标题变了即失配）
    /// ```
    func resolveWindow(identity: WindowIdentity) -> AXUIElement? {
        // P-INST-24: resolveWindow 耗时 + 命中路径（P2 yabai 路径调用，窗口已主屏 space，fast path 应命中；
        // exactID_scan 全量 kAXWindowsAttribute 遍历可能阻塞，归因 fast path miss 的成本）。
        let rwStart = Date()
        let pid = pid_t(identity.pid)
        if let focused = focusedWindow(for: pid),
           let focusedID = windowHandle(for: focused),
           focusedID == identity.windowID {
            log("[WindowManager] resolveWindow result", level: .debug, fields: [
                "windowID": String(identity.windowID), "path": "fast", "found": "true",
                "durationMs": String(elapsedMilliseconds(since: rwStart))
            ])
            return focused
        }

        let windows = allWindows(for: pid)
        if let exactID = windows.first(where: { window in
            guard let currentID = windowHandle(for: window) else { return false }
            return currentID == identity.windowID
        }) {
            log("[WindowManager] resolveWindow result", level: .debug, fields: [
                "windowID": String(identity.windowID), "path": "exactID_scan", "found": "true",
                "windowsChecked": String(windows.count),
                "durationMs": String(elapsedMilliseconds(since: rwStart))
            ])
            return exactID
        }

        if let number = identity.windowNumber,
           let matched = windows.first(where: { windowNumber(for: $0) == number }) {
            log("[WindowManager] resolveWindow result", level: .debug, fields: [
                "windowID": String(identity.windowID), "path": "windowNumber", "found": "true",
                "durationMs": String(elapsedMilliseconds(since: rwStart))
            ])
            return matched
        }

        if let expectedTitle = identity.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !expectedTitle.isEmpty,
           let matched = windows.first(where: {
               self.title(of: $0)?.trimmingCharacters(in: .whitespacesAndNewlines) == expectedTitle
           }) {
            log("[WindowManager] resolveWindow result", level: .debug, fields: [
                "windowID": String(identity.windowID), "path": "title", "found": "true",
                "durationMs": String(elapsedMilliseconds(since: rwStart))
            ])
            return matched
        }

        log("[WindowManager] resolveWindow result", level: .debug, fields: [
            "windowID": String(identity.windowID), "path": "none", "found": "false",
            "durationMs": String(elapsedMilliseconds(since: rwStart))
        ])
        return nil
    }

    /// AX 全量窗口枚举（kAXWindowsAttribute），resolveWindow 的退化路径数据源。
    /// internal：仅 resolveWindow 调用；AX 全量遍历可阻塞，勿在热路径直接使用。
    private func allWindows(for pid: pid_t) -> [AXUIElement] {
        // P-INST-46: AX 全量窗口枚举耗时（kAXWindowsAttribute；resolveWindow 退化路径，AX 可阻塞；slow-op ≥50ms warn）。
        #if PERF_INSTRUMENT
        let allWinStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: allWinStart)
            if durMs >= 50 {
                log("[WindowManager] allWindows slow AX", level: .warn, fields: ["pid": String(pid), "durationMs": String(durMs)])
            }
        }
        #endif
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard status == .success, let windowsRef else { return [] }
        return windowsRef as? [AXUIElement] ?? []
    }
}
