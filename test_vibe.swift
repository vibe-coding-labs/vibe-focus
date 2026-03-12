import AppKit
import ApplicationServices

print("=== VibeFocus 功能测试 ===\n")

// 测试权限
let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false] as CFDictionary
let trusted = AXIsProcessTrustedWithOptions(options)
print("[1/4] 辅助功能权限: \(trusted ? "✅ 通过" : "❌ 未授权")")

if !trusted {
    print("\n⚠️ 请先授权辅助功能权限！")
    print("系统设置 → 隐私与安全性 → 辅助功能 → 添加 VibeFocusHotkeys")
    exit(1)
}

// 测试获取应用
if let frontApp = NSWorkspace.shared.frontmostApplication {
    print("[2/4] 获取当前应用: ✅ 通过 (\(frontApp.localizedName ?? "Unknown"))")

    // 测试获取窗口
    let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
    var windowRef: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef)

    if status == .success {
        print("[3/4] 获取窗口: ✅ 通过")

        // 测试全屏
        let window = windowRef!
        print("\n[4/4] 测试全屏功能...")
        print("3秒后将窗口全屏，再3秒恢复...")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let fsStatus = AXUIElementSetAttributeValue(window as! AXUIElement, "AXFullScreen" as CFString, true as CFBoolean)
            if fsStatus.rawValue == 0 {
                print("✅ 全屏成功！")
            } else {
                print("❌ 全屏失败 (状态: \(fsStatus.rawValue))")
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let restoreStatus = AXUIElementSetAttributeValue(window as! AXUIElement, "AXFullScreen" as CFString, false as CFBoolean)
                if restoreStatus.rawValue == 0 {
                    print("✅ 恢复成功！")
                    print("\n✅✅✅ 所有测试通过！功能正常 ✅✅✅")
                } else {
                    print("❌ 恢复失败")
                }
            }
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 6))
    } else {
        print("[3/4] 获取窗口: ❌ 失败")
    }
} else {
    print("[2/4] 获取当前应用: ❌ 失败")
}
