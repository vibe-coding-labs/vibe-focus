import AppKit
import SwiftUI
import Foundation

extension ScreenOverlayManager {

    func showOverlays() {
        let screens = NSScreen.screens

        for (index, screen) in screens.enumerated() {
            let uuid = uuidForScreen(screen)

            let overlay = OverlayWindow(screen: screen)

            let spaceIndex = getPerScreenSpaceIndex(for: screen) ?? 1
            log("[DEBUG] showOverlays: screen \(index), per-screen index=\(spaceIndex)")

            overlay.update(screenIndex: index, spaceIndex: spaceIndex, preferences: preferences)
            overlay.updatePosition(for: screen, position: preferences.position, margin: preferences.panelMargin)
            overlay.show()

            overlayWindows[uuid] = overlay
            screenSpaceCache[uuid] = (screenIndex: index, spaceIndex: spaceIndex)
        }

        log("Showed overlays for \(screens.count) screens")
    }

    func hideOverlays() {
        log("ScreenOverlayManager.hideOverlays entry", level: .debug, fields: ["overlayCount": String(overlayWindows.count)])
        for (_, overlay) in overlayWindows {
            overlay.close()  // 使用 close() 完全关闭窗口，而不是仅隐藏
        }
        overlayWindows.removeAll()
        log("Hid all overlays")
        log("ScreenOverlayManager.hideOverlays exit", level: .debug)
    }

    func updateOverlayPositions() {
        log("ScreenOverlayManager.updateOverlayPositions entry", level: .debug, fields: ["screenCount": String(NSScreen.screens.count), "position": preferences.position.rawValue])
        let screens = NSScreen.screens

        for screen in screens {
            let uuid = uuidForScreen(screen)

            if let overlay = overlayWindows[uuid] {
                overlay.updatePosition(for: screen, position: preferences.position, margin: preferences.panelMargin)
            } else {
                log("ScreenOverlayManager.updateOverlayPositions no overlay for screen", level: .debug, fields: ["uuid": uuid.uuidString])
            }
        }
        log("ScreenOverlayManager.updateOverlayPositions exit", level: .debug)
    }

    func updateOverlaysInPlace() {
        log("ScreenOverlayManager.updateOverlaysInPlace entry", level: .debug, fields: ["overlayCount": String(overlayWindows.count), "screenCount": String(NSScreen.screens.count)])
        let screens = NSScreen.screens
        var activeUUIDs: Set<UUID> = []

        for (index, screen) in screens.enumerated() {
            let uuid = uuidForScreen(screen)
            activeUUIDs.insert(uuid)
            let spaceIndex = screenSpaceCache[uuid]?.spaceIndex ?? (getPerScreenSpaceIndex(for: screen) ?? 1)

            if let overlay = overlayWindows[uuid] {
                overlay.update(screenIndex: index, spaceIndex: spaceIndex, preferences: preferences)
                overlay.updatePosition(for: screen, position: preferences.position, margin: preferences.panelMargin)
                overlay.show()
            } else {
                log("ScreenOverlayManager.updateOverlaysInPlace creating new overlay for screen", level: .debug, fields: ["index": String(index), "uuid": uuid.uuidString])
                let overlay = OverlayWindow(screen: screen)
                overlay.update(screenIndex: index, spaceIndex: spaceIndex, preferences: preferences)
                overlay.updatePosition(for: screen, position: preferences.position, margin: preferences.panelMargin)
                overlay.show()
                overlayWindows[uuid] = overlay
            }

            screenSpaceCache[uuid] = (screenIndex: index, spaceIndex: spaceIndex)
        }

        let staleUUIDs = overlayWindows.keys.filter { !activeUUIDs.contains($0) }
        for uuid in staleUUIDs {
            log("ScreenOverlayManager.updateOverlaysInPlace removing stale overlay", level: .debug, fields: ["uuid": uuid.uuidString])
            overlayWindows[uuid]?.close()
            overlayWindows.removeValue(forKey: uuid)
            screenSpaceCache.removeValue(forKey: uuid)
        }

        log("Updated overlays in place for \(screens.count) screens")
    }

