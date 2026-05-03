import AppKit
import Foundation

// MARK: - Sound Preferences

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

@MainActor
final class SoundManager: ObservableObject {
    static let shared = SoundManager()

    private static let preferencesKey = "soundPreferences"

    @Published private(set) var preferences: SoundPreferences {
        didSet {
            savePreferences()
        }
    }

    private var currentSound: NSSound?

    private init() {
        self.preferences = Self.loadPreferences()
    }

    // MARK: - Public API

    func playCompletionSound() {
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
    }

    func previewSound(_ soundType: CompletionSoundType, customPath: String? = nil, volume: Float) {
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
    }

    func stopPlayback() {
        currentSound?.stop()
        currentSound = nil
    }

    func updateSoundType(_ type: CompletionSoundType) {
        preferences.soundType = type
    }

    func updateCustomSoundPath(_ path: String?) {
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
    }

    private func bundledSound(named name: String) -> NSSound? {
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
        do {
            let data = try JSONEncoder().encode(preferences)
            UserDefaults.standard.set(data, forKey: Self.preferencesKey)
            PreferencesSync.persistToDisk()
        } catch {
            log("[SoundManager] failed to save preferences", level: .error, fields: [
                "error": error.localizedDescription
            ])
        }
    }

    private static func loadPreferences() -> SoundPreferences {
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
