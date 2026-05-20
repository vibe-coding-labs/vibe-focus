import AppKit
import Foundation

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
