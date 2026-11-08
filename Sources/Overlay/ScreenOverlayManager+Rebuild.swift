import AppKit
import Foundation

// MARK: - ScreenOverlayManager · 唤醒/解锁重建与可见性自审计（B316 拆分，行为不变）
// 2026-09-20 角标幽灵窗根治域：锁屏/熄屏期创建的角标窗挂幽灵空间（onscreen 但不可见），
// 事件驱动（唤醒/解锁 debounce 重建）+ 事件无关兜底（刷新周期可见性自审计）双层自愈。
// 逐字搬移自 ScreenOverlayManager.swift；handleScreenWakeOrUnlockNotification/performWakeRebuild
// 的 private 放宽为 internal（#selector 注册与调用点留在主文件，跨文件可见性所需，
// B151/B157 拆分惯例）；存储属性（pendingWakeRebuildWorkItem/lastVisibilityRebuildAt）留类体。
extension ScreenOverlayManager {

    /// 唤醒/解锁重建判定（纯函数，真值表锁定于 RunnerOverlayWakeRebuildTests）。
    ///
    /// ## 场景
    /// - 锁屏/熄屏期间创建的 canJoinAllSpaces 角标窗挂在幽灵空间（onscreen 但不可见），
    ///   唤醒/解锁后需 hideOverlays+showOverlays 全量重建重新挂接可见空间；
    /// - enabled=false / 崩溃循环熔断：不重建（与 showOverlays 内部守卫同语义，避免空转日志）；
    /// - 输入气泡存续期抑制（B180）：不得借重建把浮层拉回来；
    /// - 不受 automaticRefreshSuspended 门控：设置窗获焦挂起的只是刷新 Timer，
    ///   唤醒重建是可见性修复，语义与 applyPreferenceRefresh 同级。
    static func wakeRebuildDecision(
        enabled: Bool,
        crashLoopSuppressed: Bool,
        inputBubbleSuppressed: Bool
    ) -> Bool {
        enabled && !crashLoopSuppressed && !inputBubbleSuppressed
    }

    @objc func handleScreenWakeOrUnlockNotification(_ notification: Notification) {
        let reason = notification.name.rawValue
        guard Self.wakeRebuildDecision(
            enabled: preferences.isEnabled,
            crashLoopSuppressed: crashLoopSuppressed,
            inputBubbleSuppressed: overlaysSuppressedForInputBubble
        ) else {
            log("[Overlay] wake rebuild skipped (disabled/crash-loop/bubble-suppressed)", level: .debug, fields: ["event": reason])
            return
        }
        pendingWakeRebuildWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performWakeRebuild(reason: reason)
        }
        pendingWakeRebuildWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ScreenOverlayManager.wakeRebuildDebounceInterval, execute: work)
        // 唤醒类事件追加延迟补射：用户「唤醒→输入密码→解锁」需要数秒到数分钟，
        // +1s 的首射大概率落在锁屏期（幽灵上下文），补射落点在解锁后的桌面，
        // 兜底 screenIsUnlocked 分布式通知万一未达时仍能完成可见挂接。
        let isWakeEvent = reason == NSWorkspace.screensDidWakeNotification.rawValue
            || reason == NSWorkspace.didWakeNotification.rawValue
        if isWakeEvent {
            for interval in ScreenOverlayManager.wakeRebuildFollowUpIntervals {
                let delay = ScreenOverlayManager.wakeRebuildDebounceInterval + interval
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.performWakeRebuild(reason: "\(reason)+followup\(Int(interval))s")
                }
            }
        }
    }

    /// 全量重建角标窗（close+create）。唤醒/解锁家族事件共用的执行体；
    /// 幽灵窗的就地 update/show 无法重新挂接可见空间，必须销毁重建
    /// （事件离散且已 debounce，2026-08-10 SIGSEGV 的 close+create 竞态场景
    /// 是屏幕重排通知风暴，此处无该风险）。
    func performWakeRebuild(reason: String) {
        guard Self.wakeRebuildDecision(
            enabled: preferences.isEnabled,
            crashLoopSuppressed: crashLoopSuppressed,
            inputBubbleSuppressed: overlaysSuppressedForInputBubble
        ) else {
            return
        }
        let startedAt = Date()
        let previousCount = overlayWindows.count
        hideOverlays()
        showOverlays()
        logOperationDuration(
            "[Overlay] wake rebuild finished",
            startedAt: startedAt,
            warnThresholdMs: 200,
            fields: [
                "event": reason,
                "beforeCount": String(previousCount),
                "afterCount": String(overlayWindows.count)
            ]
        )
    }

    // MARK: - 可见性自审计（2026-09-20 幽灵窗根治第三层兜底）

    /// 可见性自审计判定（纯函数，真值表锁定于 RunnerOverlayWakeRebuildTests）。
    ///
    /// ## 场景
    /// screenIsUnlocked 分布式通知实测不可达（装机 0.0.86 上解锁后 0 次送达）、
    /// 唤醒补射有时间盲区（唤醒→解锁间隔超长时全部落在锁屏期）——任何事件丢失
    /// 都会让幽灵窗存活。本判定不依赖任何事件：解锁态（前台 ≠ loginwindow）下
    /// 用 NSWindow.occlusionState 自查，全部角标窗均不可见即全量重建。
    /// - enabled=false / 崩溃熔断 / 气泡抑制：不审计（与既有守卫同语义）；
    /// - 无角标窗：不审计（无东西可救，避免空转）；
    /// - 任一角标窗可见：不审计（正常态，全遮蔽才是失败签名）；
    /// - 冷却未到：不重建（防遮蔽场景下的重建抖动，遮蔽非挂接失败）。
    static func visibilityAuditDecision(
        frontmostBundleID: String?,
        enabled: Bool,
        crashLoopSuppressed: Bool,
        inputBubbleSuppressed: Bool,
        overlayWindowCount: Int,
        visibleOverlayCount: Int,
        secondsSinceLastRebuild: TimeInterval,
        cooldown: TimeInterval
    ) -> Bool {
        guard enabled, !crashLoopSuppressed, !inputBubbleSuppressed else { return false }
        guard let front = frontmostBundleID, front != "com.apple.loginwindow" else { return false }
        guard overlayWindowCount > 0, visibleOverlayCount == 0 else { return false }
        return secondsSinceLastRebuild >= cooldown
    }

    /// 刷新周期调用的可见性自审计入口（轻量：N 个 occlusionState 位读取）。
    func auditOverlayVisibility() {
        let visibleCount = overlayWindows.values.filter {
            $0.occlusionState.contains(.visible)
        }.count
        guard Self.visibilityAuditDecision(
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            enabled: preferences.isEnabled,
            crashLoopSuppressed: crashLoopSuppressed,
            inputBubbleSuppressed: overlaysSuppressedForInputBubble,
            overlayWindowCount: overlayWindows.count,
            visibleOverlayCount: visibleCount,
            secondsSinceLastRebuild: Date().timeIntervalSince(lastVisibilityRebuildAt),
            cooldown: Self.visibilityAuditCooldown
        ) else {
            return
        }
        lastVisibilityRebuildAt = Date()
        log("[Overlay] visibility audit: all overlays occluded in unlocked session, rebuilding", fields: [
            "windows": String(overlayWindows.count)
        ])
        performWakeRebuild(reason: "visibility_audit")
    }
}
