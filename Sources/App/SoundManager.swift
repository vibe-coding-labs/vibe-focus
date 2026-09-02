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

/// Persistent sound effect preferences stored via UserDefaults.
struct SoundPreferences: Codable {
    var soundType: CompletionSoundType
    var customSoundPath: String?
    var volume: Float

    static let `default` = SoundPreferences(
        soundType: .none,
        customSoundPath: nil,
        volume: 0.7
    )
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

    private init() {
        self.preferences = Self.loadPreferences()
    }

    // MARK: - Public API

    func playCompletionSound() {
        // P-INST-99: 完成音效播放耗时（resolveSound 加载 NSSound 音频文件 + sound.play；hook window-move 路径 HookEventHandler+WindowMove+Execute:217 调用，属热路径；play 本身异步但音频文件加载/解码在调用线程可阻塞）。
        #if PERF_INSTRUMENT
        let pcsStart = Date()
        defer {
            log("[SoundManager] playCompletionSound finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: pcsStart))
            ])
        }
        #endif
        guard preferences.soundType != .none else {
            log("[SoundManager] sound type is none, skipping")
            return
        }

        let sound = resolveSound()
        guard let sound else {
            log("[SoundManager] failed to resolve sound", level: .warn, fields: [
                "soundType": preferences.soundType.rawValue
            ])
            return
        }

        startPlayback(
            sound,
            volume: preferences.volume,
            logMessage: "[SoundManager] playing completion sound",
            logFields: [
                "soundType": preferences.soundType.rawValue,
                "volume": String(preferences.volume)
            ]
        )
    }

    /// 失败提示音（固定系统 Basso；restore 结局 NSSound 区分成败，2026-09-02 P1-1）。
    ///
    /// ## 场景
    /// - restore 失败（可重试/永久）时与完成音效区分，用户不看日志也能感知结局；
    /// - 与成功共用用户音效开关（soundType == .none 时静默——尊重用户显式选「无」）。
    func playFailureSound() {
        guard preferences.soundType != .none else {
            log("[SoundManager] sound type is none, skipping failure sound")
            return
        }
        guard let sound = NSSound(named: "Basso") else {
            log("[SoundManager] failed to resolve system Basso", level: .warn)
            return
        }
        startPlayback(
            sound,
            volume: preferences.volume,
            logMessage: "[SoundManager] playing failure sound",
            logFields: [
                "sound": "Basso",
                "volume": String(preferences.volume)
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
