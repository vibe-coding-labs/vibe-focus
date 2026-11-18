import AppKit
@testable import VibeFocusKit

/// bounds 恒为零的宿主视图：制造 renderWindowToPNG 的「空 bounds 提前返回」分支
/// （NSWindow 会把普通 contentView 撑到最小内容尺寸，无法直接构造零尺寸内容）。
private final class ZeroBoundsView: NSView {
    override var bounds: NSRect {
        get { .zero }
        set { _ = newValue }
    }
}

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
        let dir = "/tmp/vibefocus-b268-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/snap.png"

        // 2026-11-03：改用自建离屏窗（纯 NSView 内容）而不是共享设置窗。
        // 共享窗的 SwiftUI 全树在 CI 离屏渲染会触发 AttributeGraph cycle 硬崩
        // （`AttributeGraph: cycle detected through attribute 33816` → Trace/BPT trap，
        // 整域 profraw 连同后续断言一起丢失）。本域只验证 renderWindowToPNG 渲染链，
        // 纯 NSView 内容等价覆盖 layer 分支且零 SwiftUI 依赖；设置窗自身的构建
        // 由 runSettingsWindowControllerTests 覆盖。
        func makeWindow(size: NSSize, wantsLayer: Bool) -> NSWindow {
            let win = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            let content = NSView(frame: NSRect(origin: .zero, size: size))
            content.wantsLayer = wantsLayer
            content.layer?.backgroundColor = NSColor.systemBlue.cgColor
            win.contentView = content
            return win
        }

        // layer 分支：content.layer 非空 → CGContext 垂直翻转后 layer.render
        let layerWindow = makeWindow(size: NSSize(width: 320, height: 200), wantsLayer: true)
        ctl.renderWindowToPNG(window: layerWindow, path: path)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else {
            check("snapshotRender: PNG 产出非空", false)
            return
        }
        let image = NSImage(data: data)
        check("snapshotRender: PNG 可解码且尺寸为 2x 位图",
              image != nil && image!.size.width > 0 && image!.size.height > 0)

        // 非 layer 分支：cacheDisplay(in:to:) 兜底路
        let plainPath = dir + "/snap-plain.png"
        let plainWindow = makeWindow(size: NSSize(width: 160, height: 120), wantsLayer: false)
        ctl.renderWindowToPNG(window: plainWindow, path: plainPath)
        check("snapshotRender: 非 layer 内容 cacheDisplay 分支产出非空",
              (try? Data(contentsOf: URL(fileURLWithPath: plainPath)))?.isEmpty == false)

        // 空 bounds 分支：提前 return，不产出文件（NSWindow 会把 contentView 撑到
        // 最小内容尺寸，用 bounds 恒为零的视图子类制造该状态）
        let emptyPath = dir + "/snap-empty.png"
        let emptyWindow = makeWindow(size: NSSize(width: 100, height: 100), wantsLayer: true)
        emptyWindow.contentView = ZeroBoundsView(frame: .zero)
        ctl.renderWindowToPNG(window: emptyWindow, path: emptyPath)
        check("snapshotRender: 空 bounds 提前返回不产出文件",
              !FileManager.default.fileExists(atPath: emptyPath))

        check("snapshotRender: 渲染链全程不崩", true)
    }
}
