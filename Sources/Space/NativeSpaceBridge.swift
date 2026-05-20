import AppKit
import CoreGraphics
import Foundation

/// 使用 macOS 原生 API 进行空间操作。
/// focusSpace: 通过 CGEvent 发送 Ctrl+Left/Right 键盘事件切换空间（可靠，无需私有 API）
/// moveWindow: 通过 SLS 私有 API 移动窗口到指定空间
enum NativeSpaceBridge {
    // MARK: - SLS Private API Types (only for moveWindow)

    private typealias FnMainConnectionID = @convention(c) () -> Int32
    // SLSMoveWindowsToManagedSpace 的第二个参数是 NSArray（包含 NSNumber 包装的 CGWindowID）
    // 而非 C 数组指针 — 传 C 数组会导致 SkyLight 内部 objc_msgSend("count") 崩溃
    private typealias FnMoveWindowsToManagedSpace = @convention(c) (Int32, AnyObject, Int32, Int64) -> Int32

    private static let skyLightHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    }()

    private static func load<T>(_ name: String) -> T? {
        guard let handle = skyLightHandle,
              let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    private static var fnMainConnectionID: FnMainConnectionID? { load("SLSMainConnectionID") }
    private static var fnMoveWindowsToManagedSpace: FnMoveWindowsToManagedSpace? { load("SLSMoveWindowsToManagedSpace") }
    private static var connectionID: Int32? { fnMainConnectionID?() }

    // MARK: - Availability

    static var isAvailable: Bool {
        fnMainConnectionID != nil && fnMoveWindowsToManagedSpace != nil
    }

    static func logAvailability() {
        let symbols: [(String, Any?)] = [
            ("SLSMainConnectionID", fnMainConnectionID as Any),
            ("SLSMoveWindowsToManagedSpace", fnMoveWindowsToManagedSpace as Any),
        ]
        for (name, fn) in symbols {
            log(
                "[NativeSpaceBridge] symbol check",
                fields: ["symbol": name, "loaded": fn != nil ? "true" : "false"]
            )
        }
    }

    // MARK: - Window Moving (SLS Private API)

    // 缓存每个窗口的 moveWindow 失败时间 — 避免对已失败的窗口反复调用
    private static var _moveWindowFailures: [UInt32: TimeInterval] = [:]
    private static let moveWindowFailureRetryInterval: TimeInterval = 300

    static func resetFailureCache() {
        _moveWindowFailures.removeAll()
    }

    static func moveWindow(_ windowID: CGWindowID, toSpaceID spaceID: Int64) -> Bool {
        let key = UInt32(windowID)
        if let failedAt = _moveWindowFailures[key] {
            let elapsed = Date().timeIntervalSince1970 - failedAt
            if elapsed < moveWindowFailureRetryInterval {
                log(
                    "[NativeSpaceBridge] moveWindow skipped: window \(windowID) recently failed",
                    level: .debug,
                    fields: ["windowID": String(windowID), "elapsed": String(Int(elapsed)) + "s"]
                )
                return false
            }
            _moveWindowFailures.removeValue(forKey: key)
        }
        guard let cid = connectionID, let fn = fnMoveWindowsToManagedSpace else {
            log("[NativeSpaceBridge] moveWindow: API not available", level: .error, fields: [:])
            return false
        }
        guard windowID != 0 else {
            log("[NativeSpaceBridge] moveWindow: invalid windowID=0", level: .error, fields: [:])
            return false
        }
        let windowArray: NSArray = [NSNumber(value: UInt32(windowID))]
        let result = fn(cid, windowArray, 1, spaceID)
        if result != 0 {
            _moveWindowFailures[key] = Date().timeIntervalSince1970
        }
        log(
            "[NativeSpaceBridge] moveWindow",
            level: result == 0 ? .info : .warn,
            fields: [
                "windowID": String(windowID),
                "spaceID": String(spaceID),
                "result": String(result),
                "cached": String(_moveWindowFailures[key] != nil),
            ]
        )
        return result == 0
    }

    // MARK: - Space Switching (CGEvent direct)

    /// 通过 CGEvent 直接发送 Ctrl+Left/Right 键盘事件切换空间
    /// 比 AppleScript 更低延迟，避免 AppleScript runtime 开销
    /// steps > 0 = 向右切（Ctrl+Right），steps < 0 = 向左切（Ctrl+Left）
    static func focusSpace(steps: Int, operationID: String? = nil) -> Bool {
        let op = operationID ?? "none"
        guard steps != 0 else { return true }

        let keyCode: CGKeyCode
        let direction: String
        if steps > 0 {
            keyCode = 124 // Right arrow
            direction = "right"
        } else {
            keyCode = 123 // Left arrow
            direction = "left"
        }
        let absSteps = abs(steps)

        log(
            "[NativeSpaceBridge] focusSpace via CGEvent",
            fields: [
                "op": op,
                "direction": direction,
                "steps": String(absSteps),
            ]
        )

        for i in 0..<absSteps {
            // Key down
            let downEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
            downEvent?.flags = .maskControl
            downEvent?.post(tap: .cghidEventTap)
            // Key up
            let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
            upEvent?.flags = .maskControl
            upEvent?.post(tap: .cghidEventTap)
            // 间隔，防止 macOS 丢失事件
            if i < absSteps - 1 {
                usleep(80_000) // 80ms
            }
        }

        log(
            "[NativeSpaceBridge] focusSpace via CGEvent completed",
            fields: ["op": op, "direction": direction, "steps": String(absSteps)]
        )
        return true
    }

    // MARK: - Window Drag (CGEvent Mouse Simulation)

    /// 通过 CGEvent 模拟鼠标拖拽，将窗口从当前显示器移到目标显示器。
    /// macOS 在拖拽过程中检测到窗口跨显示器边界时，会自动将窗口重新分配到目标显示器。
    /// 这复刻了用户手动拖动窗口到另一个显示器的行为。
    ///
    /// 坐标系说明：
    /// - AX frame (windowFrame): Quartz 坐标系 — 原点在主屏左上角，Y 向下
    /// - NSScreen.frame (targetScreen): Cocoa 坐标系 — 原点在主屏左下角，Y 向上
    /// - CGEvent: Quartz 坐标系 — 与 AX 相同
    /// - 鼠标位置 (NSEvent.mouseLocation): Cocoa 坐标系
    /// - 转换: quartzY = mainScreenHeight - cocoaY
    static func dragWindowToDisplay(
        windowFrame: CGRect,
        targetScreen: NSScreen,
        operationID: String? = nil
    ) -> Bool {
        let op = operationID ?? "none"
        let mainScreenHeight = NSScreen.screens[0].frame.height

        // windowFrame 是 AX/Quartz 坐标，不需要转换
        // 标题栏在窗口顶部往下 15px（Quartz 坐标，Y 向下）
        let titleBarCG = CGPoint(x: windowFrame.midX, y: windowFrame.origin.y + 15)

        // targetScreen.frame 是 NSScreen/Cocoa 坐标，需要转换到 Quartz
        let targetCenterCocoaY = targetScreen.frame.origin.y + targetScreen.frame.height / 2
        let targetCenterCG = CGPoint(
            x: targetScreen.frame.origin.x + targetScreen.frame.width / 2,
            y: mainScreenHeight - targetCenterCocoaY
        )

        // NSEvent.mouseLocation 是 Cocoa 坐标，转换到 Quartz 用于恢复
        let savedCursorNS = NSEvent.mouseLocation
        let savedCursorCG = CGPoint(x: savedCursorNS.x, y: mainScreenHeight - savedCursorNS.y)

        log(
            "[NativeSpaceBridge] dragWindowToDisplay starting",
            level: .info,
            fields: [
                "op": op,
                "windowFrame": "\(windowFrame)",
                "titleBarCG": "\(titleBarCG)",
                "targetCenterCG": "\(targetCenterCG)",
                "targetScreenCocoa": "\(targetScreen.frame)"
            ]
        )

        // Step 1: 移动鼠标到标题栏
        postMouse(.mouseMoved, position: titleBarCG)
        usleep(30_000) // 30ms

        // Step 2: 鼠标按下
        postMouse(.leftMouseDown, position: titleBarCG)
        usleep(30_000)

        // Step 3: 分步拖拽到目标显示器（分 5 步，让 macOS 检测到跨显示器）
        let steps = 5
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let interpX = titleBarCG.x + (targetCenterCG.x - titleBarCG.x) * t
            let interpY = titleBarCG.y + (targetCenterCG.y - titleBarCG.y) * t
            postMouse(.leftMouseDragged, position: CGPoint(x: interpX, y: interpY))
            usleep(20_000) // 20ms per step
        }

        // Step 4: 确保到达目标位置
        postMouse(.leftMouseDragged, position: targetCenterCG)
        usleep(100_000) // 100ms 等待 macOS 处理显示器切换

        // Step 5: 鼠标释放
        postMouse(.leftMouseUp, position: targetCenterCG)
        usleep(50_000)

        // Step 6: 恢复鼠标位置
        postMouse(.mouseMoved, position: savedCursorCG)

        log(
            "[NativeSpaceBridge] dragWindowToDisplay completed",
            level: .info,
            fields: [
                "op": op,
                "targetScreenCocoa": "\(targetScreen.frame)"
            ]
        )
        return true
    }

    private static func postMouse(_ type: CGEventType, position: CGPoint) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: position, mouseButton: .left) else { return }
        event.post(tap: .cghidEventTap)
    }
}
