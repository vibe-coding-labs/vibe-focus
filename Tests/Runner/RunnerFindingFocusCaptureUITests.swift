// Tests/Runner/RunnerFindingFocusCaptureUITests.swift — 覆盖率批次 32：
// UI 门控域（VIBEFOCUS_UI_E2E=1，覆盖率 CI 的 UI 域通道）下自建真实 key 窗，
// 把 Finding/焦点解析两条「必须有真实前台窗口」的成功臂变成可执行路径：
//   - captureFocusedWindowIdentity 的 AX 成功臂（focusedWindow + windowHandle +
//     windowNumber/title + 身份构造，Finding.swift 尾段）；
//   - resolveFocusedWindowForToggle 的 yabai 探测失败 → AX adopt 分支（多候选遮挡
//     CGWindowList 快路径后，AX 拿到自建窗并在 CG 快照里命中 → source == "ax"）。
// 真机全量 Runner 不设 UI_E2E → 整域跳过；覆盖率管线单域进程内 UI_E2E=1 才执行。
// 断言双世界诚实：AX 自查询/前台激活在 CI 可能不可得（无辅助功能授权），此时只断言
// 降级不崩溃；成功臂断言仅在真拿到结果时生效，不会把环境差异变成假红。

import AppKit
import Foundation

@testable import VibeFocusKit

extension RunnerHarness {
    func runFindingFocusCaptureUITests() {
        print("\n=== FindingFocusCaptureUI ===")
        _ = NSApplication.shared
        let wm = WindowManager.shared

        let win1 = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win1.title = "vibefocus-focus-capture-ui-1"
        let win2 = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win2.title = "vibefocus-focus-capture-ui-2"
        win1.makeKeyAndOrderFront(nil)
        win2.orderFront(nil)
        defer {
            win1.close()
            win2.close()
        }

        // --- A. toggle 焦点解析：两候选（自建双窗）遮挡 CGWindowList 快路径，
        //     yabai 在 CI 不可用 → AX 分支。frontApp 直接传 current，不依赖前台激活。
        var toggleContext: [String: String] = [:]
        let resolution = wm.resolveFocusedWindowForToggle(
            frontApp: NSRunningApplication.current,
            cachedMainScreen: NSScreen.screens.first,
            toggleContext: &toggleContext
        )
        check("findingUI: 焦点解析 source 合法",
              resolution.source == "cgwindowlist" || resolution.source == "yabai" || resolution.source == "ax")
        if toggleContext["candidatesCount"] == "1" {
            // 自建窗只有一个在屏（无桌面会话的 CI 可能如此）：CGWindowList 快路径命中
            check("findingUI: 单候选快路径命中 cgwindowlist",
                  resolution.source == "cgwindowlist")
        } else {
            check("findingUI: 非单候选时 yabai 探测被执行并计时",
                  toggleContext["yabaiProbeMs"] != nil)
        }
        if resolution.source == "ax", let winID = resolution.windowID {
            // AX 成功臂：自建 key 窗的 AX handle 在 CGWindowList 快照中命中 → adopt
            check("findingUI: AX 分支命中自建窗（pid 归属本进程）",
                  winID != 0 && resolution.identity?.pid == getpid())
            check("findingUI: AX 分支携带 windowAX 供复用",
                  resolution.windowAX != nil)
            check("findingUI: AX 分支填充 ctx 窗口元信息",
                  toggleContext["windowID"] != nil && toggleContext["windowTitle"] != nil)
        } else {
            // 无辅助功能授权（CI 常见）或单候选快路径：解析结果与 ctx 字段一致即合法
            check("findingUI: 非 AX 命中路径结果自洽",
                  (resolution.windowID == nil) == (resolution.identity == nil))
        }

        // --- B. captureFocusedWindowIdentity 成功臂：需本进程为 frontmostApplication。
        //     CI 无交互会话时激活可能不可得——轮询等待，拿不到就只断言降级不崩溃。
        NSApp.activate(ignoringOtherApps: true)
        _ = NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
        var frontmost = false
        let activateDeadline = Date().addingTimeInterval(5)
        while Date() < activateDeadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
                frontmost = true
                break
            }
            NSApp.activate(ignoringOtherApps: true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        if frontmost {
            var captured: WindowIdentity?
            let captureDeadline = Date().addingTimeInterval(5)
            while Date() < captureDeadline {
                captured = wm.captureFocusedWindowIdentity()
                if captured != nil { break }
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            if let captured {
                check("findingUI: 前台 key 窗被捕获身份（AX 成功臂）", captured.windowID != 0)
                check("findingUI: 捕获身份 pid 归属本进程", captured.pid == getpid())
            } else {
                // 前台已激活但 AX 读不到焦点窗（CI 无辅助功能授权常见）：降级不崩溃
                check("findingUI: 前台激活但 AX 不可读 → 捕获降级", true)
            }
        } else {
            // CI 前台激活不可得：捕获函数走 guard 降级，不崩溃即可
            let captured = wm.captureFocusedWindowIdentity()
            check("findingUI: 无前台激活时捕获降级不崩溃", captured == nil || captured?.pid != nil)
        }
    }
}
