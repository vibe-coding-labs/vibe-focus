import AppKit
import SwiftUI
import Foundation

// Sources/App/AppDelegate+Menu.swift — B158 自 AppDelegate+MenuAndInstance.swift 按域拆出
//（逐字搬移零行为变更）：菜单栏构建/状态栏图标/菜单动作（toggle·网格三动作·设置·退出）。
// 单实例锁与安装完整性在 +Instance.swift。

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
}
