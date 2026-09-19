import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerFocusResolutionTests.swift — B231：toggle 三级焦点解析 +
// 标题通道不支持 bundle 跳过分支（两者全只读：nil 前台走确定性短路；
// 真前台解析只读 CGWindowList/yabai/AX 探测，不写任何窗口状态）。

extension RunnerHarness {
    func runFocusResolutionTests() {
        let wm = WindowManager.shared

        // ===== resolveFocusedWindowForToggle：nil 前台 → 确定性短路（零探测） =====
        do {
            var ctx: [String: String] = ["op": "b231-nil"]
            let res = wm.resolveFocusedWindowForToggle(
                frontApp: nil, cachedMainScreen: wm.getMainScreen(), toggleContext: &ctx)
            check("focusRes: 无前台 app → windowID/identity 空、默认 ax 源",
                  res.windowID == nil && res.identity == nil && res.source == "ax")
        }

        // ===== resolveFocusedWindowForToggle：真前台三级解析（只读探测，契约一致） =====
        do {
            guard let front = NSWorkspace.shared.frontmostApplication else {
                check("focusRes: 环境存在前台 app（夹具前提）", false)
                return
            }
            var ctx: [String: String] = ["op": "b231-real"]
            let res = wm.resolveFocusedWindowForToggle(
                frontApp: front, cachedMainScreen: wm.getMainScreen(), toggleContext: &ctx)
            // 命中时：typed 字段与 context 字典同源同步（adopt 单点收尾契约）
            if let wid = res.windowID {
                check("focusRes: 命中时 context 与 typed 字段同源",
                      ctx["windowID"] == String(wid) && res.identity != nil
                      && ctx["windowTitle"] != nil
                      && (res.source == "cgwindowlist" || res.source == "yabai" || res.source == "ax"))
                check("focusRes: onMain 判定与主屏缓存一致（两态皆可）",
                      res.onMainScreen == nil || ctx["onMainScreen"] != nil)
            } else {
                // 三分支全失败（全屏遮挡/无可见窗）：收尾字段仍须齐备
                check("focusRes: 未命中时收尾字段仍齐备",
                      res.identity == nil && ctx["windowID"] == nil)
            }
        }

        // ===== applyViaAppleScript：不支持 bundle → makeTitleScript nil → 跳过（零执行） =====
        do {
            let svc = TitleEditorService()
            check("titleChan: 非 Terminal/iTerm2 bundle → 不执行脚本直接 false",
                  svc.applyViaAppleScript("B231", bundleID: "com.vibefocus.nonexistent.zz", targetTTY: nil) == false)
            check("titleChan: 定向 TTY + 不支持 bundle 同样跳过",
                  svc.applyViaAppleScript("B231", bundleID: "com.vibefocus.nonexistent.zz", targetTTY: "/dev/ttys001") == false)
        }
    }
}