    func schedulePreferenceSave() {
        pendingPreferenceSaveWorkItem?.cancel()
        let snapshot = preferences
        let signature = preferenceSignature(snapshot)
        if signature != lastLoggedPreferenceSignature {
            lastLoggedPreferenceSignature = signature
            log(
                "[Overlay] schedule preference save",
                fields: [
                    "signature": signature
                ]
            )
        }
        let workItem = DispatchWorkItem { [weak self] in
            let startedAt = Date()
            snapshot.save()
            self?.pendingPreferenceSaveWorkItem = nil
            logOperationDuration(
                "[Overlay] preference save finished",
                startedAt: startedAt,
                warnThresholdMs: 120,
                fields: [
                    "signature": signature
                ]
            )
        }
        pendingPreferenceSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + preferenceSaveDebounceInterval, execute: workItem)
    }

    func schedulePreferenceRefresh() {
        pendingPreferenceRefreshWorkItem?.cancel()
        let signature = preferenceSignature(preferences)
        log(
            "[Overlay] schedule preference refresh",
            fields: [
                "signature": signature
            ]
        )

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.pendingPreferenceRefreshWorkItem = nil
            self.applyPreferenceRefresh(signature: signature)
        }

        pendingPreferenceRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + preferenceRefreshDebounceInterval, execute: workItem)
    }

    func applyPreferenceRefresh(signature: String) {
        let startedAt = Date()
        guard preferences.isEnabled else {
            hideOverlays()
            logOperationDuration(
                "[Overlay] preference refresh finished",
                startedAt: startedAt,
                warnThresholdMs: 120,
                fields: [
                    "signature": signature,
                    "path": "hide_overlays"
                ]
            )
            return
        }

        if overlayWindows.isEmpty {
            showOverlays()
            logOperationDuration(
                "[Overlay] preference refresh finished",
                startedAt: startedAt,
                warnThresholdMs: 120,
                fields: [
                    "signature": signature,
                    "path": "show_overlays"
                ]
            )
            return
        }

        // Avoid closing/reopening all windows while the user drags sliders in settings.
        // Frequent teardown/rebuild caused unstable AppKit object churn.
        updateOverlaysInPlace()
        logOperationDuration(
            "[Overlay] preference refresh finished",
            startedAt: startedAt,
            warnThresholdMs: 120,
            fields: [
                "signature": signature,
                "path": "update_in_place",
                "overlayCount": String(overlayWindows.count)
            ]
        )
    }

    func preferenceSignature(_ preferences: ScreenIndexPreferences) -> String {
        "enabled=\(preferences.isEnabled)|pos=\(preferences.position.rawValue)|font=\(String(format: "%.1f", preferences.fontSize))|opacity=\(String(format: "%.2f", preferences.opacity))|scale=\(String(format: "%.2f", preferences.panelScale))|margin=\(String(format: "%.1f", preferences.panelMargin))"
    }

    func uuidForScreen(_ screen: NSScreen) -> UUID {
        log("ScreenOverlayManager.uuidForScreen entry", level: .debug, fields: ["screenFrame": String(describing: screen.frame)])
        if let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            // Use the uint32 value as UUID's uuid_t bytes
            var uuidBytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            let value = screenID.uint32Value
            // Store the uint32 in the first 4 bytes
            uuidBytes.0 = UInt8((value >> 24) & 0xFF)
            uuidBytes.1 = UInt8((value >> 16) & 0xFF)
            uuidBytes.2 = UInt8((value >> 8) & 0xFF)
            uuidBytes.3 = UInt8(value & 0xFF)
            return UUID(uuid: uuidBytes)
        }
        // Fallback: use the screen's hash
        log("ScreenOverlayManager.uuidForScreen fallback to hash", level: .debug, fields: ["screenHash": String(screen.hashValue)])
        return UUID(uuid: uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(abs(screen.hashValue % 256))))
    }
}
