import AppKit
import ApplicationServices
import CoreGraphics

// 简单版本 - 直接测试跨屏铺满与恢复

print("=== VibeFocus 直接测试工具 ===\n")

// 检查权限
let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false] as CFDictionary
if !AXIsProcessTrustedWithOptions(options) {
    print("❌ 请先授权辅助功能权限")
    print("系统设置 → 隐私与安全性 → 辅助功能")
    exit(1)
}

// 获取当前窗口
if let frontApp = NSWorkspace.shared.frontmostApplication {
    print("当前应用: \(frontApp.localizedName ?? "Unknown")")

    let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
    var windowRef: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef)

    guard status == .success, let window = windowRef else {
        print("❌ 无法获取窗口")
        exit(1)
    }

    let windowAX = window as! AXUIElement

    // 获取当前位置
    var frameValue: CFTypeRef?
    AXUIElementCopyAttributeValue(windowAX, "AXFrame" as CFString, &frameValue)
    var originalFrame = CGRect.zero
    if let axValue = frameValue {
        AXValueGetValue(axValue as! AXValue, .cgRect, &originalFrame)
        print("当前位置: \(originalFrame)")
    }

    var positionSettable = DarwinBoolean(false)
    let positionCheck = AXUIElementIsAttributeSettable(windowAX, kAXPositionAttribute as CFString, &positionSettable)
    var sizeSettable = DarwinBoolean(false)
    let sizeCheck = AXUIElementIsAttributeSettable(windowAX, kAXSizeAttribute as CFString, &sizeSettable)

    guard positionCheck == .success, positionSettable.boolValue else {
        print("❌ 当前窗口不支持设置位置")
        exit(1)
    }

    guard sizeCheck == .success, sizeSettable.boolValue else {
        print("❌ 当前窗口不支持设置大小")
        exit(1)
    }

    // 获取主屏幕
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    let mainDisplayID = CGMainDisplayID()
    let targetScreen = NSScreen.screens.first { screen in
        if let value = screen.deviceDescription[key] as? NSNumber {
            return CGDirectDisplayID(value.uint32Value) == mainDisplayID
        }
        return false
    }

    guard let screen = targetScreen ?? NSScreen.screens.first ?? NSScreen.main else {
        print("❌ 无法获取主屏幕")
        exit(1)
    }

    print("主屏幕可见区域(AppKit): \(screen.visibleFrame)")

    // 移动窗口
    print("\n正在移动...")
    let visibleFrame = screen.visibleFrame
    let zeroScreenMaxY = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
    let targetFrame = CGRect(
        x: visibleFrame.origin.x,
        y: zeroScreenMaxY - visibleFrame.maxY,
        width: visibleFrame.width,
        height: visibleFrame.height
    )
    print("目标区域(AX): \(targetFrame)")

    // 设置位置
    var pos = CGPoint(x: targetFrame.origin.x, y: targetFrame.origin.y)
    let posValue = AXValueCreate(.cgPoint, &pos)
    let posResult = AXUIElementSetAttributeValue(windowAX, kAXPositionAttribute as CFString, posValue!)

    // 设置大小
    var size = CGSize(width: targetFrame.width, height: targetFrame.height)
    let sizeValue = AXValueCreate(.cgSize, &size)
    let sizeResult = AXUIElementSetAttributeValue(windowAX, kAXSizeAttribute as CFString, sizeValue!)

    if posResult.rawValue == 0 && sizeResult.rawValue == 0 {
        print("✅ 移动成功！")

        // 3秒后恢复
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            print("正在恢复...")
            var origPos = CGPoint(x: originalFrame.origin.x, y: originalFrame.origin.y)
            let origPosValue = AXValueCreate(.cgPoint, &origPos)
            _ = AXUIElementSetAttributeValue(windowAX, kAXPositionAttribute as CFString, origPosValue!)

            var origSize = CGSize(width: originalFrame.width, height: originalFrame.height)
            let origSizeValue = AXValueCreate(.cgSize, &origSize)
            _ = AXUIElementSetAttributeValue(windowAX, kAXSizeAttribute as CFString, origSizeValue!)

            print("✅ 已恢复")
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 5))
    } else {
        print("❌ 移动失败 (pos: \(posResult.rawValue), size: \(sizeResult.rawValue))")
    }
}
