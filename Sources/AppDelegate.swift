import SwiftUI
import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var toggleMenuItem: NSMenuItem?
    private var launchWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("applicationDidFinishLaunching")
        logDiagnostics("launch")

        // 显示启动窗口
        showLaunchWindow()

        // 执行启动序列
        Task {
            await AppLauncher.shared.launch()

            // 启动完成后设置 UI
            if AppLauncher.shared.canProceed {
                await MainActor.run {
                    self.setupMenuBar()
                    self.closeLaunchWindow()
                    self.showSettingsWindowOnLaunch()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ScreenOverlayManager.shared.unregisterYabaiSignals()
        ClaudeHookServer.shared.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }

    // MARK: - Launch Window

    private func showLaunchWindow() {
        let contentView = AppLaunchView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "VibeFocus"
        window.center()
        window.contentView = NSHostingView(rootView: contentView)
        window.isReleasedWhenClosed = false

        launchWindowController = NSWindowController(window: window)
        launchWindowController?.showWindow(nil)
    }

    private func closeLaunchWindow() {
        launchWindowController?.close()
        launchWindowController = nil
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            if let image = loadStatusBarImage() {
                button.image = image
                button.imagePosition = .imageOnly
            } else {
                button.title = "VF"
            }
        }

        let menu = NSMenu()
        let toggleItem = NSMenuItem(title: "", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        toggleMenuItem = toggleItem
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem?.menu = menu
        refreshMenuLabels()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshMenuLabels),
            name: .hotKeyConfigurationDidChange,
            object: nil
        )
    }

    private func loadStatusBarImage() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "StatusBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    @objc private func refreshMenuLabels() {
        toggleMenuItem?.title = "Toggle (\(HotKeyManager.shared.currentHotKey.displayString))"
    }

    @objc private func toggle() {
        WindowManager.shared.toggle()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show(shouldFocus: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showSettingsWindowOnLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            SettingsWindowController.shared.show(shouldFocus: false)
        }
    }
}
