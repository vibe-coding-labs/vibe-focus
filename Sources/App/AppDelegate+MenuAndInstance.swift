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

        // 摆位子菜单（Rectangle 式；热键标注见热键表）
        let layoutSubmenu = NSMenu()
        for action in LayoutAction.allCases {
            let item = NSMenuItem(
                title: action.displayName,
                action: #selector(layoutMenuItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = action.rawValue
            layoutSubmenu.addItem(item)
        }
        let layoutItem = NSMenuItem(title: "摆位", action: nil, keyEquivalent: "")
        layoutItem.submenu = layoutSubmenu
        layoutSubmenuItem = layoutItem
        menu.addItem(layoutItem)

        // 终端网格子菜单
        let gridSubmenu = NSMenu()
        let gridCreateItem = NSMenuItem(title: "创建网格（按设置行列）", action: #selector(gridCreateMenuItem), keyEquivalent: "")
        gridCreateItem.target = self
        gridSubmenu.addItem(gridCreateItem)
        let gridCaptureItem = NSMenuItem(title: "捕获当前布局（记住位置 + Claude session）", action: #selector(gridCaptureMenuItem), keyEquivalent: "")
        gridCaptureItem.target = self
        gridSubmenu.addItem(gridCaptureItem)
        let gridRestoreItem = NSMenuItem(title: "恢复上次布局（自动 claude --resume）", action: #selector(gridRestoreMenuItem), keyEquivalent: "")
        gridRestoreItem.target = self
        gridSubmenu.addItem(gridRestoreItem)
        let gridItem = NSMenuItem(title: "终端网格", action: nil, keyEquivalent: "")
        gridItem.submenu = gridSubmenu
        menu.addItem(gridItem)

        menu.addItem(.separator())

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
        #if PERF_INSTRUMENT
        let lsbStart = Date()
        defer {
            log("[AppDelegate] loadStatusBarImage finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: lsbStart))
            ])
        }
        #endif
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
        let conflictSuffix: String
        if LayoutPreferences.isEnabled {
            conflictSuffix = ""
        } else if let conflict = layoutConflictDetected {
            conflictSuffix = "（热键已停用：检测到 \(conflict)）"
        } else {
            conflictSuffix = "（热键已停用）"
        }
        layoutSubmenuItem?.title = "摆位\(conflictSuffix)"
    }

    @objc func layoutMenuItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = LayoutAction(rawValue: raw) else {
            return
        }
        let op = makeOperationID(prefix: "menu-layout")
        log("[Menu] layout action clicked", fields: ["op": op, "action": action.rawValue])
        WindowManager.shared.applyLayoutAction(action, triggerSource: "menu", operationID: op)
    }

    @objc func gridCreateMenuItem() {
        Task {
            let result = await TerminalGridController.shared.createGrid()
            presentGridResultIfNeeded(result)
        }
    }

    @objc func gridCaptureMenuItem() {
        Task {
            let result = await TerminalGridController.shared.captureLayout()
            presentGridResultIfNeeded(result)
        }
    }

    @objc func gridRestoreMenuItem() {
        Task {
            let result = await TerminalGridController.shared.restoreLayout()
            presentGridResultIfNeeded(result)
        }
    }

    /// 失败才弹窗（成功时窗口已经出现在屏幕上，无需打扰）
    private func presentGridResultIfNeeded(_ result: TerminalGridController.OperationResult) {
        guard !result.ok else { return }
        let alert = NSAlert()
        alert.messageText = "终端网格"
        alert.informativeText = result.message
        alert.alertStyle = .warning
        alert.runModal()
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
        #if PERF_INSTRUMENT
        let osStart = Date()
        defer {
            log("[App] openSettings finished", level: .debug, fields: ["durationMs": String(elapsedMilliseconds(since: osStart))])
        }
        #endif
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
        #if PERF_INSTRUMENT
        let aelStart = Date()
        defer {
            log("[AppDelegate] acquireExclusiveLock finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: aelStart))
            ])
        }
        #endif
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
        #if PERF_INSTRUMENT
        let feiStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: feiStart)
            if durMs >= 50 { log("[AppDelegate] findExistingInstance slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        #endif
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
        #if PERF_INSTRUMENT
        let aaiStart = Date()
        defer {
            log("[AppDelegate] applyApplicationIcon finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: aaiStart))
            ])
        }
        #endif
        guard let icon = bundledAppIconImage() else {
            return
        }
        NSApp.applicationIconImage = icon
    }

    func enforceExpectedInstallLocation() -> Bool {
        // P-INST-95: 安装位置校验耗时（Bundle.main.bundleURL + isAllowedDevelopmentBundlePath + fileExists 检查预期路径 + 可能触发 NSWorkspace.open 重定位；启动路径调用；启动延迟归因）。
        #if PERF_INSTRUMENT
        let eeiStart = Date()
        defer {
            log("[AppDelegate] enforceExpectedInstallLocation finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: eeiStart))
            ])
        }
        #endif
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
        #if PERF_INSTRUMENT
        let paiStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: paiStart)
            if durMs >= 50 { log("[App] promptAccessibilityIfNeeded slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        #endif
        guard HotKeyManager.shared.accessibilityGranted == false else {
            return
        }
        log("Accessibility not granted; opening System Settings.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            HotKeyManager.shared.openAccessibilitySettings()
        }
    }
}
