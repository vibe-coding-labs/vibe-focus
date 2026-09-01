import SwiftUI
import AppKit
import ApplicationServices.HIServices
import Foundation

// MARK: - Screen Position
// 屏幕检测、frame 计算、窗口位置判断
@MainActor
extension WindowManager {

    /// Check whether a window (by CGWindowID) is currently on the main screen.
    ///
    /// Uses CGWindowList (non-blocking) instead of AX to avoid cross-screen stalls.
    /// Called by toggle decision logic and hook pre-checks.
    ///
    /// - Parameter windowID: The CGWindowID of the window to check
    /// - Returns: true if the window's bounds overlap the main screen
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

    /// Resolve which display a given frame belongs to, returning both array index and CGDisplayID.
    ///
    /// Iterates NSScreen.screens to find the screen containing the frame's center point.
    /// Used by toggle/restore to determine source and target displays.
    ///
    /// - Parameter frame: The window frame to locate
    /// - Returns: Tuple of (screen array index, CGDisplayID), either may be nil if no match
    /// 判定 Quartz frame 所属显示器。
    ///
    /// ## 场景
    /// - saveToggleRecordForMainMove 的 sourceDisplay 派生兜底（yabai 拿不到 sourceDisplayIndex 时）；
    /// - displayID(for:)。
    ///
    /// ## 坐标约定（2.16a 第十三刀修正）
    /// - 入参 frame 是 Quartz 坐标（CGWindowList）；NSScreen.frame 是 Cocoa 坐标。
    ///   必须先做全局 Quartz→Cocoa 变换（cocoaY = 主屏高 − quartzY）再比较——
    ///   此前直接比 Quartz 点，仅主屏和与主屏垂直对齐的副屏碰巧正确，
    ///   纵向偏移副屏永远 miss（Quartz 负 y 段 vs Cocoa 正 y 段）。
    /// - 返回的 index 是 yabai display index（1-based，主屏=1），
    ///   经 CoordinateKit.yabaiDisplayIndex(for:) 派生；此前返回 NSScreen 数组
    ///   0-based 下标，消费端按 yabai 索引写入审计列时倒置（副屏记成主屏）。
    func displayContext(for frame: CGRect) -> (yabaiIndex: Int?, displayID: UInt32?) {
        // P-INST-215: 显示器上下文解析耗时（NSScreen.screens.count + enumerated 遍历 contains/intersects + CoordinateKit.cgDisplayID；toggle 路径确定窗口所在屏，NSScreen.screens 可能阻塞；slow-op ≥30ms warn）。
        #if PERF_INSTRUMENT
        let dcStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: dcStart)
            if durMs >= 30 { log("[WindowManager] displayContext slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        #endif
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
        // 全局 Quartz→Cocoa 变换（变换常量恒为主屏高，与点在哪块屏无关）
        let cocoaFrame = CGRect(
            x: frame.origin.x,
            y: CoordinateKit.mainScreenHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        let cocoaCenter = CGPoint(x: cocoaFrame.midX, y: cocoaFrame.midY)
        for (screenIndex, screen) in NSScreen.screens.enumerated() {
            if screen.frame.contains(cocoaCenter) || screen.frame.intersects(cocoaFrame) {
                let yabaiIndex = CoordinateKit.yabaiDisplayIndex(for: screen)
                let dID = CoordinateKit.cgDisplayID(for: screen)
                log(
                    "[WindowManager] displayContext matched screen",
                    level: .debug,
                    fields: [
                        "screenArrayIndex": String(screenIndex),
                        "yabaiIndex": String(describing: yabaiIndex),
                        "displayID": String(describing: dID)
                    ]
                )
                return (yabaiIndex, dID)
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

    /// 根据窗口 frame 确定所在屏幕的 Display ID
    func displayID(for frame: CGRect) -> UInt32? {
        let context = displayContext(for: frame)
        return context.displayID
    }

}
