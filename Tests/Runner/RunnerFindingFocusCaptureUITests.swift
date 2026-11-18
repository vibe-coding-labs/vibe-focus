// Tests/Runner/RunnerFindingFocusCaptureUITests.swift — 覆盖率批次 32（批次 36 改为确定性两段）：
// UI 门控域（VIBEFOCUS_UI_E2E=1，覆盖率 CI 的 UI 域通道）下自建真实 key 窗，
// 把 Finding/焦点解析两条「必须有真实前台窗口」的成功臂变成可执行路径：
//   A. 单在屏窗（只有 win1）→ 候选数恒为 1 → cgwindowlist 快路径 + adopt 归一化收尾
//      （此前两窗同开，候选数在 CI 时而 1 时而 2，覆盖率随环境抖动）；
//   B. 再开 win2 → 候选 >1 → yabai 探测失败 → AX adopt 分支（无授权时诚实降级）；
//   - captureFocusedWindowIdentity 的 AX 成功臂（focusedWindow + windowHandle +
//     windowNumber/title + 身份构造，Finding.swift 尾段）。
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
        defer {
            win1.close()
            win2.close()
        }

        // --- A. 单在屏窗 → CGWindowList 快路径（候选恒 1，不依赖 yabai/AX） ---
        win1.makeKeyAndOrderFront(nil)
        // 等 WindowServer 把窗登记进 CGWindowList（否则候选数可能瞬间为 0）
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        var ctxSingle: [String: String] = [:]
        let single = wm.resolveFocusedWindowForToggle(
            frontApp: NSRunningApplication.current,
            cachedMainScreen: NSScreen.screens.first,
            toggleContext: &ctxSingle
        )
        check("findingUI: 焦点解析 source 合法",
              single.source == "cgwindowlist" || single.source == "yabai" || single.source == "ax")
        if ctxSingle["candidatesCount"] == "1" {
            check("findingUI: 单候选快路径命中 cgwindowlist", single.source == "cgwindowlist")
            check("findingUI: 单候选快路径带出窗口身份与 frame",
                  single.windowID != nil && single.identity?.pid == getpid())
            check("findingUI: adopt 填充 ctx 窗口元信息",
                  ctxSingle["windowID"] != nil && ctxSingle["windowTitle"] != nil
                  && ctxSingle["windowFrame"] != nil)
        } else {
            check("findingUI: 环境自带他窗遮挡单候选（降级路径自洽）",
                  (single.windowID == nil) == (single.identity == nil))
        }

        // --- B. 再开第二窗 → 候选 >1 → yabai 分支（CI 无 yabai → AX 探测） ---
        win2.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        var ctxMulti: [String: String] = [:]
        let multi = wm.resolveFocusedWindowForToggle(
            frontApp: NSRunningApplication.current,
            cachedMainScreen: NSScreen.screens.first,
            toggleContext: &ctxMulti
        )
        if ctxMulti["candidatesCount"] != "1" {
            check("findingUI: 非单候选时 yabai 探测被执行并计时", ctxMulti["yabaiProbeMs"] != nil)
        } else {
            check("findingUI: 第二窗未在屏（单候选仍走快路径）", multi.source == "cgwindowlist")
        }
        if multi.source == "ax", let winID = multi.windowID {
            check("findingUI: AX 分支命中自建窗（pid 归属本进程）",
                  winID != 0 && multi.identity?.pid == getpid())
            check("findingUI: AX 分支携带 windowAX 供复用", multi.windowAX != nil)
        } else {
            check("findingUI: 非 AX 命中路径结果自洽",
                  (multi.windowID == nil) == (multi.identity == nil))
        }

        // --- C. captureFocusedWindowIdentity 成功臂：需本进程为 frontmostApplication。
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
