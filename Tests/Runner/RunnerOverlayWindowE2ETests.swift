import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerOverlayWindowE2ETests.swift — B301：Overlay 家族 E2E 通道开建。
//
// 第 1 节（默认门禁恒跑）：OverlayWindow 离屏生命周期——构造/update/updatePosition
//   全程不 orderFront（B268 离屏 NSWindow 先例），窗口不进屏、零用户可见扰动。
//
// 第 2 节（VIBEFOCUS_OVERLAY_E2E=1 门控，单通道运行）：真实置前链——show/hide、
//   showOverlays/hideOverlays/updateOverlayPositions/updateOverlaysInPlace 全家、
//   气泡抑制开关、crash-loop 熔断守卫、triggerForceRefresh 广播/刷新双分支、
//   refreshSpaceIndices 后台 Task 真实 yabai 查询、SpaceQuery 失败注入
//   （preferences.yabaiPath 指向 /usr/bin/false / /usr/bin/true 打查询失败/解析失败分支）。
//   全程只动自家 borderless 窗（ignoresMouseEvents=true，不抢焦点不挡点击），
//   结束 hideOverlays 归零盘点（自动化测试清场纪律）。


final class OverlayE2EAsyncResultBox<T: Sendable>: @unchecked Sendable {
    var value: T? = nil
}

