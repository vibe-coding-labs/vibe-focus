import AppKit
import Foundation

/// Manages the dock badge indicator for active window focus sessions.
@MainActor
final class DockBadgeManager {
    static let shared = DockBadgeManager()

    private var pendingCount = 0

    private static var terminalBundleIDs: Set<String> { TerminalRegistry.allTerminalAndIDEBundleIDs }

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    func showBadge(targetBundleID: String? = nil, targetAppName: String? = nil) {
        // P-INST-111: dock badge 显示耗时（NSApp.dockTile.badgeLabel 设置 + bounceTerminalApp P-INST-112 进程枚举激活；hook window-move 路径 HookEventHandler+WindowMove+Execute:227 调用）。
        let sbStart = Date()
        defer {
            log("[DockBadgeManager] showBadge finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: sbStart))
            ])
        }
        pendingCount += 1
        NSApp.dockTile.badgeLabel = String(pendingCount)

        log("[DockBadgeManager] badge shown", fields: [
            "count": String(pendingCount)
        ])

        bounceTerminalApp(bundleID: targetBundleID, appName: targetAppName)
    }

    func clearBadge() {
        guard pendingCount > 0 else { return }
        log("[DockBadgeManager] badge cleared", fields: [
            "previousCount": String(pendingCount)
        ])
        pendingCount = 0
        NSApp.dockTile.badgeLabel = nil
    }

    @objc private func appDidBecomeActive() {
        clearBadge()
    }

    private func bounceTerminalApp(bundleID: String?, appName: String?) {
        // P-INST-112: 终端 app 激活/弹跳耗时（NSRunningApplication.runningApplications 进程枚举 by bundleID 或 NSWorkspace.shared.runningApplications 全枚举 by name + app.activate；showBadge P-INST-111 子阶段，hook window-move 路径；进程枚举可阻塞）。
        let btStart = Date()
        defer {
            log("[DockBadgeManager] bounceTerminalApp finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: btStart))
            ])
        }
        if let bid = bundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
            app.activate(options: .activateIgnoringOtherApps)
            log("[DockBadgeManager] bounced terminal app via bundleID", fields: [
                "bundleID": bid
            ])
            return
        }

        if let name = appName {
            let matching = NSWorkspace.shared.runningApplications.first { app in
                app.localizedName?.contains(name) == true
            }
            if let app = matching {
                app.activate(options: .activateIgnoringOtherApps)
                log("[DockBadgeManager] bounced terminal app via name", fields: [
                    "appName": name
                ])
                return
            }
        }

        log("[DockBadgeManager] could not find terminal app to bounce", level: .warn, fields: [
            "bundleID": bundleID ?? "nil",
            "appName": appName ?? "nil"
        ])
    }
}
