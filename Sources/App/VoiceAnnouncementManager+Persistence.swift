import Foundation

// MARK: - 语音播报持久化
// 偏好 JSON 编码/解码与 UserDefaults 读写。镜像 SoundManager 的持久化模式：
// init 只读不写（加载用 fallback 默认值，不回写），写入仅由 preferences didSet 驱动。

@MainActor
extension VoiceAnnouncementManager {

    /// 序列化当前偏好写入 UserDefaults（didSet 触发，编码失败记 error 日志不抛出）。
    func savePreferences() {
        // P-INST-270: 语音播报偏好持久化耗时（JSONEncoder.encode + UserDefaults.standard.set 写；VoiceAnnouncementPreferences didSet 触发，设置 UI 改动写）。
        #if PERF_INSTRUMENT
        let spStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: spStart)
            if durMs >= 5 { log("[VoiceAnnouncementManager] savePreferences slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        #endif
        do {
            let data = try JSONEncoder().encode(preferences)
            UserDefaults.standard.set(data, forKey: Self.preferencesKey)
        } catch {
            log("[VoiceAnnouncementManager] failed to save preferences", level: .error, fields: [
                "error": error.localizedDescription
            ])
        }
    }

    /// 启动加载偏好：无记录或解码失败（字段漂移/损坏）都用 `.default`，绝不回写——
    /// 防止用陈旧默认覆盖 SQLite/UserDefaults 真实配置（ScreenIndexPreferences 同类教训）。
    static func loadPreferences() -> VoiceAnnouncementPreferences {
        // P-INST-281: 语音播报偏好加载耗时（UserDefaults.standard.data 读 + JSONDecoder.decode；启动加载 + 偏好变更；slow-op ≥5ms warn）。
        #if PERF_INSTRUMENT
        let lpStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: lpStart)
            if durMs >= 5 { log("[VoiceAnnouncementManager] loadPreferences slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        #endif
        guard let data = UserDefaults.standard.data(forKey: preferencesKey) else {
            return .default
        }
        do {
            return try JSONDecoder().decode(VoiceAnnouncementPreferences.self, from: data)
        } catch {
            log("[VoiceAnnouncementManager] failed to decode preferences, using defaults", level: .warn, fields: [
                "error": error.localizedDescription
            ])
            return .default
        }
    }
}
