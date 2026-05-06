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

// MARK: - 主程序
@main
struct VibeFocusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(HotKeyManager.shared)
        }
    }
}

// MARK: - App Delegate
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var toggleMenuItem: NSMenuItem?
    private let openSettingsDistributedNotification = Notification.Name("com.vibefocus.app.open-settings")

    private struct ExistingInstanceInfo {
        let app: NSRunningApplication
        let version: String?
        let path: String?
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installCrashSignalHandlers()
        installAtExitHandler()
        log("applicationDidFinishLaunching bundle=\(Bundle.main.bundleIdentifier ?? "nil") path=\(Bundle.main.bundleURL.path)")
        logDiagnostics("launch")
        CrashContextRecorder.shared.bootstrap()
        NativeSpaceBridge.logAvailability()
        PreferencesSync.restoreFromDisk()

        // 单实例处理：同版本复用现有进程，不强制重启。
        if let existing = findExistingInstance() {
            let currentVersion = currentAppVersion()
            let existingVersion = existing.version ?? "unknown"
            log("Found existing instance pid=\(existing.app.processIdentifier) version=\(existingVersion) path=\(existing.path ?? "nil")")
            CrashContextRecorder.shared.record("existing_instance_detected pid=\(existing.app.processIdentifier) version=\(existingVersion)")

            if existing.version == nil || existing.version == currentVersion {
                log("Reusing existing same-version instance; activating and opening settings")
                CrashContextRecorder.shared.record("reuse_existing_instance pid=\(existing.app.processIdentifier)")
                requestExistingInstanceOpenSettings()
                existing.app.activate(options: [.activateAllWindows])
                NSApp.terminate(nil)
                return
            }

            log("Existing instance version differs (current=\(currentVersion), existing=\(existingVersion)); terminating old instance")
            CrashContextRecorder.shared.record("terminate_old_instance pid=\(existing.app.processIdentifier)")
            existing.app.terminate()
            Thread.sleep(forTimeInterval: 0.3)
            if !existing.app.isTerminated {
                kill(existing.app.processIdentifier, SIGTERM)
                Thread.sleep(forTimeInterval: 0.2)
            }
        }

        // 获取锁（不同版本替换场景下应能成功）
        if !acquireExclusiveLock() {
            log("Failed to acquire lock after terminating old instance, retrying...")
            CrashContextRecorder.shared.record("lock_retry")
            Thread.sleep(forTimeInterval: 0.5)
            if !acquireExclusiveLock() {
                log("Still cannot acquire lock, terminating self")
                CrashContextRecorder.shared.record("lock_failed_terminate")
                NSApp.terminate(nil)
                return
            }
        }

        guard enforceExpectedInstallLocation() else {
            return
        }
        applyApplicationIcon()
        setupMenuBar()
        HotKeyManager.shared.setup()
        PreferencesSync.persistToDisk()
        ClaudeHookServer.shared.applyPreferences()
        ScreenOverlayManager.shared.refreshOverlays()
        ShutdownSnapshotManager.shared.start()
        TerminalRestoreService.shared.checkAndRestore()
        promptAccessibilityIfNeeded()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                SessionWindowRegistry.shared.purgeClosedWindows()
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshMenuLabels),
            name: .hotKeyConfigurationDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleOpenSettingsRequest(_:)),
            name: openSettingsDistributedNotification,
            object: nil
        )
        showSettingsWindowOnLaunch()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        log("applicationShouldHandleReopen hasVisibleWindows=\(flag)")
        SettingsWindowController.shared.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        ScreenOverlayManager.shared.flushPendingPreferenceSave(reason: "application_will_terminate")
        PreferencesSync.persistToDiskAndWait()
        CrashContextRecorder.shared.markCleanExit()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        log("setupMenuBar called")
        if let button = statusItem?.button {
            if let image = loadStatusBarImage() {
                log("Setting image to status bar")
                button.image = image
                button.imagePosition = .imageOnly
                button.title = ""
            } else if let fallbackSymbol = fallbackStatusBarSymbolImage() {
                log("Using SF Symbol fallback for status bar")
                button.image = fallbackSymbol
                button.imagePosition = .imageOnly
                button.title = ""
            } else {
                log("Failed to load status bar image/symbol, using text fallback")
                button.image = nil
                button.title = "VF"
            }
        }

        let menu = NSMenu()
        let toggleItem = NSMenuItem(title: "", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        toggleMenuItem = toggleItem
        menu.addItem(toggleItem)

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        refreshMenuLabels()
    }

    private func loadStatusBarImage() -> NSImage? {
        log("loadStatusBarImage: bundle path=\(Bundle.main.bundleURL.path)")

        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "StatusBarIcon", withExtension: "png") {
            candidates.append(bundled)
        }
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("StatusBarIcon.png"))
        }

        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(currentDirectory.appendingPathComponent("assets/StatusBarIcon.png"))

        if let executableURL = Bundle.main.executableURL {
            let releaseDir = executableURL.deletingLastPathComponent()
            let repoRoot = releaseDir
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            candidates.append(repoRoot.appendingPathComponent("assets/StatusBarIcon.png"))
        }

        var seenPaths: Set<String> = []
        for candidate in candidates where seenPaths.insert(candidate.path).inserted {
            if FileManager.default.fileExists(atPath: candidate.path),
               let image = NSImage(contentsOf: candidate) {
                log("loadStatusBarImage: Loaded from \(candidate.path) size=\(image.size)")
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                return image
            }
        }

        log("loadStatusBarImage: no usable icon found in candidates")
        return nil
    }

    private func fallbackStatusBarSymbolImage() -> NSImage? {
        guard let image = NSImage(
            systemSymbolName: "viewfinder.circle",
            accessibilityDescription: "VibeFocus"
        ) else {
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
        let op = makeOperationID(prefix: "menu-toggle")
        log(
            "[Menu] toggle clicked",
            fields: [
                "op": op,
                "frontmost": frontmostAppDescriptor()
            ]
        )
        WindowManager.shared.toggle(operationID: op, triggerSource: "menu")
    }

    @objc private func openSettings() {
        log("[Menu] open settings clicked")
        DispatchQueue.main.async {
            SettingsWindowController.shared.show(shouldFocus: true)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func handleAppBecameActive() {
        let startedAt = Date()
        applyApplicationIcon()
        HotKeyManager.shared.refreshAccessibilityStatus()
        logOperationDuration(
            "[AppDelegate] didBecomeActive handled",
            startedAt: startedAt,
            warnThresholdMs: 140,
            fields: [
                "frontmost": frontmostAppDescriptor(),
                "axTrusted": String(HotKeyManager.shared.accessibilityGranted)
            ]
        )
    }

    @objc private func handleOpenSettingsRequest(_ notification: Notification) {
        log(
            "Received distributed open-settings request",
            fields: [
                "frontmost": frontmostAppDescriptor()
            ]
        )
        DispatchQueue.main.async {
            SettingsWindowController.shared.show(shouldFocus: true)
        }
    }

    private func showSettingsWindowOnLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            log("Showing settings window on launch")
            SettingsWindowController.shared.show(shouldFocus: false)
        }
    }

    private func requestExistingInstanceOpenSettings() {
        DistributedNotificationCenter.default().post(
            name: openSettingsDistributedNotification,
            object: nil,
            userInfo: nil
        )
    }

    private func currentAppVersion() -> String {
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        if let bundleVersion, !bundleVersion.isEmpty {
            return bundleVersion
        }
        return AppVersion.current
    }

    private func installedVersion(for app: NSRunningApplication) -> String? {
        guard let bundleURL = app.bundleURL,
              let bundle = Bundle(url: bundleURL) else {
            return nil
        }
        let shortVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        if let shortVersion, !shortVersion.isEmpty {
            return shortVersion
        }
        let buildVersion = bundle.infoDictionary?["CFBundleVersion"] as? String
        if let buildVersion, !buildVersion.isEmpty {
            return buildVersion
        }
        return nil
    }

    // MARK: - Single Instance Check

    // 文件锁路径，用于防止竞态条件
    private let lockFilePath = "/tmp/VibeFocus.lock"

    private func acquireExclusiveLock() -> Bool {
        log("AppDelegate.acquireExclusiveLock entry", level: .debug, fields: ["lockFilePath": lockFilePath])
        let fd = open(lockFilePath, O_CREAT | O_RDWR, 0o644)
        guard fd != -1 else {
            log("Failed to open lock file")
            return false
        }

        // 尝试获取排他锁（非阻塞）
        let result = flock(fd, LOCK_EX | LOCK_NB)
        if result == -1 {
            // 锁已被占用，关闭文件描述符
            log("AppDelegate.acquireExclusiveLock failed, lock held by another process", level: .debug)
            close(fd)
            return false
        }

        // 成功获取锁，保持文件描述符打开以维持锁
        // 注意：文件描述符会在进程退出时自动关闭，锁会自动释放
        log("Acquired exclusive lock, PID \(ProcessInfo.processInfo.processIdentifier)")
        return true
    }

    private func findExistingInstance() -> ExistingInstanceInfo? {
        log("AppDelegate.findExistingInstance entry", level: .debug)
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier
        let execPath = Bundle.main.executableURL?.resolvingSymlinksInPath().path

        // Get all running processes with the same name
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-eo", "pid,comm", "-c"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            let processName = execPath?.components(separatedBy: "/").last ?? "VibeFocus"

            for line in output.components(separatedBy: .newlines) {
                let components = line.trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }

                guard components.count >= 2,
                      let pid = Int32(components[0]),
                      pid != currentPID else { continue }

                let comm = components[1]
                if comm == processName || comm == "VibeFocus" {
                    log("AppDelegate.findExistingInstance found matching process", level: .debug, fields: ["pid": String(pid), "comm": comm])
                    // Found another instance with same process name
                    // Try to get NSRunningApplication for this PID
                    if let app = NSRunningApplication(processIdentifier: pid) {
                        return ExistingInstanceInfo(
                            app: app,
                            version: installedVersion(for: app),
                            path: app.bundleURL?.path
                        )
                    }
                }
            }
        } catch {
            log("Failed to check for existing instances: \(error)")
        }

        // Fallback: match by bundle ID if available
        if let bundleID = bundleID {
            log("AppDelegate.findExistingInstance fallback to bundle ID match", level: .debug, fields: ["bundleID": bundleID])
            let runningApps = NSWorkspace.shared.runningApplications
            for app in runningApps {
                if app.bundleIdentifier == bundleID && app.processIdentifier != currentPID {
                    log("AppDelegate.findExistingInstance found via bundle ID", level: .debug, fields: ["pid": String(app.processIdentifier)])
                    return ExistingInstanceInfo(
                        app: app,
                        version: installedVersion(for: app),
                        path: app.bundleURL?.path
                    )
                }
            }
        }

        return nil
    }

    private func applyApplicationIcon() {
        log("AppDelegate.applyApplicationIcon entry", level: .debug)
        guard let icon = bundledAppIconImage() else {
            return
        }
        NSApp.applicationIconImage = icon
    }

    private func expectedAppBundlePaths() -> [String] {
        let home = NSHomeDirectory()
        return [
            (home as NSString).appendingPathComponent("Applications/VibeFocus.app"),
            (home as NSString).appendingPathComponent("Applications/VibeFocus.app"),
            "/Applications/VibeFocus.app",
            "/Applications/VibeFocus.app"
        ]
    }

    private func isAllowedDevelopmentBundlePath(_ path: String) -> Bool {
        path.hasSuffix("/dist/VibeFocus.app") || path.hasSuffix("/dist/VibeFocus.app")
    }

    @discardableResult
    private func enforceExpectedInstallLocation() -> Bool {
        log("AppDelegate.enforceExpectedInstallLocation entry", level: .debug)
        let actualURL = Bundle.main.bundleURL
        let actual = actualURL.path
        if actualURL.pathExtension != "app" {
            log("Skipping install-location enforcement for direct binary run: \(actual)")
            log("AppDelegate.enforceExpectedInstallLocation binary run, returning true", level: .debug)
            return true
        }

        if isAllowedDevelopmentBundlePath(actual) {
            log("Skipping install-location enforcement for development bundle path: \(actual)")
            log("AppDelegate.enforceExpectedInstallLocation dev path, returning true", level: .debug)
            return true
        }

        let expectedPaths = expectedAppBundlePaths()
        guard !expectedPaths.contains(actual) else {
            log("AppDelegate.enforceExpectedInstallLocation at expected path, returning true", level: .debug, fields: ["actual": actual])
            return true
        }

        log("Unexpected app location. actual=\(actual) expected=\(expectedPaths)")
        logDiagnostics("unexpected_location")

        // Try to open existing copy if found
        for expected in expectedPaths {
            if FileManager.default.fileExists(atPath: expected) {
                NSWorkspace.shared.open(URL(fileURLWithPath: expected))
                break
            }
        }

        showWrongLocationAlert(actual: actual, expectedPaths: expectedPaths)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
        return false
    }

    private func showWrongLocationAlert(actual: String, expectedPaths: [String]) {
        let alert = NSAlert()
        alert.messageText = "VibeFocus 安装位置异常"
        let home = NSHomeDirectory()
        let displayExpected = expectedPaths
            .prefix(2)
            .map { path in
                if path.hasPrefix(home) {
                    return path.replacingOccurrences(of: home, with: "~")
                }
                return path
            }
            .joined(separator: "\n")
        alert.informativeText = "当前运行位置：\n\(actual)\n\n建议位置：\n\(displayExpected)\n或\n/Applications/VibeFocus.app"
        alert.addButton(withTitle: "退出")

        NSApp.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        alert.runModal()
        NSApp.setActivationPolicy(.accessory)
    }

    private func promptAccessibilityIfNeeded() {
        guard HotKeyManager.shared.accessibilityGranted == false else {
            log("AppDelegate.promptAccessibilityIfNeeded already granted, skipping", level: .debug)
            return
        }
        log("Accessibility not granted; opening System Settings.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            HotKeyManager.shared.openAccessibilitySettings()
        }
    }
}
