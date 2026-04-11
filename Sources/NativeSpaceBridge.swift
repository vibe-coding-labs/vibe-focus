import AppKit
import CoreGraphics
import Foundation

/// 使用 macOS 原生 API 进行空间操作。
/// focusSpace: 通过 CGEvent 发送 Ctrl+Left/Right 键盘事件切换空间（可靠，无需私有 API）
/// moveWindow: 通过 SLS 私有 API 移动窗口到指定空间
enum NativeSpaceBridge {
    // MARK: - SLS Private API Types (only for moveWindow)

    private typealias FnMainConnectionID = @convention(c) () -> Int32
    private typealias FnMoveWindowsToManagedSpace = @convention(c) (Int32, UnsafePointer<CGWindowID>, Int32, Int64) -> Int32

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

    static func moveWindow(_ windowID: CGWindowID, toSpaceID spaceID: Int64) -> Bool {
        guard let cid = connectionID, let fn = fnMoveWindowsToManagedSpace else {
            log("[NativeSpaceBridge] moveWindow: API not available", level: .error, fields: [:])
            return false
        }
        let result = fn(cid, [windowID], 1, spaceID)
        log(
            "[NativeSpaceBridge] moveWindow",
            level: result == 0 ? .info : .warn,
            fields: [
                "windowID": String(windowID),
                "spaceID": String(spaceID),
                "result": String(result),
            ]
        )
        return result == 0
    }

    // MARK: - Space Switching (NSAppleScript via System Events)

    /// 通过 NSAppleScript 调用 System Events 发送 Ctrl+Left/Right 键盘事件
    /// System Events 是 macOS 原生的自动化方式，比 CGEvent 更可靠
    /// steps > 0 = 向右切（Ctrl+Right），steps < 0 = 向左切（Ctrl+Left）
    static func focusSpace(steps: Int, operationID: String? = nil) -> Bool {
        let op = operationID ?? "none"
        guard steps != 0 else { return true }

        let keyCode: Int
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
            "[NativeSpaceBridge] focusSpace via AppleScript",
            fields: [
                "op": op,
                "direction": direction,
                "steps": String(absSteps),
            ]
        )

        for i in 0..<absSteps {
            let script = NSAppleScript(source: """
            tell application "System Events" to key code \(keyCode) using control down
            """)
            var error: NSDictionary?
            script?.executeAndReturnError(&error)
            if let error {
                let msg = error[NSAppleScript.errorMessage] as? String ?? "unknown"
                log(
                    "[NativeSpaceBridge] focusSpace AppleScript error at step \(i)",
                    level: .error,
                    fields: ["op": op, "error": msg]
                )
                return false
            }
            // 间隔，防止 macOS 丢失事件
            if i < absSteps - 1 {
                usleep(80_000) // 80ms
            }
        }

        log(
            "[NativeSpaceBridge] focusSpace via AppleScript completed",
            fields: ["op": op, "direction": direction, "steps": String(absSteps)]
        )
        return true
    }
}
