import AppKit
import SwiftUI
import Foundation

// MARK: - App Delegate
@MainActor
public class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var toggleMenuItem: NSMenuItem?
    let openSettingsDistributedNotification = Notification.Name("com.vibefocus.app.open-settings")

    struct ExistingInstanceInfo {
        let app: NSRunningApplication
        let version: String?
        let path: String?
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
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

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        log("applicationShouldHandleReopen hasVisibleWindows=\(flag)")
        SettingsWindowController.shared.show()
        return true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        ScreenOverlayManager.shared.flushPendingPreferenceSave(reason: "application_will_terminate")
        PreferencesSync.persistToDiskAndWait()
        CrashContextRecorder.shared.markCleanExit()
    }

    @objc func handleOpenSettingsRequest(_ notification: Notification) {
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

    func showSettingsWindowOnLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            log("Showing settings window on launch")
            SettingsWindowController.shared.show(shouldFocus: false)
        }
    }

    func requestExistingInstanceOpenSettings() {
        DistributedNotificationCenter.default().post(
            name: openSettingsDistributedNotification,
            object: nil,
            userInfo: nil
        )
    }

    func currentAppVersion() -> String {
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        if let bundleVersion, !bundleVersion.isEmpty {
            return bundleVersion
        }
        return AppVersion.current
    }

    func installedVersion(for app: NSRunningApplication) -> String? {
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
    let lockFilePath = VFConstants.appLockFilePath

    func expectedAppBundlePaths() -> [String] {
        let home = NSHomeDirectory()
        return [
            (home as NSString).appendingPathComponent("Applications/VibeFocus.app"),
            "/Applications/VibeFocus.app"
        ]
    }

    func isAllowedDevelopmentBundlePath(_ path: String) -> Bool {
        path.hasSuffix("/dist/VibeFocus.app")
    }

    func showWrongLocationAlert(actual: String, expectedPaths: [String]) {
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
}
