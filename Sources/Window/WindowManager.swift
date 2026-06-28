import SwiftUI
import AppKit
import Carbon
import ApplicationServices.HIServices
import CoreFoundation
import Foundation

@MainActor
/// Core window management engine — finding, moving, toggling, and restoring windows.
class WindowManager {
    static let shared = WindowManager()

    let spaceController = SpaceController.shared
    var focusSpaceKnownBroken: Bool = false
    var didPromptForAccessibility = false
    let frameTolerance: CGFloat = 10
    let axWindowNumberAttribute = "AXWindowNumber"
    let axFrameAttribute = "AXFrame"

    struct ScriptWindowSnapshot: Codable {
        let windowID: UInt32?
        let appName: String
        let title: String?
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat

        var frame: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }

    init() {}

    func getMainScreen() -> NSScreen? {
        // P-INST-214: 主屏获取耗时（NSScreen.screens 枚举 + first filter + NSScreen.main fallback；toggle/move 多路径调用，NSScreen.screens 可能阻塞 WindowServer；slow-op ≥30ms warn）。
        let gmsStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: gmsStart)
            if durMs >= 30 { log("[WindowManager] getMainScreen slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        return NSScreen.screens.first { $0.isMainScreen } ?? NSScreen.main
    }

    func hasAccessibilityPermission() -> Bool {
        // P-INST-64: AX 权限检查耗时（AXIsProcessTrustedWithOptions 系统调用；启动 + toggle 前置检查，通常 ~5ms 但系统繁忙时可阻塞；slow-op ≥50ms warn）。
        let hapStart = Date()
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary)
        let hapMs = elapsedMilliseconds(since: hapStart)
        if hapMs >= 50 {
            log("[WindowManager] hasAccessibilityPermission slow", level: .warn, fields: ["trusted": String(trusted), "durationMs": String(hapMs)])
        }
        return trusted
    }

    func notifyAccessibilityPermissionRequired() {
        // P-INST-191: 辅助功能权限缺失通知耗时（NSSound.beep 系统提示音 + NSWorkspace.shared.open 启动 System Settings；toggle/hotkey 检测到权限缺失首次调用，didPromptForAccessibility 去重后续跳过）。
        let naprStart = Date()
        guard !didPromptForAccessibility else {
            let durMs = elapsedMilliseconds(since: naprStart)
            if durMs >= 5 { log("[WindowManager] notifyAccessibilityPermissionRequired(skipped) slow", level: .warn, fields: ["durationMs": String(durMs)]) }
            return
        }
        didPromptForAccessibility = true
        NSSound.beep()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        let durMs = elapsedMilliseconds(since: naprStart)
        if durMs >= 50 { log("[WindowManager] notifyAccessibilityPermissionRequired slow", level: .warn, fields: ["durationMs": String(durMs)]) }
    }
}
