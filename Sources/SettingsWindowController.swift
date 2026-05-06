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
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "VibeFocus 设置"
        window.center()
        window.minSize = NSSize(width: 820, height: 900)
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace]
        window.tabbingMode = .disallowed
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.toolbarStyle = .unifiedCompact
        window.backgroundColor = .clear
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
