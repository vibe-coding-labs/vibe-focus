import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerMenuBarTests.swift — B249：菜单栏构建族直测（AppDelegate+Menu.swift
// 此前 0%——218 行未覆盖大头）。
//
// 安全边界：只测「构建与只读」——setupMenuBar（NSStatusItem 瞬态创建，voiceYield 状态项
// 先例；测试后 removeStatusItem 收尾不留菜单栏残留）、图标加载、标签刷新、layoutMenuItem
// 守卫早退、handleAppBecameActive（applyApplicationIcon + refreshAccessibilityStatus
// 均无弹窗无 fork）。绝不触碰 toggle/grid 三动作/quit/openSettings——那些是真实窗口作业
// 与进程退出；presentGridResultIfNeeded 的 runModal 在 CLI 会挂死，留白。

extension RunnerHarness {
    func runMenuBarTests() {
        let ad = AppDelegate()

        // ===== A. 状态栏图标双路（Bundle.main 无资源 → nil；SF Symbol 兜底恒可造） =====
        let icon = ad.loadStatusBarImage()
        check("menuBar: 图标加载 nil 或 18×18 template",
              icon == nil || (icon != nil && icon!.size == NSSize(width: 18, height: 18) && icon!.isTemplate))
        let fallback = ad.fallbackStatusBarSymbolImage()
        check("menuBar: SF Symbol 兜底图标可造", fallback != nil)

        // ===== B. setupMenuBar 全建：结构断言 + 瞬态状态项收尾 =====
        ad.setupMenuBar()
        check("menuBar: 状态项已创建", ad.statusItem != nil)
        check("menuBar: toggle 菜单项已挂接", ad.toggleMenuItem != nil && ad.toggleMenuItem?.target != nil)
        check("menuBar: 摆位子菜单已挂接", ad.layoutSubmenuItem != nil)

        let menu = ad.statusItem?.menu
        check("menuBar: 主菜单非空", menu != nil && menu!.items.count >= 6)
        // 摆位子菜单项数 = LayoutAction 全量（每项 representedObject 携带 rawValue）
        let layoutSubmenu = ad.layoutSubmenuItem?.submenu
        check("menuBar: 摆位子菜单覆盖全部 LayoutAction",
              layoutSubmenu?.items.count == LayoutAction.allCases.count
              && layoutSubmenu?.items.allSatisfy { $0.representedObject is String } == true)
        // 网格子菜单三项（创建/捕获/恢复）——只验结构，绝不触发
        let gridSubmenu = menu?.items.first(where: { $0.title == "终端网格" })?.submenu
        check("menuBar: 网格子菜单三项", gridSubmenu?.items.count == 3)
        check("menuBar: 设置与 Quit 项在位",
              menu?.items.contains(where: { $0.title == "设置…" }) == true
              && menu?.items.contains(where: { $0.title == "Quit" }) == true)

        // ===== C. refreshMenuLabels 三分支（isEnabled 取真实值，conflict 走注入） =====
        // setupMenuBar 尾已调用过一次；这里补注入分支。热键标注随真实 HotKeyManager 态。
        check("menuBar: toggle 标签含热键标注",
              ad.toggleMenuItem?.title.isEmpty == false)
        if LayoutPreferences.isEnabled {
            check("menuBar: 启用态摆位标签无停用后缀", ad.layoutSubmenuItem?.title == "摆位")
        } else {
            ad.layoutConflictDetected = "Runner 冲突探针"
            ad.refreshMenuLabels()
            check("menuBar: 冲突态标签含冲突源与停用后缀",
                  ad.layoutSubmenuItem?.title.contains("Runner 冲突探针") == true
                  && ad.layoutSubmenuItem?.title.contains("热键已停用") == true)
            ad.layoutConflictDetected = nil
            ad.refreshMenuLabels()
            check("menuBar: 无冲突停用态标签为纯停用后缀",
                  ad.layoutSubmenuItem?.title == "摆位（热键已停用）")
        }

        // ===== D. layoutMenuItem 守卫：representedObject 缺失 → 早退（不触真实摆位） =====
        let bareItem = NSMenuItem(title: "bare", action: nil, keyEquivalent: "")
        ad.layoutMenuItem(bareItem)
        let wrongItem = NSMenuItem(title: "wrong", action: nil, keyEquivalent: "")
        wrongItem.representedObject = "no-such-action"
        ad.layoutMenuItem(wrongItem)
        check("menuBar: 非法 representedObject 守卫早退不崩", true)

        // ===== E. handleAppBecameActive：图标+AX 状态刷新（无弹窗无 fork，只读） =====
        ad.handleAppBecameActive()
        check("menuBar: didBecomeActive 处理不崩", true)

        // ===== 收尾：移除瞬态状态项，不留菜单栏残留 =====
        if let item = ad.statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        ad.statusItem = nil
    }
}
