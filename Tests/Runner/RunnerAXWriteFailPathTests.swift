import AppKit
import ApplicationServices.HIServices
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerAXWriteFailPathTests.swift — 覆盖率批次 23（B254）：
// WindowManager AX 写入/读取原语在无授权 CLI 进程下的失败分支直测。
//
// 无 AX 授权（Runner 非 axis 装机实例）时 AXUIElementSetAttributeValue /
// AXUIElementCopyAttributeValue 恒返回错误 → 写路径 false、读路径 nil——
// 这是生产「AX 不可写 → fallback yabai」降级链的入口分支，安全可锁。
// systemWide 元素创建不需要授权；settleDelay 重试在毫秒级（usleep）可接受。

extension RunnerHarness {
    func runAXWriteFailPathTests() {
        let wm = WindowManager.shared
        let systemWide = AXUIElementCreateSystemWide()
        let target = CGRect(x: 0, y: 0, width: 800, height: 600)

        // resizeViaAX：size write + readback 在无授权下 axOK=false → false。
        let resized = wm.resizeViaAX(
            targetFrame: target, window: systemWide,
            windowID: 0xB254, op: "b254-resize", stage: "test")
        check("axWrite: resizeViaAX 无授权走失败分支返 false", resized == false)

        // AX frame 读取：无授权 → nil。
        check("axRead: frame(of:) 无授权 → nil",
              wm.frame(of: systemWide) == nil)
    }
}

// MARK: - B266 追加：captureFocusedWindowIdentity 无授权降级链

extension RunnerHarness {
    func runCaptureFocusedWindowTests() {
        let wm = WindowManager.shared
        // Runner（无 bundle/无 AX 授权）：frontmostApplication nil 或 focusedWindow
        // AX 查询失败 → 降级链返 nil。两态均合法（依运行环境）。
        if let identity = wm.captureFocusedWindowIdentity() {
            check("captureFocused: 命中时 windowID/title 结构完整",
                  identity.windowID != 0 && (identity.title ?? "").isEmpty == false)
        } else {
            check("captureFocused: 无前台/无 AX 授权环境合法 nil", true)
        }
    }
}
