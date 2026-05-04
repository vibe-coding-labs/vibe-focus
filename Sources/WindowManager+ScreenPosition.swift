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
        guard let mainScreen = getMainScreen() else {
            log(
                "[WindowManager] isWindowOnMainScreen: no main screen",
                level: .debug
            )
            return false
        }
        let mainScreenFrame = mainScreen.frame

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
            let windowFrame = CGRect(
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0
            )
            let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
            let onMainScreen = mainScreenFrame.contains(center)
            log(
                "[WindowManager] isWindowOnMainScreen result",
                level: .debug,
                fields: [
                    "windowID": String(windowID),
                    "onMainScreen": String(onMainScreen),
                    "windowCenterX": "\(center.x)",
                    "windowCenterY": "\(center.y)"
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
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else {
            return nil
        }
        return number.uint32Value
    }

    func displayIndex(forDisplayID displayID: UInt32?) -> Int? {
        guard let displayID else {
            return nil
        }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.enumerated().first(where: { _, screen in
            guard let number = screen.deviceDescription[key] as? NSNumber else {
                return false
            }
            return number.uint32Value == displayID
        })?.offset
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
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        for (index, screen) in NSScreen.screens.enumerated() {
            let displayFrame = screen.frame
            if displayFrame.contains(center) || displayFrame.intersects(frame) {
                let displayID = (screen.deviceDescription[key] as? NSNumber)?.uint32Value
                log(
                    "[WindowManager] displayContext matched screen",
                    level: .debug,
                    fields: [
                        "index": String(index),
                        "displayID": String(describing: displayID)
                    ]
                )
                return (index, displayID)
            }
        }
        log(
            "[WindowManager] displayContext: no screen matched frame",
            level: .debug
        )
        return (nil, nil)
    }

    func axFrame(forVisibleFrameOf screen: NSScreen) -> CGRect {
        let visibleFrame = screen.visibleFrame
        // 使用当前屏幕的 frame.maxY 进行坐标转换
        let screenMaxY = screen.frame.maxY
        return CGRect(
            x: visibleFrame.origin.x,
            y: screenMaxY - visibleFrame.maxY,
            width: visibleFrame.width,
            height: visibleFrame.height
        )
    }

    func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= frameTolerance &&
        abs(lhs.origin.y - rhs.origin.y) <= frameTolerance &&
        abs(lhs.width - rhs.width) <= frameTolerance &&
        abs(lhs.height - rhs.height) <= frameTolerance
    }

}
