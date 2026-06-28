import AppKit
import SwiftUI
import Foundation
import Darwin

extension AppDelegate {

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            if let image = loadStatusBarImage() {
                button.image = image
                button.imagePosition = .imageOnly
                button.title = ""
            } else if let fallbackSymbol = fallbackStatusBarSymbolImage() {
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

    func loadStatusBarImage() -> NSImage? {
        // P-INST-94: 状态栏图标加载耗时（Bundle.main.url/forResource 资源查找 + 多候选路径 fileExists + NSImage 初始化；启动路径 setupMenuBar 调用；启动延迟归因）。
        let lsbStart = Date()
        defer {
            log("[AppDelegate] loadStatusBarImage finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: lsbStart))
            ])
        }
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
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                return image
            }
        }

        log("loadStatusBarImage: no usable icon found in candidates")
        return nil
    }

    func fallbackStatusBarSymbolImage() -> NSImage? {
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

    @objc func refreshMenuLabels() {
        toggleMenuItem?.title = "Toggle (\(HotKeyManager.shared.currentHotKey.displayString))"
    }

    @objc func toggle() {
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

    @objc func openSettings() {
        // P-INST-261: 打开设置窗口入口（DispatchQueue.main.async 调度 SettingsWindowController.show；菜单/通知触发，show 已 logOperationDuration，此处归因入口/触发源）。
        let osStart = Date()
        defer {
            log("[App] openSettings finished", level: .debug, fields: ["durationMs": String(elapsedMilliseconds(since: osStart))])
        }
        DispatchQueue.main.async {
            SettingsWindowController.shared.show(shouldFocus: true)
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    @objc func handleAppBecameActive() {
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

    func acquireExclusiveLock() -> Bool {
        // P-INST-98: 单实例排他锁获取耗时（POSIX open lockFilePath O_CREAT|O_RDWR 创建/打开锁文件 + flock LOCK_EX|LOCK_NB 非阻塞加锁；启动单实例检测；内核文件锁竞争可阻塞）。
        let aelStart = Date()
        defer {
            log("[AppDelegate] acquireExclusiveLock finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: aelStart))
            ])
        }
        let fd = open(lockFilePath, O_CREAT | O_RDWR, 0o644)
        guard fd != -1 else {
            log("Failed to open lock file")
            return false
        }

        let result = flock(fd, LOCK_EX | LOCK_NB)
        if result == -1 {
            close(fd)
            return false
        }

        log("Acquired exclusive lock, PID \(ProcessInfo.processInfo.processIdentifier)")
        return true
    }

    func findExistingInstance() -> ExistingInstanceInfo? {
        // P-INST-209: 单实例检查耗时（NSWorkspace.shared.runningApplications 枚举所有运行进程 + Bundle.main.bundleIdentifier；启动路径调用，runningApplications 可能在多进程系统累积；slow-op ≥50ms warn）。
        let feiStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: feiStart)
            if durMs >= 50 { log("[AppDelegate] findExistingInstance slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier

        if let bundleID {
            let runningApps = NSWorkspace.shared.runningApplications
            for app in runningApps {
                if app.bundleIdentifier == bundleID && app.processIdentifier != currentPID {
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

    func applyApplicationIcon() {
        // P-INST-102: 应用图标应用耗时（bundledAppIconImage 从 Bundle 加载 NSImage + 设置 NSApp.applicationIconImage；启动路径调用；启动延迟归因）。
        let aaiStart = Date()
        defer {
            log("[AppDelegate] applyApplicationIcon finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: aaiStart))
            ])
        }
        guard let icon = bundledAppIconImage() else {
            return
        }
        NSApp.applicationIconImage = icon
    }

    func enforceExpectedInstallLocation() -> Bool {
        // P-INST-95: 安装位置校验耗时（Bundle.main.bundleURL + isAllowedDevelopmentBundlePath + fileExists 检查预期路径 + 可能触发 NSWorkspace.open 重定位；启动路径调用；启动延迟归因）。
        let eeiStart = Date()
        defer {
            log("[AppDelegate] enforceExpectedInstallLocation finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: eeiStart))
            ])
        }
        let actualURL = Bundle.main.bundleURL
        let actual = actualURL.path
        if actualURL.pathExtension != "app" {
            return true
        }

        if isAllowedDevelopmentBundlePath(actual) {
            return true
        }

        let expectedPaths = expectedAppBundlePaths()
        guard !expectedPaths.contains(actual) else {
            return true
        }

        log("Unexpected app location. actual=\(actual) expected=\(expectedPaths)")
        logDiagnostics("unexpected_location")

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

    func promptAccessibilityIfNeeded() {
        // P-INST-262: AX 未授权时延迟打开系统设置入口（accessibilityGranted 缓存检查 + DispatchQueue 0.4s 后调度 openAccessibilitySettings NSWorkspace.open；启动调用，open 可能阻塞；slow-op ≥50ms warn）。
        let paiStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: paiStart)
            if durMs >= 50 { log("[App] promptAccessibilityIfNeeded slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        guard HotKeyManager.shared.accessibilityGranted == false else {
            return
        }
        log("Accessibility not granted; opening System Settings.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            HotKeyManager.shared.openAccessibilitySettings()
        }
    }
}
