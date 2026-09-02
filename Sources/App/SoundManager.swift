import AppKit
import Foundation

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
struct SoundPreferences: Codable {
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
        self.volume = try container.decode(Float.self, forKey: .volume)
        self.minPlayIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .minPlayIntervalSeconds) ?? 2
        self.quietHoursEnabled = try container.decodeIfPresent(Bool.self, forKey: .quietHoursEnabled) ?? false
        self.quietStartHour = try container.decodeIfPresent(Int.self, forKey: .quietStartHour) ?? 22
        self.quietEndHour = try container.decodeIfPresent(Int.self, forKey: .quietEndHour) ?? 8
        self.projectRules = try container.decodeIfPresent([ProjectSoundRule].self, forKey: .projectRules) ?? []
    }
}

// MARK: - Sound Manager

/// Manages completion sound effects for window focus operations.
@MainActor
final class SoundManager: ObservableObject {
    static let shared = SoundManager()

    private static let preferencesKey = "soundPreferences"

    @Published private(set) var preferences: SoundPreferences {
        didSet {
            // P-INST-253: 声音偏好变更触发持久化入口（savePreferences P-INST-208 UserDefaults+JSONEncoder 写；偏好 UI 变更/apply 路径触发 didSet，归因持久化触发频率；slow-op ≥5ms warn）。
            #if PERF_INSTRUMENT
            let dslStart = Date()
            defer {
                let durMs = elapsedMilliseconds(since: dslStart)
                if durMs >= 5 { log("[SoundManager] preferences didSet→save slow", level: .warn, fields: ["durationMs": String(durMs)]) }
            }
            #endif
            savePreferences()
        }
    }

    private var currentSound: NSSound?
    /// 当前播放的自动停止任务（5s 兜底）。新播放/手动停止时取消，
    /// 防止旧定时器把新启的音频掐断（多会话并发完成时的真实竞态，见 startPlayback 场景注释）。
    private var playbackStopWorkItem: DispatchWorkItem?
    /// 上一次完成音实际发声时间（节流判据，轮次 1）。仅由 playCompletionSound 写；
    /// 试听（preview）是用户显式行为，不经过门控、不写此时间。
    private var lastCompletionPlayedAt: Date?

    private init() {
        self.preferences = Self.loadPreferences()
    }

    // MARK: - Public API

    /// 完成音入口（hook 移窗成功路径）。
    ///
    /// ## 场景
    /// - 调用方 HookEventHandler+WindowMove+Execute 携带 payload 提取的项目名（轮次 2）；
    /// - 流程：项目规则解析音效类型 → 防打扰门控 → 播放；
    ///   全局 .none 但项目命中规则时该项目仍发声（规则优先于全局开关）。
    ///
    /// - Parameter projectName: 完成会话的项目名（ProjectSoundResolver.projectName 提取；nil 走全局）
    func playCompletionSound(projectName: String? = nil) {
        // P-INST-99: 完成音效播放耗时（resolveSound 加载 NSSound 音频文件 + sound.play；hook window-move 路径 HookEventHandler+WindowMove+Execute:217 调用，属热路径；play 本身异步但音频文件加载/解码在调用线程可阻塞）。
        #if PERF_INSTRUMENT
        let pcsStart = Date()
        defer {
            log("[SoundManager] playCompletionSound finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: pcsStart))
            ])
        }
        #endif

        // 轮次 2：项目规则优先解析音效类型（在 .none 守卫之前——规则可覆盖全局关闭）
        let resolvedType = ProjectSoundResolver.resolvedType(
            projectName: projectName,
            rules: preferences.projectRules,
            globalType: preferences.soundType
        )
        guard resolvedType != .none else {
            log("[SoundManager] sound type is none, skipping")
            return
        }

        // 防打扰门控（轮次 1）：免打扰时段硬静音优先，其次节流间隔。
        // 试听（previewSound）不经过本门控——用户显式行为不受限。
        let gate = SoundPlayGate.decide(
            now: Date(),
            lastPlayedAt: lastCompletionPlayedAt,
            minIntervalSeconds: preferences.minPlayIntervalSeconds,
            quietEnabled: preferences.quietHoursEnabled,
            quietStartHour: preferences.quietStartHour,
            quietEndHour: preferences.quietEndHour
        )
        switch gate {
        case .allow:
            lastCompletionPlayedAt = Date()
        case .throttled(let remaining):
            log("[SoundManager] completion sound throttled", level: .info, fields: [
                "remainingSeconds": String(remaining),
                "minInterval": String(preferences.minPlayIntervalSeconds),
                "project": projectName ?? "nil"
            ])
            return
        case .quietHours:
            log("[SoundManager] completion sound muted by quiet hours", level: .info, fields: [
                "quietStartHour": String(preferences.quietStartHour),
                "quietEndHour": String(preferences.quietEndHour),
                "project": projectName ?? "nil"
            ])
            return
        }

