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
        // P-INST-228: SkyLight.framework 动态加载耗时（dlopen RTLD_LAZY 私有框架映射；首次访问 skyLightHandle 时单次执行，启动延迟归因；slow-op ≥50ms warn）。
        let shStart = Date()
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        let durMs = elapsedMilliseconds(since: shStart)
        if durMs >= 50 { log("[NativeSpaceBridge] skyLightHandle dlopen slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        return handle
    }()

    private static func load<T>(_ name: String) -> T? {
        // P-INST-229: SkyLight 符号动态查找耗时（dlsym 符号解析 + unsafeBitCast；fnMainConnectionID/fnMoveWindowsToManagedSpace 计算属性每次访问调用，首次解析后 OS 缓存；slow-op ≥5ms warn）。
        let ldStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: ldStart)
            if durMs >= 5 { log("[NativeSpaceBridge] load slow", level: .warn, fields: ["symbol": name, "durationMs": String(durMs)]) }
        }
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
        // P-INST-230: SLS 符号可用性诊断耗时（访问 fnMainConnectionID/fnMoveWindowsToManagedSpace 计算属性触发 load P-INST-229 dlsym + 循环 log；诊断/启动调用）。
        let laStart = Date()
        defer {
            log("[NativeSpaceBridge] logAvailability finished", level: .debug, fields: ["durationMs": String(elapsedMilliseconds(since: laStart))])
        }
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
        // P-INST-50: SLS moveWindow 耗时（SLSMoveWindowsToManagedSpace 调用；Strategy 2 fallback 预期权限不足失败，但 SLS 调用本身可能慢；moveWindow P-INST-43 总耗时的 fallback 归因）。
        let slsStart = Date()
        var slsOutcome = "unknown"
        defer {
            log("[NativeSpaceBridge] moveWindow finished", level: .debug, fields: [
                "windowID": String(windowID),
                "spaceID": String(spaceID),
                "outcome": slsOutcome,
                "durationMs": String(elapsedMilliseconds(since: slsStart))
            ])
        }
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
        slsOutcome = result == 0 ? "sls_ok" : "sls_failed"
        if result != 0 {
            _moveWindowFailures[key] = Date().timeIntervalSince1970
        }
        // result != 0 是预期：SLSMoveWindowsToManagedSpace 需 "universal owner connection"
        // (yabai issue #2593)，VibeFocus 普通 connection 权限不足。降为 debug 避免日志噪音。
        log(
            "[NativeSpaceBridge] moveWindow",
            level: result == 0 ? .info : .debug,
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
        // P-INST-12: focusSpace CGEvent 切换总耗时（含 N×80ms usleep，restore 的 focusSpaceMs 内部细分）。
        let focusStart = Date()
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
            fields: [
                "op": op, "direction": direction, "steps": String(absSteps),
                "durationMs": String(elapsedMilliseconds(since: focusStart))
            ]
        )
        return true
    }

    // MARK: - Mission Control Dismissal

    /// 发送 Escape 键关闭 Mission Control
    /// 当 yabai 报 "mission-control is active" 错误时，Mission Control 正在显示中
    /// 此时所有 space 切换命令（yabai + CGEvent Ctrl+Arrow）都会失败
    static func dismissMissionControl(operationID: String? = nil) {
        let op = operationID ?? "none"
        // P-INST-20: dismissMissionControl 完成耗时（含 150ms usleep 等 Mission Control 动画）。
        let dismissStart = Date()
        log("[NativeSpaceBridge] dismissing Mission Control via Escape key", fields: ["op": op])
        let escapeDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: true)
        escapeDown?.post(tap: .cghidEventTap)
        let escapeUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: false)
        escapeUp?.post(tap: .cghidEventTap)
        usleep(150_000) // 等待 Mission Control 动画结束
        log("[NativeSpaceBridge] dismissMissionControl done", fields: [
            "op": op,
            "durationMs": String(elapsedMilliseconds(since: dismissStart))
        ])
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
        // P-INST-19: dragWindowToDisplay 总耗时（多步 CGEvent 鼠标拖拽 + usleep，约 310ms 固定成本）。
        let dragStart = Date()
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0

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
                "targetScreenCocoa": "\(targetScreen.frame)",
                "durationMs": String(elapsedMilliseconds(since: dragStart))
            ]
        )
        return true
    }

    private static func postMouse(_ type: CGEventType, position: CGPoint) {
        // P-INST-206: 合成鼠标事件注入耗时（CGEvent 构造 + event.post cghidEventTap HID 注入；NativeSpaceBridge space 拖拽恢复路径调用，post 可能阻塞 WindowServer；slow-op ≥30ms warn）。
        let pmStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: pmStart)
            if durMs >= 30 { log("[NativeSpaceBridge] postMouse slow", level: .warn, fields: ["type": String(type.rawValue), "durationMs": String(durMs)]) }
        }
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: position, mouseButton: .left) else { return }
        event.post(tap: .cghidEventTap)
    }
}
