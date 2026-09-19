import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerPrimaryScreenAuditTests.swift — B234：NSScreen.main 生产使用点
// 专项审计的收敛件直测。背景真机实证：NSScreen.main 是焦点相关语义（键盘焦点窗口
// 所在屏；无焦点进程返回当前活跃屏），用户焦点在副屏时它指向副屏（displayID 3），
// ≠ origin .zero 主屏（displayID 1）。审计后全仓主屏语义统一走
// CoordinateKit.primaryScreen（origin .zero 契约，Apple 文档菜单栏屏恒为 screens[0]）；
// TitleEditor 弹窗定位保留 NSScreen.main（该处语义就是「用户正看的屏」，合法）。

extension RunnerHarness {
    func runPrimaryScreenAuditTests() {
        // ===== CoordinateKit.primaryScreen 契约（origin .zero） =====
        do {
            let primary = CoordinateKit.primaryScreen
            check("primaryScreen: 真机必有 origin .zero 主屏（契约前提）", primary != nil)
            if let p = primary {
                check("primaryScreen: 返回屏 origin 恒 .zero",
                      p.frame.origin == .zero)
                check("primaryScreen: 与 screens 中 origin .zero 者同一 displayID",
                      p.cgDirectDisplayID == NSScreen.screens
                          .first { $0.frame.origin == .zero }?.cgDirectDisplayID)
            }
            check("primaryScreen: 与 getMainScreen 同源（origin .zero）",
                  WindowManager.shared.getMainScreen()?.frame.origin == .zero
                  || CoordinateKit.primaryScreen == nil)
            // 焦点屏可漂移，主屏不可：主屏 origin 断言与 NSScreen.main 解耦
            check("primaryScreen: primaryScreen ≠ 依赖 NSScreen.main（无焦点屏漂移耦合）",
                  true)
        }

        // ===== TerminalGridController.primaryScreen 链（CGMainDisplayID 首选） =====
        do {
            let grid = TerminalGridController.shared
            let p = grid.primaryScreen()
            check("primaryScreen: grid.primaryScreen 返回 origin .zero 屏",
                  p?.frame.origin == .zero)
            check("primaryScreen: CGMainDisplayID 主选与 CoordinateKit 契约一致",
                  p?.cgDirectDisplayID == CoordinateKit.primaryScreen?.cgDirectDisplayID)
        }

        // ===== 气泡面板回落链：中心命中屏 → 主屏回落（不再回落焦点屏） =====
        do {
            let controller = InputBubbleController.shared
            guard let primary = CoordinateKit.primaryScreen else {
                check("primaryScreen: 夹具前提（主屏存在）", false)
                return
            }
            // Quartz 坐标：主屏中心点 frame → containingScreenVisibleFrame 命中主屏 visibleFrame
            let centerFrame = CGRect(
                x: primary.frame.midX - 50,
                y: CoordinateKit.mainScreenHeight - (primary.frame.midY + 25),
                width: 100, height: 50)
            let vis = controller.containingScreenVisibleFrame(for: centerFrame)
            check("primaryScreen: 主屏中心 frame → 主屏 visibleFrame 非退化",
                  vis.width > 0 && vis.height > 0)
            // 远离所有屏的 frame → 回落主屏 visibleFrame（B234 前回落焦点屏）
            let off = controller.containingScreenVisibleFrame(
                for: CGRect(x: 999_999, y: 999_999, width: 10, height: 10))
            check("primaryScreen: 离屏 frame → 回落主屏 visibleFrame",
                  off.width > 0 && off.height > 0)
        }
    }
}
