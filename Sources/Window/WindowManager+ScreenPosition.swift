import SwiftUI
import AppKit
import ApplicationServices.HIServices
import Foundation

// MARK: - Screen Position
// 屏幕检测、frame 计算、窗口位置判断
@MainActor
extension WindowManager {

    func isWindowOnMainScreen(windowID: UInt32) -> Bool {
        log(
            "[WindowManager] isWindowOnMainScreen called",
            level: .debug,
            fields: ["windowID": String(windowID)]
        )
        let options = CGWindowListOption(arrayLiteral: .optionAll)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            log(
                "[WindowManager] isWindowOnMainScreen: CGWindowList returned nil",
                level: .debug
            )
            return false
        }

        for info in windowList {
            guard let id = info[kCGWindowNumber as String] as? UInt32,
                  id == windowID else { continue }
            let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
            guard let bounds else {
                log(
                    "[WindowManager] isWindowOnMainScreen: no bounds for window",
                    level: .debug,
                    fields: ["windowID": String(windowID)]
                )
                return false
            }
            // CGWindowList 返回 Quartz 坐标 — 直接用 CoordinateKit 判断
            let windowFrame = CGRect(
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0
            )
            let onMainScreen = CoordinateKit.isOnMainScreen(windowFrame)
            log(
                "[WindowManager] isWindowOnMainScreen result",
                level: .debug,
                fields: [
                    "windowID": String(windowID),
                    "onMainScreen": String(onMainScreen),
                    "windowCenterX": "\(windowFrame.midX)",
                    "windowCenterY": "\(windowFrame.midY)"
                ]
            )
            return onMainScreen
        }
        log(
            "[WindowManager] isWindowOnMainScreen: window not found in list",
            level: .debug,
            fields: ["windowID": String(windowID)]
        )
        return false
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
