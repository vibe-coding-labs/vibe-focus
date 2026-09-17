// UserNotificationPoster.swift
// VibeFocus — NotificationPosting 生产实现（B196）
//
// UNUserNotificationCenter 封装。授权策略：provisional（临时授权）——首次投递
// 静默拿到权限、通知安静地进通知中心，不弹系统权限框打断用户；用户此后随时可
// 在系统设置升到横幅/声音。被用户显式拒绝过则缓存 denial 短路，不再逐事件空转 XPC。

import Foundation
import UserNotifications

@MainActor
final class UserNotificationPoster: NotificationPosting {
    static let shared = UserNotificationPoster()

    /// 用户显式拒绝后置位，后续投递直接短路（requestAuthorization 恒 false）。
    private var authorizationDenied = false

    private init() {}

    /// CLI/SwiftPM 可执行（Runner）无 bundle id，UNUserNotificationCenter 不可用——
    /// 调用前短路，保证 Runner 门禁进程内不触碰 UN 框架。
    static var isNotificationAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    func post(_ content: HookNotificationContent) async -> Bool {
        guard Self.isNotificationAvailable, !authorizationDenied else {
            log("[UserNotificationPoster] skip post (unavailable or denied)", level: .debug, fields: [
                "identifier": content.identifier
            ])
            return false
        }
        let center = UNUserNotificationCenter.current()
        do {
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .denied:
                authorizationDenied = true
                log("[UserNotificationPoster] authorization denied by user, short-circuiting", level: .warn)
                return false
            case .notDetermined:
                let granted = try? await center.requestAuthorization(options: [.alert, .sound, .provisional])
                if granted != true {
                    authorizationDenied = true
                    log("[UserNotificationPoster] provisional authorization not granted", level: .warn)
                    return false
                }
            default:
                break
            }
            let notification = UNMutableNotificationContent()
            notification.title = content.title
            notification.body = content.body
            notification.sound = nil
            let request = UNNotificationRequest(identifier: content.identifier, content: notification, trigger: nil)
            try await center.add(request)
            log("[UserNotificationPoster] posted", fields: [
                "identifier": content.identifier,
                "title": content.title
            ])
            return true
        } catch {
            log("[UserNotificationPoster] post failed: \(error.localizedDescription)", level: .warn)
            return false
        }
    }
}
