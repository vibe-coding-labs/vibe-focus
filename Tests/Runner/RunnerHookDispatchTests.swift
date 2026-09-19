import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerHookDispatchTests.swift — B218：ClaudeHookServer.handleHookRequest
// 事件分发管线直驱（此前仅 SessionEnd 无绑定路径有覆盖；stop/userPromptSubmit/
// notification/permissionRequest 分发 case + spool 自注册接线 0 计数行）。
// 无绑定场景全走只读早退路径：不触碰窗口作业、不写生产 DB；语音播报 mode 默认
// .none 静默早退。async 桥接=信号量+主 RunLoop 短片泵（MainActor handler 铁律）。

extension RunnerHarness {
    /// 直驱 handleHookRequest：信号量等待 + 主 RunLoop 泵（服务端 handler 在主队列）
    private func driveHook(_ body: String, peer: String?) -> (statusCode: Int, code: String?, handled: Bool) {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var statusCode = -1
        nonisolated(unsafe) var code: String?
        nonisolated(unsafe) var handled = false
        Task {
            let r = await ClaudeHookServer.shared.handleHookRequest(
                body: Data(body.utf8), query: [:], headers: [:], peerAddress: peer)
            statusCode = r.statusCode
            code = r.response.code
            handled = r.response.handled
            sem.signal()
        }
        // 30s 死线：覆盖率插桩构建慢数倍且并行会话抢 CPU 时 10s 曾误报超时（B225 收官轮实测 flake）
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if sem.wait(timeout: .now() + 0.05) == .success { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return (statusCode, code, handled)
    }

    func runHookDispatchTests() {
        do {
            // 偏好存-还：通知开关关死（不投递 UN 中心）；spool 主机清单隔离
            let savedNotify = UserDefaults.standard.object(forKey: ClaudeHookPreferences.notifyOnNotificationKey)
            let savedHosts = UserDefaults.standard.string(forKey: RemoteSpoolHosts.hostsKey)
            defer {
                if let savedNotify { UserDefaults.standard.set(savedNotify, forKey: ClaudeHookPreferences.notifyOnNotificationKey) }
                else { UserDefaults.standard.removeObject(forKey: ClaudeHookPreferences.notifyOnNotificationKey) }
                if let savedHosts { UserDefaults.standard.set(savedHosts, forKey: RemoteSpoolHosts.hostsKey) }
                else { UserDefaults.standard.removeObject(forKey: RemoteSpoolHosts.hostsKey) }
            }
            UserDefaults.standard.set(false, forKey: ClaudeHookPreferences.notifyOnNotificationKey)
            UserDefaults.standard.removeObject(forKey: RemoteSpoolHosts.hostsKey)

            let unmatchedBefore = ClaudeHookServer.shared.unmatchedSessionCount
            let handledBefore = ClaudeHookServer.shared.handledRequestCount

            // ===== .stop 分发 case：无绑定 → no_binding_skip 入 unmatched =====
            let rStop = driveHook("{\"event\":\"Stop\",\"session_id\":\"b218-stop\"}", peer: nil)
            check("hookDispatch: Stop 无绑定 → no_binding_skip",
                  rStop.statusCode == 200 && rStop.code == "no_binding_skip" && rStop.handled == false)

            // ===== .userPromptSubmit 分发 case：无绑定 → no_binding_skip（UPS 决策树入口） =====
            let rUPS = driveHook("{\"event\":\"UserPromptSubmit\",\"session_id\":\"b218-ups\"}", peer: nil)
            check("hookDispatch: UPS 无绑定 → no_binding_skip",
                  rUPS.statusCode == 200 && rUPS.code == "no_binding_skip" && rUPS.handled == false)

            // ===== .notification / .permissionRequest 分发 case：开关关 → notification_disabled =====
            // B239：cfprefs 跨进程竞态（并行套件共享 defaults 域）会在设置与驱动之间
            // 翻转值——驱动前经偏好 setter 重钉一次。
            ClaudeHookPreferences.notifyOnNotification = false
            let rNotify = driveHook("{\"event\":\"Notification\",\"session_id\":\"b218-ntf\",\"message\":\"waiting\"}", peer: nil)
            check("hookDispatch: Notification 开关关 → notification_disabled 不计数 handled",
                  rNotify.statusCode == 200 && rNotify.code == "notification_disabled" && rNotify.handled == false)
            let rPerm = driveHook("{\"event\":\"PermissionRequest\",\"session_id\":\"b218-perm\"}", peer: nil)
            check("hookDispatch: PermissionRequest 同管线同门控（B206）",
                  rPerm.statusCode == 200 && rPerm.code == "notification_disabled")

            // ===== 计数器：stop/UPS 两请求入 unmatched；notification_disabled 非
            // no_binding_skip 不入；handled 恒不增 =====
            check("hookDispatch: unmatched +2（仅 no_binding_skip 类）、handled 恒 0",
                  ClaudeHookServer.shared.unmatchedSessionCount == unmatchedBefore + 2
                  && ClaudeHookServer.shared.handledRequestCount == handledBefore)

            // ===== B171 spool 自注册接线：TCP 对端==上报服务器 IP 才注册 =====
            let regBody = "{\"event\":\"Stop\",\"session_id\":\"b218-reg\"," +
                "\"terminal_ctx\":{\"machine_label\":\"ml-b218\",\"ssh_user\":\"cc\",\"ssh_server_ip\":\"203.0.113.9\"}}"
            _ = driveHook(regBody, peer: "203.0.113.9")
            check("hookDispatch: 对端==上报 IP → 自注册 cc@203.0.113.9",
                  RemoteSpoolHosts.loadHosts().contains("cc@203.0.113.9"))

            UserDefaults.standard.removeObject(forKey: RemoteSpoolHosts.hostsKey)
            _ = driveHook(regBody, peer: "9.9.9.9")
            check("hookDispatch: 对端错位 → 不注册（防伪造）",
                  RemoteSpoolHosts.loadHosts().isEmpty)
        }
    }
}