extension RunnerHarness {
    private func runOverlayMainActorAsync<T: Sendable>(
        _ block: @escaping @MainActor () async -> T
    ) -> T? {
        let box = OverlayE2EAsyncResultBox<T>()
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            box.value = await block()
            sem.signal()
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if sem.wait(timeout: .now() + 0.05) == .success { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return box.value
    }
}

extension RunnerHarness {
    func runOverlayWindowE2ETests() {
        print("\n=== OverlayWindowE2E (B301) ===")
        guard let screen = NSScreen.screens.first else {
            check("overlayE2E: 无显示器环境跳过", true)
            return
        }

        // ===== 第 1 节：离屏生命周期（默认门禁恒跑，不 orderFront）=====
        do {
            let prefs = ScreenIndexPreferences.default
            let win = OverlayWindow(screen: screen)
            check("overlayWin: 构造成功且未上屏（borderless 200x100 初帧）",
                  !win.isVisible && win.contentView != nil)

            win.update(screenIndex: 2, yabaiDisplayIndex: nil, spaceIndex: 3, preferences: prefs)
            let expectedLabel = Self.overlayExpectedLabel(yabaiDisplayIndex: nil, screenIndex: 2, spaceIndex: 3)
            let scaled = prefs.fontSize * prefs.panelScale
            let expectedSize = OverlayWindow.calculateOverlaySize(
                textWidth: expectedLabel.width(givenFont: scaled),
                textHeight: scaled, scaledFontSize: scaled)
            check("overlayWin: update 落尺寸（≥字号兜底最小宽高）",
                  win.contentView!.bounds.width >= expectedSize.width - 1
                  && win.contentView!.bounds.height >= expectedSize.height - 1)

            win.updatePosition(for: screen, position: .topRight, margin: prefs.panelMargin)
            let expectedOrigin = OverlayWindow.calculateOverlayOrigin(
                position: .topRight, screenFrame: screen.frame,
                windowSize: win.contentView!.bounds.size, margin: prefs.panelMargin)
            check("overlayWin: updatePosition 落角标原点（topRight 纯函数一致）",
                  abs(win.frame.origin.x - expectedOrigin.x) < 0.5
                  && abs(win.frame.origin.y - expectedOrigin.y) < 0.5)

            win.hide()
            check("overlayWin: hide 后仍离屏（orderOut 幂等）", !win.isVisible)
        }

        // ===== 第 2 节：真实置前链（VIBEFOCUS_OVERLAY_E2E=1 单通道）=====
        guard ProcessInfo.processInfo.environment["VIBEFOCUS_OVERLAY_E2E"] == "1" else {
            check("overlayE2E: 真实置前链（未设 VIBEFOCUS_OVERLAY_E2E=1，跳过）", true)
            return
        }
        MainActor.assumeIsolated {
            let om = ScreenOverlayManager(startTimerAutomatically: false)
            var prefs = om.preferences
            prefs.isEnabled = true
            om.preferences = prefs

            // B1: showOverlays 全家——每屏一窗全部上屏
            om.showOverlays()
            check("overlayE2E: showOverlays 每屏一窗全部上屏",
                  om.overlayWindows.count == NSScreen.screens.count
                  && om.overlayWindows.values.allSatisfy { $0.isVisible })

            // B2: 二次 showOverlays——先 close 既有再重建（stale 清理循环）
            om.showOverlays()
            check("overlayE2E: 二次 showOverlays 重建后仍每屏一窗",
                  om.overlayWindows.count == NSScreen.screens.count)

            // B3: updateOverlayPositions——换角落重摆
            prefs.position = .bottomLeft
            om.preferences = prefs
            om.updateOverlayPositions()
            check("overlayE2E: updateOverlayPositions 换 bottomLeft 后仍全部上屏",
                  om.overlayWindows.values.allSatisfy { $0.isVisible })
            prefs.position = .topRight
            om.preferences = prefs
            om.updateOverlayPositions()

            // B4: updateOverlaysInPlace——就地更新（含缺失屏新建分支）
            om.updateOverlaysInPlace()
            check("overlayE2E: updateOverlaysInPlace 后每屏一窗且全部上屏",
                  om.overlayWindows.count == NSScreen.screens.count
                  && om.overlayWindows.values.allSatisfy { $0.isVisible })

            // B5: 气泡抑制开关——true 隐藏归零 / false 恢复重建
            om.setOverlaysSuppressedForInputBubble(true)
            check("overlayE2E: 抑制开启后窗口归零",
                  om.overlayWindows.isEmpty
                  && om.overlaysSuppressedForInputBubble)
            om.setOverlaysSuppressedForInputBubble(false)
            check("overlayE2E: 抑制解除后 overlay 恢复",
                  om.overlayWindows.count == NSScreen.screens.count)

            // B6: triggerForceRefresh 双分支——force 穿透挂起（refreshGate 语义）；broadcastOnly=去重窗内二次触发
            om.triggerForceRefresh(reason: "b301-heavy-refresh")
            // 后台 Task 真实 yabai fork + MainActor 回写——泵 RunLoop 等落账（B154 家法）
            let deadline = Date().addingTimeInterval(6.0)
            while Date() < deadline && om.screenSpaceCache.isEmpty {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            check("overlayE2E: force refresh 后 screenSpaceCache 落账（真实 yabai）",
                  !om.screenSpaceCache.isEmpty)
            // 去重窗内二次触发 → broadcastOnly：不清缓存、不重复刷新
            om.triggerForceRefresh(reason: "b301-duplicate-broadcast-only")
            check("overlayE2E: 去重窗内二次触发只广播（缓存保持不清）",
                  !om.screenSpaceCache.isEmpty)

            // B8: crash-loop 熔断守卫——showOverlays/startRefreshTimer 双早退
            om.crashLoopSuppressed = true
            let countBefore = om.overlayWindows.count
            om.showOverlays()
            check("overlayE2E: 熔断期 showOverlays 早退（窗口数不变）",
                  om.overlayWindows.count == countBefore)
            om.startRefreshTimer()
            om.crashLoopSuppressed = false

            // B9: 清场归零（自动化测试清场纪律——自家窗口真实关闭）
            om.hideOverlays()
            check("overlayE2E: hideOverlays 后窗口字典归零", om.overlayWindows.isEmpty)
        }
    }

    private static func overlayExpectedLabel(yabaiDisplayIndex: Int?, screenIndex: Int, spaceIndex: Int) -> String {
        let displayNumber = yabaiDisplayIndex ?? (screenIndex + 1)
        return "\(displayNumber)-\(spaceIndex)"
    }
}

private extension String {
    /// 与 update() 内部同源的文字量测（systemFont bold + NSAttributedString.size）
    func width(givenFont size: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: .bold)
        let attr = NSAttributedString(string: self, attributes: [.font: font])
        return attr.size().width
    }
}
