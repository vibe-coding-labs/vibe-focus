import AppKit
import SwiftUI
import Foundation

extension ScreenOverlayManager {

    func showOverlays() {
        // P-INST-74: overlay 显示总耗时（N 屏 getPerScreenSpaceIndex fork 累积 P-INST-73 + OverlayWindow 创建/show；@MainActor 主线程，fork 阻塞 UI）。
        let startedAt = Date()
        let screens = NSScreen.screens

        for (index, screen) in screens.enumerated() {
            let uuid = uuidForScreen(screen)
            let overlay = OverlayWindow(screen: screen)
            let spaceIndex = getPerScreenSpaceIndex(for: screen) ?? 1

            overlay.update(screenIndex: index, spaceIndex: spaceIndex, preferences: preferences)
            overlay.updatePosition(for: screen, position: preferences.position, margin: preferences.panelMargin)
            overlay.show()

            overlayWindows[uuid] = overlay
            screenSpaceCache[uuid] = (screenIndex: index, spaceIndex: spaceIndex)
        }
        logOperationDuration("[Overlay] showOverlays finished", startedAt: startedAt, warnThresholdMs: 100, fields: ["screenCount": String(screens.count)])
    }

    func hideOverlays() {
        // P-INST-265: 隐藏所有 overlay 窗口（NSWindow.close 循环 + 字典清空；偏好禁用/设置窗口获焦时调用，close 触发 WindowServer 同步；slow-op ≥30ms warn）。
        let hoStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: hoStart)
            if durMs >= 30 { log("[Overlay] hideOverlays slow", level: .warn, fields: ["count": String(overlayWindows.count), "durationMs": String(durMs)]) }
        }
        for (_, overlay) in overlayWindows {
            overlay.close()
        }
        overlayWindows.removeAll()
    }

    func updateOverlayPositions() {
        // P-INST-216: overlay 位置批量更新耗时（NSScreen.screens 枚举 + uuidForScreen + overlay.updatePosition N 屏循环；屏幕变化/overlay 刷新调用，轻量版仅更新位置；slow-op ≥30ms warn）。
        let uopStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: uopStart)
            if durMs >= 30 { log("[Overlay] updateOverlayPositions slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        let screens = NSScreen.screens

        for screen in screens {
            let uuid = uuidForScreen(screen)
            if let overlay = overlayWindows[uuid] {
                overlay.updatePosition(for: screen, position: preferences.position, margin: preferences.panelMargin)
            }
        }
    }

    func updateOverlaysInPlace() {
        // P-INST-74: overlay 就地更新总耗时（N 屏循环 + cache miss getPerScreenSpaceIndex fork P-INST-73 + OverlayWindow show + stale cleanup）。
        let startedAt = Date()
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
            overlayWindows[uuid]?.close()
            overlayWindows.removeValue(forKey: uuid)
            screenSpaceCache.removeValue(forKey: uuid)
        }
        logOperationDuration("[Overlay] updateOverlaysInPlace finished", startedAt: startedAt, warnThresholdMs: 100, fields: ["screenCount": String(screens.count)])
    }

    func schedulePreferenceSave() {
        // P-INST-254: 偏好持久化调度入口（cancel 旧 workItem + preferenceSignature 计算 + DispatchWorkItem 异步调度 save；偏好 UI 变更触发，实际 save 在闭包内 logOperationDuration 已覆盖，此处归因调度入口/频率）。
        let spsStart = Date()
        defer {
            log("[Overlay] schedulePreferenceSave finished", level: .debug, fields: ["durationMs": String(elapsedMilliseconds(since: spsStart))])
        }
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
        // P-INST-255: overlay 偏好刷新调度入口（cancel 旧 workItem + DispatchWorkItem 异步调度 applyPreferenceRefresh；偏好 UI 变更触发，实际 applyPreferenceRefresh 已 logOperationDuration 覆盖，此处归因调度入口/频率）。
        let sprStart = Date()
        defer {
            log("[Overlay] schedulePreferenceRefresh finished", level: .debug, fields: ["durationMs": String(elapsedMilliseconds(since: sprStart))])
        }
        pendingPreferenceRefreshWorkItem?.cancel()
        let signature = preferenceSignature(preferences)

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

    /// Generate a deterministic UUID from a display ID — extracted for testability.
    static func uuidFromDisplayID(_ displayID: UInt32) -> UUID {
        var uuidBytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        uuidBytes.0 = UInt8((displayID >> 24) & 0xFF)
        uuidBytes.1 = UInt8((displayID >> 16) & 0xFF)
        uuidBytes.2 = UInt8((displayID >> 8) & 0xFF)
        uuidBytes.3 = UInt8(displayID & 0xFF)
        return UUID(uuid: uuidBytes)
    }

    /// Generate a fallback UUID from a hash value — extracted for testability.
    static func fallbackUUIDFromHash(_ hashValue: Int) -> UUID {
        UUID(uuid: uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(abs(hashValue % 256))))
    }

    func uuidForScreen(_ screen: NSScreen) -> UUID {
        // P-INST-226: 屏幕 UUID 解析耗时（screen.deviceDescription NSScreenNumber 字典访问 + uuidFromDisplayID；overlay 每屏循环调用，deviceDescription 通常轻量缓存；slow-op ≥30ms warn）。
        let usStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: usStart)
            if durMs >= 30 { log("[Overlay] uuidForScreen slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        if let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return Self.uuidFromDisplayID(screenID.uint32Value)
        }
        return Self.fallbackUUIDFromHash(screen.hashValue)
    }
}
