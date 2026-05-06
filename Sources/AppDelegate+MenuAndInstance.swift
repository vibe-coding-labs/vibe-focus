import AppKit
import SwiftUI
import Foundation
import Darwin

extension AppDelegate {


    func setupMenuBar() {
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


    func loadStatusBarImage() -> NSImage? {
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
        log("[Menu] open settings clicked")
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


    func findExistingInstance() -> ExistingInstanceInfo? {
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


    func applyApplicationIcon() {
        log("AppDelegate.applyApplicationIcon entry", level: .debug)
        guard let icon = bundledAppIconImage() else {
            return
        }
        NSApp.applicationIconImage = icon
    }

    func enforceExpectedInstallLocation() -> Bool {
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


    func promptAccessibilityIfNeeded() {
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
