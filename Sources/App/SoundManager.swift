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
            let dslStart = Date()
            defer {
                let durMs = elapsedMilliseconds(since: dslStart)
                if durMs >= 5 { log("[SoundManager] preferences didSet→save slow", level: .warn, fields: ["durationMs": String(durMs)]) }
            }
            savePreferences()
        }
    }

    private var currentSound: NSSound?

    private init() {
        self.preferences = Self.loadPreferences()
    }

    // MARK: - Public API

    func playCompletionSound() {
        // P-INST-99: 完成音效播放耗时（resolveSound 加载 NSSound 音频文件 + sound.play；hook window-move 路径 HookEventHandler+WindowMove+Execute:217 调用，属热路径；play 本身异步但音频文件加载/解码在调用线程可阻塞）。
        let pcsStart = Date()
        defer {
            log("[SoundManager] playCompletionSound finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: pcsStart))
            ])
        }
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

        sound.volume = preferences.volume
        sound.play()
        currentSound = sound

        log("[SoundManager] playing completion sound", fields: [
            "soundType": preferences.soundType.rawValue,
            "volume": String(preferences.volume)
        ])

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.currentSound?.stop()
            self?.currentSound = nil
        }
    }

    func previewSound(_ soundType: CompletionSoundType, customPath: String? = nil, volume: Float) {
        // P-INST-160: 音效预览播放耗时（resolveSound 加载 NSSound P-INST-99 子路径 + sound.play 音频设备开声；设置 UI 试听按钮调用，文件加载/解码在调用线程可阻塞）。
        let psStart = Date()
        defer {
            log("[SoundManager] previewSound finished", level: .debug, fields: [
                "soundType": soundType.rawValue,
                "durationMs": String(elapsedMilliseconds(since: psStart))
            ])
        }
        let sound = resolveSound(soundType: soundType, customPath: customPath)
        guard let sound else {
            log("[SoundManager] preview failed to resolve sound", level: .warn, fields: [
                "soundType": soundType.rawValue
            ])
            return
        }
        sound.volume = volume
        sound.play()
        currentSound = sound

        log("[SoundManager] preview sound", fields: [
            "soundType": soundType.rawValue,
            "volume": String(volume)
        ])

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.currentSound?.stop()
            self?.currentSound = nil
        }
    }

    func stopPlayback() {
        // P-INST-161: 音效停止耗时（currentSound.stop 停止音频设备 + 清引用；设置 UI 停止按钮调用）。
        let spStart = Date()
        defer {
            log("[SoundManager] stopPlayback finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: spStart))
            ])
        }
        currentSound?.stop()
        currentSound = nil
    }

    func updateSoundType(_ type: CompletionSoundType) {
        preferences.soundType = type
    }

    func updateCustomSoundPath(_ path: String?) {
        // P-INST-162: 自定义音频路径更新耗时（preferences.customSoundPath didSet 持久化写；设置 UI 选择/清除文件按钮调用，触发偏好持久化）。
        let ucspStart = Date()
        defer {
            log("[SoundManager] updateCustomSoundPath finished", level: .debug, fields: [
                "hasPath": String(path != nil),
                "durationMs": String(elapsedMilliseconds(since: ucspStart))
            ])
        }
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
        let bsStart = Date()
        defer {
            log("[SoundManager] bundledSound finished", level: .debug, fields: [
                "name": name,
                "durationMs": String(elapsedMilliseconds(since: bsStart))
            ])
        }
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
        let lprStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: lprStart)
            if durMs >= 5 { log("[SoundManager] loadPreferences slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
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
