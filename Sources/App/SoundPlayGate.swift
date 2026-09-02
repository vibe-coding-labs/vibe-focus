// SoundPlayGate.swift
// VibeFocus — 提示音播放门控（纯类型 + 纯决策函数，产品迭代轮次 1：防打扰）
//
// 职责：判定一次「对话完成提示音」是否应当发声。三个产品判定维度：
//   1. 节流（throttle）：多个会话在 minIntervalSeconds 内先后完成时，抑制连环 ding；
//   2. 免打扰时段（quiet hours）：配置的时间窗内静音（支持跨午夜窗口，如 22→8）；
//   3. 其余情况放行。
// 试听（preview）是用户显式行为，不经过本门控（见 SoundManager）。

import Foundation

/// 门控判定结果
enum SoundPlayGateDecision: Equatable {
    /// 放行
    case allow
    /// 节流抑制（remainingSeconds = 距离可再次播放的秒数，仅日志/UI 展示用）
    case throttled(remainingSeconds: Int)
    /// 免打扰时段静音
    case quietHours
}

/// 提示音播放门控（纯函数命名空间，fixture 可测，见 Standalone/SoundPlayGateTests.swift）。
enum SoundPlayGate {

    /// 判定是否放行提示音。
    ///
    /// ## 场景
    /// - `SoundManager.playCompletionSound` 的前置判据（hook 移窗成功路径）；
    /// - 判定顺序：免打扰时段优先（硬静音压过节流），再查节流间隔。
    ///
    /// ## 边界裁决
    /// - `minIntervalSeconds <= 0` → 节流关闭（永不 throttle）；
    /// - `quietStartHour == quietEndHour` → 配置无效，视作不启用免打扰（避免误配成全天静音）；
    /// - `quietStartHour > quietEndHour` → 跨午夜窗口（如 22→8：hour≥22 或 hour<8 静音）；
    /// - `quietStartHour < quietEndHour` → 同日窗口（如 9→18：9 ≤ hour < 18 静音）；
    /// - `lastPlayedAt == nil` → 首次播放，直接放行。
    ///
    /// - Parameters:
    ///   - now: 当前时间
    ///   - lastPlayedAt: 上一次实际发声时间（nil 表示本轮会话尚未播过）
    ///   - minIntervalSeconds: 两次发声的最小间隔秒数（≤0 关闭节流）
    ///   - quietEnabled: 免打扰时段总开关
    ///   - quietStartHour / quietEndHour: 免打扰起止小时（0...23）
    ///   - calendar: 时区来源（默认当前设备；测试可注入固定时区）
    static func decide(
        now: Date,
        lastPlayedAt: Date?,
        minIntervalSeconds: Int,
        quietEnabled: Bool,
        quietStartHour: Int,
        quietEndHour: Int,
        calendar: Calendar = .current
    ) -> SoundPlayGateDecision {
        if quietEnabled, quietStartHour != quietEndHour,
           Self.isInQuietHours(
               date: now,
               startHour: quietStartHour,
               endHour: quietEndHour,
               calendar: calendar
           ) {
            return .quietHours
        }

        guard minIntervalSeconds > 0, let lastPlayedAt else {
            return .allow
        }
        let elapsed = now.timeIntervalSince(lastPlayedAt)
        if elapsed < Double(minIntervalSeconds) {
            let remaining = Int((Double(minIntervalSeconds) - elapsed).rounded(.up))
            return .throttled(remainingSeconds: max(remaining, 1))
        }
        return .allow
    }

    /// 时间点是否落在免打扰窗口内（起闭右开：含 startHour，不含 endHour）
    private static func isInQuietHours(
        date: Date,
        startHour: Int,
        endHour: Int,
        calendar: Calendar
    ) -> Bool {
        let hour = calendar.component(.hour, from: date)
        if startHour > endHour {
            return hour >= startHour || hour < endHour
        }
        return hour >= startHour && hour < endHour
    }
}