        let sound = resolveSound(soundType: resolvedType, customPath: preferences.customSoundPath)
        guard let sound else {
            log("[SoundManager] failed to resolve sound", level: .warn, fields: [
                "soundType": resolvedType.rawValue
            ])
            return
        }

        startPlayback(
            sound,
            volume: preferences.volume,
            logMessage: "[SoundManager] playing completion sound",
            logFields: [
                "soundType": resolvedType.rawValue,
                "volume": String(preferences.volume),
                "project": projectName ?? "nil"
            ]
        )
    }

    func previewSound(_ soundType: CompletionSoundType, customPath: String? = nil, volume: Float) {
        // P-INST-160: 音效预览播放耗时（resolveSound 加载 NSSound P-INST-99 子路径 + sound.play 音频设备开声；设置 UI 试听按钮调用，文件加载/解码在调用线程可阻塞）。
        #if PERF_INSTRUMENT
        let psStart = Date()
        defer {
            log("[SoundManager] previewSound finished", level: .debug, fields: [
                "soundType": soundType.rawValue,
                "durationMs": String(elapsedMilliseconds(since: psStart))
            ])
        }
        #endif
        let sound = resolveSound(soundType: soundType, customPath: customPath)
        guard let sound else {
            log("[SoundManager] preview failed to resolve sound", level: .warn, fields: [
                "soundType": soundType.rawValue
            ])
            return
        }
        startPlayback(
            sound,
            volume: volume,
            logMessage: "[SoundManager] preview sound",
            logFields: [
                "soundType": soundType.rawValue,
                "volume": String(volume)
            ]
        )
    }

    func stopPlayback() {
        // P-INST-161: 音效停止耗时（currentSound.stop 停止音频设备 + 清引用；设置 UI 停止按钮 + startPlayback 互斥前停调用）。
        let spStart = Date()
        defer {
            log("[SoundManager] stopPlayback finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: spStart))
            ])
        }
        playbackStopWorkItem?.cancel()
        playbackStopWorkItem = nil
        currentSound?.stop()
        currentSound = nil
    }

    // MARK: - Playback Orchestration

    /// 播放互斥编排：停掉上一个（并取消其停止定时）→ 设音量 → 播放 → 5s 兜底停止。
    ///
    /// ## 场景
    /// - playCompletionSound / previewSound 的共同执行尾巴（两处曾各写一份"播+5s 后停"，
    ///   且都不停上一个——历史 bug：多会话并发完成时旧音频继续播、旧定时器把新音频提前掐断）。
    ///
    /// ## 并发约束
    /// - 必须主线程（@MainActor 类约束；hook 路径经 Task { @MainActor } 进入）；
    /// - 互斥：入口先 stopPlayback()，同一时刻至多一个 NSSound 在播；
    /// - 定时器身份校验：兜底闭包捕获具体 sound 实例，仅当仍是 currentSound 时才 stop，
    ///   杜绝"上一个播放的定时器掐断下一个播放"的互踩。
    private func startPlayback(
        _ sound: NSSound,
        volume: Float,
        logMessage: String,
        logFields: [String: String]
    ) {
        stopPlayback()

        sound.volume = volume
        sound.play()
        currentSound = sound

        log(logMessage, fields: logFields)

        let stopWork = DispatchWorkItem { [weak self] in
            guard let self, self.currentSound === sound else { return }
            sound.stop()
            self.currentSound = nil
        }
        playbackStopWorkItem = stopWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: stopWork)
    }

    func updateSoundType(_ type: CompletionSoundType) {
        preferences.soundType = type
    }

    func updateCustomSoundPath(_ path: String?) {
        // P-INST-162: 自定义音频路径更新耗时（preferences.customSoundPath didSet 持久化写；设置 UI 选择/清除文件按钮调用，触发偏好持久化）。
        #if PERF_INSTRUMENT
        let ucspStart = Date()
        defer {
            log("[SoundManager] updateCustomSoundPath finished", level: .debug, fields: [
                "hasPath": String(path != nil),
                "durationMs": String(elapsedMilliseconds(since: ucspStart))
            ])
        }
        #endif
        preferences.customSoundPath = path
    }

    func updateVolume(_ volume: Float) {
        preferences.volume = volume
    }

    /// 更新播放节流间隔（秒，0 = 关闭；负值防御性归零）
    func updateMinPlayInterval(_ seconds: Int) {
        preferences.minPlayIntervalSeconds = max(0, seconds)
    }

    /// 更新免打扰时段（小时钳制到 0...23；起==止在门控中视作无效不启用）
    func updateQuietHours(enabled: Bool, startHour: Int, endHour: Int) {
        preferences.quietHoursEnabled = enabled
        preferences.quietStartHour = max(0, min(23, startHour))
        preferences.quietEndHour = max(0, min(23, endHour))
    }

    // MARK: - Project Sound Rules（轮次 2）

    /// 新增一条空项目规则（默认 Complete 音效，UI 中填项目名）
    func addProjectRule() {
        preferences.projectRules.append(ProjectSoundRule(projectName: "", soundType: .builtinComplete))
    }

    func setProjectRuleName(at index: Int, _ name: String) {
        guard preferences.projectRules.indices.contains(index) else { return }
        preferences.projectRules[index].projectName = name
    }

    func setProjectRuleSound(at index: Int, _ type: CompletionSoundType) {
        guard preferences.projectRules.indices.contains(index) else { return }
        preferences.projectRules[index].soundRawValue = type.rawValue
    }

    func removeProjectRule(at index: Int) {
        guard preferences.projectRules.indices.contains(index) else { return }
        preferences.projectRules.remove(at: index)
    }

    // MARK: - Sound Resolution

    private func resolveSound(
        soundType: CompletionSoundType? = nil,
        customPath: String? = nil
    ) -> NSSound? {
        // P-INST-163: 音效资源解析耗时（NSSound(named:) 系统音 / bundledSound P-INST-164 Bundle 查找 / NSSound(contentsOfFile:) 自定义文件加载解码；playCompletionSound P-INST-99 + previewSound P-INST-160 子阶段，音频解码在调用线程可阻塞）。
        let rsStart = Date()
        let result: NSSound? = {
            let type = soundType ?? preferences.soundType
        let path = customPath ?? preferences.customSoundPath

        switch type {
        case .none:
            return nil
        case .systemDefault:
            return NSSound(named: "Hero")
        case .builtinDing:
            return bundledSound(named: "ding")
        case .builtinPing:
            return bundledSound(named: "ping")
        case .builtinComplete:
            return bundledSound(named: "complete")
        case .builtinAreYouOk:
            return bundledSound(named: "are-you-ok")
        case .custom:
            guard let path, !path.isEmpty else {
                log("[SoundManager] custom sound path is empty", level: .warn)
                return nil
            }
            // 轮次 3：配置过的文件被删 → 降级系统默认并告警（历史行为是静默无声）
            guard FileManager.default.fileExists(atPath: path) else {
                log("[SoundManager] custom sound file missing, falling back to system default", level: .warn, fields: [
                    "path": path
                ])
                return NSSound(named: "Hero")
            }
            return NSSound(contentsOfFile: path, byReference: false)
        }
        }()
        log("[SoundManager] resolveSound finished", level: .debug, fields: [
            "durationMs": String(elapsedMilliseconds(since: rsStart))
        ])
        return result
    }

    private func bundledSound(named name: String) -> NSSound? {
        // P-INST-164: 内置音频资源查找耗时（Bundle.main.url forResource 多扩展名 m4a/wav/mp3 × 2 路径查 + NSSound(contentsOf:byReference:) 加载解码；resolveSound P-INST-163 builtin 分支调用）。
        #if PERF_INSTRUMENT
        let bsStart = Date()
        defer {
            log("[SoundManager] bundledSound finished", level: .debug, fields: [
                "name": name,
                "durationMs": String(elapsedMilliseconds(since: bsStart))
            ])
        }
        #endif
        let extensions = ["m4a", "wav", "mp3"]
        for ext in extensions {
            if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Sounds") {
                return NSSound(contentsOf: url, byReference: false)
            }
        }
        for ext in extensions {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                return NSSound(contentsOf: url, byReference: false)
            }
        }
        log("[SoundManager] bundled sound not found: \(name)", level: .warn)
        return nil
    }

    // MARK: - Persistence

    private func savePreferences() {
        // P-INST-186: 音效偏好持久化耗时（JSONEncoder.encode + UserDefaults.standard.set CFPreferences 同步写；SoundPreferences didSet 触发，设置 UI 改动写）。
        let spStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: spStart)
            if durMs >= 5 { log("[SoundManager] savePreferences slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        do {
            let data = try JSONEncoder().encode(preferences)
            UserDefaults.standard.set(data, forKey: Self.preferencesKey)
        } catch {
            log("[SoundManager] failed to save preferences", level: .error, fields: [
                "error": error.localizedDescription
            ])
        }
    }

    private static func loadPreferences() -> SoundPreferences {
        // P-INST-208: 声音偏好加载耗时（UserDefaults.standard.data CFPreferences 读 + JSONDecoder.decode；声音偏好变更 + 启动加载调用；slow-op ≥5ms warn）。
        #if PERF_INSTRUMENT
        let lprStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: lprStart)
            if durMs >= 5 { log("[SoundManager] loadPreferences slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        #endif
        guard let data = UserDefaults.standard.data(forKey: preferencesKey) else {
            return .default
        }
        do {
            return try JSONDecoder().decode(SoundPreferences.self, from: data)
        } catch {
            log("[SoundManager] failed to decode preferences, using defaults", level: .warn, fields: [
                "error": error.localizedDescription
            ])
            return .default
        }
    }
}
