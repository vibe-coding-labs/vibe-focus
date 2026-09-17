// HookEventHandler+Notification.swift
// VibeFocus — Notification 事件处理（B196）
//
// Claude Code 的 Notification hook 在「需要权限确认」或「空闲等待输入」时触发。
// 此前这两个态完全无感知——多会话工作流下「哪个会话在等我」比「哪个做完了」
// 更高频更关键。处理策略：只投递 macOS 通知中心，绝不动窗口（B192 用户定调
// 「拉窗」类触发默认关；通知属信息投递，另一性质，默认开 + 设置页可关）。

import Foundation

/// 投递到通知中心的一条等待输入提醒。
struct HookNotificationContent: Equatable {
    /// 通知去重标识（同会话反复等待时替换旧通知而非堆叠）。
    let identifier: String
    let title: String
    let body: String
}

/// 通知投递抽象：生产走 UserNotificationPoster（UNUserNotificationCenter），
/// Runner 测试注入假投递器锁三态行为。@MainActor——投递只从主 actor 的
/// hook handler 发起，协议级隔离让 Sendable 检查静默。
@MainActor
protocol NotificationPosting {
    func post(_ content: HookNotificationContent) async -> Bool
}

@MainActor
extension HookEventHandler {

    // MARK: - 纯内容构造（Runner 直测）

    /// Notification 事件 → 通知内容。cwd 尾段做项目名进标题；message 原文透传
    /// （Claude Code 给的是人话，如 "Claude needs your permission to use Bash"），
    /// 空白回退默认文案；identifier 绑 sessionID 使同会话通知互相替换。
    static func makeNotificationContent(
        sessionID: String,
        message: String?,
        cwd: String?
    ) -> HookNotificationContent {
        let project: String? = cwd.flatMap { raw -> String? in
            let name = URL(fileURLWithPath: raw).lastPathComponent
            return name.isEmpty ? nil : name
        }
        let title = project.map { "Claude 等待输入 · \($0)" } ?? "Claude 等待输入"
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = trimmed.isEmpty ? "会话等待你的输入（权限确认或空闲等待）" : trimmed
        return HookNotificationContent(
            identifier: "vf-hook-\(sessionID)",
            title: title,
            body: body
        )
    }

    // MARK: - 事件处理

    /// Notification 事件处理：注册表记账 + 通知中心投递。无窗口作业，快路径，
    /// 不经 WindowWorkExecutor（与移窗类事件的耗时画像根本不同）。
    /// 不走 AuditLogger：审计表服务于窗口迁移健康（--diagnose 新鲜度按迁移事件
    /// 算），无窗事件落进去只会污染账本；证据走注册表 touch + hook.resp.<code> 计数。
    func handleNotification(
        payload: ClaudeHookPayload,
        poster: NotificationPosting = UserNotificationPoster.shared
    ) async -> (statusCode: Int, response: ClaudeHookResponse) {
        log(
            "[HookEventHandler] Notification triggered",
            fields: [
                "sessionID": payload.sessionID,
                "notifyOnNotification": String(ClaudeHookPreferences.notifyOnNotification),
                "hasMessage": String(payload.message != nil),
                "cwd": payload.cwd ?? "nil"
            ]
        )

        // 门：总开关（与 SessionEnd/UPS 关闭语义一致——事件收到、诚实记账、不处理）
        guard ClaudeHookPreferences.notifyOnNotification else {
            // setLastEventDescription 无条件记账（Notification 常来自绑定失败的会话，
            // touch 对未绑定会话是 no-op）；touch 仍对已绑定会话刷新 updatedAt。
            SessionWindowRegistry.shared.setLastEventDescription("Notification 收到（等待输入通知已关闭）")
            SessionWindowRegistry.shared.touch(sessionID: payload.sessionID)
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "notification_disabled",
                    message: "Waiting-for-input notification disabled",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        let content = Self.makeNotificationContent(
            sessionID: payload.sessionID,
            message: payload.message,
            cwd: payload.cwd
        )
        let posted = await poster.post(content)
        log(
            "[HookEventHandler] Notification posted",
            level: posted ? .info : .warn,
            fields: [
                "sessionID": payload.sessionID,
                "identifier": content.identifier,
                "posted": String(posted)
            ]
        )
        SessionWindowRegistry.shared.setLastEventDescription(
            posted
                ? "Notification：已投递等待输入通知"
                : "Notification：通知投递失败（未授权或不可用）"
        )
        SessionWindowRegistry.shared.touch(sessionID: payload.sessionID)
        return (
            200,
            ClaudeHookResponse(
                ok: true,
                code: posted ? "notification_sent" : "notification_post_failed",
                message: posted
                    ? "Waiting-for-input notification delivered"
                    : "Waiting-for-input notification could not be delivered (unauthorized or unavailable)",
                sessionID: payload.sessionID,
                handled: posted
            )
        )
    }
}
