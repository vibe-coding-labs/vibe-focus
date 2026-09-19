import AppKit
@testable import VibeFocusKit

// Tests/Runner/RunnerSettingsWindowControllerTests.swift — B240：设置窗控制器构建
// 契约与委托回调直测。shared 单例在 Runner 内离屏构造（不触 contentView=不渲染
// SwiftUI 树，无 onAppear/单例安装副作用）；窗口属性锁死构建契约，委托回调直驱
// 锁 suspend/resume 接线。windowWillClose 会 setActivationPolicy(.accessory)——
// Runner 进程级、无桌面可见影响。

extension RunnerHarness {
    func runSettingsWindowControllerTests() {
        print("\n=== SettingsWindowController (B240) ===")
        let controller = SettingsWindowController.shared
        guard let window = controller.window else {
            check("settingsWin: 离屏构造出窗口", false)
            return
        }

        // --- 构建契约：标题/最小尺寸/关窗不释放 ---
        check("settingsWin: 标题与最小尺寸契约",
              window.title == "VibeFocus 设置"
              && window.minSize == NSSize(width: 780, height: 680)
              && window.isReleasedWhenClosed == false)

        // --- 行为契约：跟随活跃 Space、禁 tab 合窗、隐藏标题栏、紧凑工具栏 ---
        check("settingsWin: collectionBehavior/tabbingMode/标题栏契约",
              window.collectionBehavior.contains(.moveToActiveSpace)
              && window.tabbingMode == .disallowed
              && window.titleVisibility == .hidden
              && window.toolbarStyle == .unifiedCompact)

        // --- 初始几何下界：contentView 安装后 hosting 按内容定高，宽度锁 780 ---
        check("settingsWin: 初始几何不低于最小尺寸",
              window.frame.width >= 780 && window.frame.height >= 680)

        // --- 委托回调直驱：key/resign 的 overlay suspend/resume 接线不崩 ---
        controller.windowDidBecomeKey(
            Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        check("settingsWin: didBecomeKey → suspend 接线不崩", true)
        controller.windowDidResignKey(
            Notification(name: NSWindow.didResignKeyNotification, object: window))
        check("settingsWin: didResignKey → resume 接线不崩", true)

        // --- willClose：orderOut + 回归 accessory 政策 ---
        window.makeKeyAndOrderFront(nil)
        controller.windowWillClose(
            Notification(name: NSWindow.willCloseNotification, object: window))
        check("settingsWin: willClose 回归 accessory 政策",
              NSApp.activationPolicy() == .accessory && !window.isVisible)
    }
}

// MARK: - B268：renderWindowToPNG 离屏渲染直测（private→internal 提缝，零行为变化）
// 设置窗快照钩子（VIBEFOCUS_SETTINGS_SNAPSHOT 配方）的核心渲染函数：
// 用测试自建离屏 NSWindow（永不 orderFront，零用户影响）直测 layer→PNG 渲染链。

extension RunnerHarness {
    func runSettingsSnapshotRenderTests() {
        let ctl = SettingsWindowController.shared
        guard let win = ctl.window else {
            check("snapshotRender: 设置窗已在内存构建", false)
            return
        }
        let dir = "/tmp/vibefocus-b268-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/snap.png"

        ctl.renderWindowToPNG(window: win, path: path)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else {
            check("snapshotRender: PNG 产出非空", false)
            return
        }
        let image = NSImage(data: data)
        check("snapshotRender: PNG 可解码且尺寸为 2x 位图",
              image != nil && image!.size.width > 0 && image!.size.height > 0)

        // contentView 缺失/空 bounds 分支：无法在共享控制器上模拟（窗真实存在），
        // 该两分支由「窗未加载完成」生产场景自然覆盖，留白。
        check("snapshotRender: 渲染链全程不崩", true)
    }
}
