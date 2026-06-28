import SwiftUI
import AppKit
import ApplicationServices.HIServices
import Foundation

// MARK: - Screen Position
// 屏幕检测、frame 计算、窗口位置判断
@MainActor
extension WindowManager {

    func isWindowOnMainScreen(windowID: UInt32) -> Bool {
        // P-INST-61: isWindowOnMainScreen 耗时（cgWindowListAll P-INST-45 + CoordinateKit.isOnMainScreen；hook 预检 P-INST-47 + toggle 路径调用）。
        let iwomsStart = Date()
        var onMain = false
        defer {
            log("[WindowManager] isWindowOnMainScreen finished", level: .debug, fields: [
                "windowID": String(windowID),
                "onMain": String(onMain),
                "durationMs": String(elapsedMilliseconds(since: iwomsStart))
            ])
        }
        let windows = cgWindowListAll()
        guard let entry = windows.first(where: { $0.windowID == windowID }) else {
            return false
        }
        guard let bounds = entry.bounds else {
            return false
        }
        onMain = CoordinateKit.isOnMainScreen(bounds)
        return onMain
    }

    /// 通过 CGWindowList 读取窗口 frame（非 AX，不跨屏阻塞）。
    /// 用于 toggle ctxMs 采集，替代 AX frame(of:) —— 窗口位于副屏 Space 时
    /// AX kAXFrameAttribute 被 WindowServer 阻塞 1500-1900ms（move_to_main ctxMs 主因，
    /// 见 toggle-00000187 ctxMs=1918）。CGWindowListCopyWindowInfo 是 WindowServer 快照查询，
    /// 不走 AX 通道，不阻塞。
    func cgWindowFrame(forWindowID windowID: UInt32) -> CGRect? {
        // P-INST-181: 按 windowID 读 CGWindowList 帧耗时（cgWindowListAll 全扫 P-INST-45 + first(where:) 匹配 windowID；toggle/restore 热路径 frame 读取，按 memory feedback_toggle_ctxms_cgwindowlist 铁律必须用 CGWindowList 而非 AX frame(of:)）。
        let cgfStart = Date()
        let frame: CGRect? = {
            let windows = cgWindowListAll()
            guard let entry = windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }
            return entry.bounds
        }()
        let durMs = elapsedMilliseconds(since: cgfStart)
        if durMs >= 30 {
            log("[WindowManager] cgWindowFrame slow", level: .warn, fields: ["windowID": String(windowID), "durationMs": String(durMs)])
        }
        return frame
    }

    func displayID(for screen: NSScreen) -> UInt32? {
        return CoordinateKit.cgDisplayID(for: screen)
    }

    func displayIndex(forDisplayID displayID: UInt32?) -> Int? {
        guard let displayID else {
            return nil
        }
        guard let screen = CoordinateKit.nsScreen(forCGDisplayID: displayID) else {
            return nil
        }
        return CoordinateKit.screenArrayIndex(for: screen)
    }

    func displayContext(for frame: CGRect) -> (index: Int?, displayID: UInt32?) {
        // P-INST-215: 显示器上下文解析耗时（NSScreen.screens.count + enumerated 遍历 contains/intersects + CoordinateKit.cgDisplayID；toggle 路径确定窗口所在屏，NSScreen.screens 可能阻塞；slow-op ≥30ms warn）。
        let dcStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: dcStart)
            if durMs >= 30 { log("[WindowManager] displayContext slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        log(
            "[WindowManager] displayContext called",
            level: .debug,
            fields: [
                "frame": String(describing: frame),
                "centerX": "\(frame.midX)",
                "centerY": "\(frame.midY)",
                "screenCount": String(NSScreen.screens.count)
            ]
        )
        let center = CGPoint(x: frame.midX, y: frame.midY)
        for (index, screen) in NSScreen.screens.enumerated() {
            if screen.frame.contains(center) || screen.frame.intersects(frame) {
                let dID = CoordinateKit.cgDisplayID(for: screen)
                log(
                    "[WindowManager] displayContext matched screen",
                    level: .debug,
                    fields: [
                        "index": String(index),
                        "displayID": String(describing: dID)
                    ]
                )
                return (index, dID)
            }
        }
        log(
            "[WindowManager] displayContext: no screen matched frame",
            level: .debug
        )
        return (nil, nil)
    }

    func axFrame(forVisibleFrameOf screen: NSScreen) -> CGRect {
        return CoordinateKit.quartzVisibleFrame(of: screen)
    }

    func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= frameTolerance &&
        abs(lhs.origin.y - rhs.origin.y) <= frameTolerance &&
        abs(lhs.width - rhs.width) <= frameTolerance &&
        abs(lhs.height - rhs.height) <= frameTolerance
    }

    /// 根据窗口 frame 确定所在屏幕的 Display ID
    func displayID(for frame: CGRect) -> UInt32? {
        let context = displayContext(for: frame)
        return context.displayID
    }

}
