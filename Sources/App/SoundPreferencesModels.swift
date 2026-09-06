import Foundation

// MARK: - 完成音效偏好模型（2026-09-07 从 SoundManager.swift 拆分，行为不变）
// 纯模型 + 自定义解码：与播放编排（SoundManager）分离。

// MARK: - Sound Preferences

/// Available completion sound effects for toggle/restore operations.
enum CompletionSoundType: String, CaseIterable, Codable {
    case none = "none"
    case systemDefault = "system_default"
    case builtinDing = "builtin_ding"
    case builtinPing = "builtin_ping"
    case builtinComplete = "builtin_complete"
    case builtinAreYouOk = "builtin_are_you_ok"
    case custom = "custom"

    var displayName: String {
        switch self {
        case .none: return "无"
        case .systemDefault: return "系统默认"
        case .builtinDing: return "Ding"
        case .builtinPing: return "Ping"
        case .builtinComplete: return "Complete"
        case .builtinAreYouOk: return "Are You OK"
        case .custom: return "自定义文件"
        }
    }

    var isBuiltin: Bool {
        switch self {
        case .builtinDing, .builtinPing, .builtinComplete, .builtinAreYouOk:
            return true
        default:
            return false
        }
    }
}

/// 自定义音频文件有效性（轮次 3：反馈可信度）。
/// 区分「未配置」与「配置过但文件被删」——后者播放时降级系统默认并告警，
/// 不再静默无声（用户删了文件后完成音悄悄消失是历史盲区）。
enum CustomSoundStatus: Equatable {
    /// 未配置路径
    case notSet
    /// 文件存在
    case valid
    /// 已配置但文件不存在
    case missing

    static func evaluate(path: String?) -> CustomSoundStatus {
        guard let path, !path.isEmpty else { return .notSet }
        return FileManager.default.fileExists(atPath: path) ? .valid : .missing
    }

    /// 设置页 detail 文案
    var uiDescription: String {
        switch self {
        case .notSet: return "未选择文件"
        case .valid: return "已选择"
        case .missing: return "⚠️ 文件不存在，完成音将降级为系统默认"
        }
    }
}

/// Persistent sound effect preferences stored via UserDefaults.
///
/// ## 向后兼容（轮次 1）
/// 新增字段必须走 `init(from:)` 的 `decodeIfPresent` + 默认值——合成 Codable 会在
/// 旧 JSON 缺字段时整体解码失败，loadPreferences 随即回退 `.default`，
/// 把用户已保存的 soundType/customSoundPath 静默重置（持久化铁律的反面案例）。
struct SoundPreferences: Codable, Equatable {
    var soundType: CompletionSoundType
    var customSoundPath: String?
    var volume: Float
    /// 两次完成音最小间隔秒数（0 = 关闭节流）。防多会话连环 ding（轮次 1）。
    var minPlayIntervalSeconds: Int
    /// 免打扰时段总开关与起止小时（0...23；起==止视作无效不启用）
    var quietHoursEnabled: Bool
    var quietStartHour: Int
    var quietEndHour: Int
    /// 项目音效规则表（从上到下首个命中者生效，轮次 2）
    var projectRules: [ProjectSoundRule]

    static let `default` = SoundPreferences(
        soundType: .none,
        customSoundPath: nil,
        volume: 0.7,
        minPlayIntervalSeconds: 2,
        quietHoursEnabled: false,
        quietStartHour: 22,
        quietEndHour: 8,
        projectRules: []
    )

    init(
        soundType: CompletionSoundType,
        customSoundPath: String?,
        volume: Float,
        minPlayIntervalSeconds: Int = 2,
        quietHoursEnabled: Bool = false,
        quietStartHour: Int = 22,
        quietEndHour: Int = 8,
        projectRules: [ProjectSoundRule] = []
    ) {
        self.soundType = soundType
        self.customSoundPath = customSoundPath
        self.volume = volume
        self.minPlayIntervalSeconds = minPlayIntervalSeconds
        self.quietHoursEnabled = quietHoursEnabled
        self.quietStartHour = quietStartHour
        self.quietEndHour = quietEndHour
        self.projectRules = projectRules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.soundType = try container.decode(CompletionSoundType.self, forKey: .soundType)
        self.customSoundPath = try container.decodeIfPresent(String.self, forKey: .customSoundPath)
        // volume 必须容错解码（2026-09-07 单测实锤的潜伏 bug）：volume 字段加入之前
        // 保存的旧 JSON 无此键，decode 必填会让整体解码失败 → loadPreferences 回退
        // .default，用户全部偏好被静默重置（持久化铁律违例）。0.7 = memberwise 默认。
        self.volume = try container.decodeIfPresent(Float.self, forKey: .volume) ?? 0.7
        self.minPlayIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .minPlayIntervalSeconds) ?? 2
        self.quietHoursEnabled = try container.decodeIfPresent(Bool.self, forKey: .quietHoursEnabled) ?? false
        self.quietStartHour = try container.decodeIfPresent(Int.self, forKey: .quietStartHour) ?? 22
        self.quietEndHour = try container.decodeIfPresent(Int.self, forKey: .quietEndHour) ?? 8
        self.projectRules = try container.decodeIfPresent([ProjectSoundRule].self, forKey: .projectRules) ?? []
    }
}

