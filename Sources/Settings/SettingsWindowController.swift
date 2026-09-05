import AppKit
import SwiftUI
import Foundation

private final class FocusableSettingsWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private init() {
        log("SettingsWindowController.init entry", level: .debug)
        let hostingController = NSHostingController(
            rootView: SettingsView()
                .environmentObject(HotKeyManager.shared)
        )

        let window = FocusableSettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VibeFocus 设置"
        window.center()
        window.minSize = NSSize(width: 780, height: 680)
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace]
        window.tabbingMode = .disallowed
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.toolbarStyle = .unifiedCompact
        window.backgroundColor = VibeColors.backgroundNS
        window.contentViewController = hostingController
        super.init(window: window)
        window.delegate = self
        log("SettingsWindowController.init exit", level: .debug)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(shouldFocus: Bool = true) {
        guard let window else { return }
        let startedAt = Date()
        NSApp.setActivationPolicy(.regular)
        if let icon = bundledAppIconImage() {
            NSApp.applicationIconImage = icon
            window.miniwindowImage = icon
        }
        DispatchQueue.main.async {
            window.center()
            if shouldFocus {
                window.makeMain()
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFront(nil)
            }
            self.maybeSnapshotForDebug()
            logOperationDuration(
                "[SettingsWindow] show finished",
                startedAt: startedAt,
                warnThresholdMs: 180,
                fields: [
                    "shouldFocus": String(shouldFocus),
                    "frontmost": frontmostAppDescriptor()
                ]
            )
        }
    }

    /// 开发快照钩子：设置环境变量 VIBEFOCUS_SETTINGS_SNAPSHOT=<PNG 路径前缀> 时，
    /// 在进程内把设置窗各渲染为亮色/暗色两张 PNG（自窗口 layer 渲染，不经屏幕
    /// 捕获、无 TCC 权限依赖，也不改动系统外观——暗色通过窗口级 appearance 覆写）。
    /// 正常运行（无该环境变量）零开销零副作用。
    private func maybeSnapshotForDebug() {
        guard let prefix = ProcessInfo.processInfo.environment["VIBEFOCUS_SETTINGS_SNAPSHOT"],
              !prefix.isEmpty,
              let window else { return }
        log("[Snapshot] debug snapshot requested, prefix=\(prefix)")
        let modes: [(tag: String, appearance: NSAppearance?)] = [
            ("light", NSAppearance(named: .aqua)),
            ("dark", NSAppearance(named: .darkAqua))
        ]

        func captureMode(_ index: Int) {
            guard index < modes.count else {
                window.appearance = nil
                log("[Snapshot] all captures finished")
                return
            }
            window.appearance = modes[index].appearance
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.renderWindowToPNG(window: window, path: "\(prefix)-\(modes[index].tag).png")
                captureMode(index + 1)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            captureMode(0)
        }
    }

    private func renderWindowToPNG(window: NSWindow, path: String) {
        guard let content = window.contentView else {
            log("[Snapshot] no contentView, skip", level: .warn)
            return
        }
        content.layoutSubtreeIfNeeded()
        let bounds = content.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            log("[Snapshot] empty bounds, skip", level: .warn)
            return
        }
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * 2),
            pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else {
            log("[Snapshot] bitmap rep creation failed", level: .warn)
            return
        }
        rep.size = bounds.size
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            log("[Snapshot] graphics context creation failed", level: .warn)
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        if let layer = content.layer {
            // CALayer 是 y-up 坐标系，与位图上下文相反，先垂直翻转再渲染
            let cg = ctx.cgContext
            cg.saveGState()
            cg.translateBy(x: 0, y: bounds.height)
            cg.scaleBy(x: 1, y: -1)
            layer.render(in: cg)
            cg.restoreGState()
        } else {
            content.cacheDisplay(in: bounds, to: rep)
        }
        NSGraphicsContext.restoreGraphicsState()
        do {
            let data = rep.representation(using: .png, properties: [:])
            try data?.write(to: URL(fileURLWithPath: path))
            log("[Snapshot] wrote \(path)")
        } catch {
            log("[Snapshot] write \(path) failed: \(error.localizedDescription)", level: .warn)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        log(
            "[SettingsWindow] did become key",
            fields: [
                "frontmost": frontmostAppDescriptor()
            ]
        )
        ScreenOverlayManager.shared.suspendAutomaticRefreshes(reason: "settings_window_key")
    }

    func windowDidResignKey(_ notification: Notification) {
        log(
            "[SettingsWindow] did resign key",
            fields: [
                "frontmost": frontmostAppDescriptor()
            ]
        )
        ScreenOverlayManager.shared.resumeAutomaticRefreshes(reason: "settings_window_resign_key")
    }

    func windowWillClose(_ notification: Notification) {
        log("[SettingsWindow] will close")
        window?.orderOut(nil)
        ScreenOverlayManager.shared.resumeAutomaticRefreshes(reason: "settings_window_closed")
        NSApp.setActivationPolicy(.accessory)
    }
}
