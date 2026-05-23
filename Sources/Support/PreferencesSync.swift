import Foundation

/// 在 ~/.vibefocus/config.json 和 UserDefaults.standard 之间同步所有用户配置。
/// 启动时从磁盘恢复到 UserDefaults（磁盘优先），运行时 UserDefaults 变更自动持久化到磁盘。
/// 重装 app 后配置不会丢失，因为文件在用户主目录下，不受 app bundle 影响。
enum PreferencesSync {
    // MARK: - 文件路径

    static var configFilePath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".vibefocus/config.json")
    }

    // MARK: - 所有需要持久化的 UserDefaults Key 及默认值

    /// 注册表：每个 key 对应其默认值。缺失 key 在 restore 时用默认值填充。
    /// 注意：token 不持久化到磁盘（安全性考虑，每次安装重新生成）
    private static let preferenceRegistry: [String: Any] = [
        // ClaudeHookPreferences
        ClaudeHookPreferences.enabledKey: false,
        ClaudeHookPreferences.portKey: ClaudeHookPreferences.defaultPort,
        ClaudeHookPreferences.autoFocusOnSessionEndKey: true,
        ClaudeHookPreferences.triggerOnStopKey: true,
        ClaudeHookPreferences.triggerOnSessionEndKey: false,
        ClaudeHookPreferences.autoRestoreOnPromptSubmitKey: true,

        // SpacePreferences
        SpacePreferences.integrationEnabledKey: true,
        SpacePreferences.restoreStrategyKey: SpaceRestoreStrategy.switchToOriginal.rawValue,

        // HotKeyConfiguration
        HotKeyConfiguration.userDefaultsKey: HotKeyConfiguration.default,

        // ScreenIndexPreferences — 整体 Codable 对象存为 String
        ScreenIndexPreferences.userDefaultsKey: "",

        // SessionWindowRegistry and WindowManager savedWindowStates
        // migrated to SQLite — no longer in UserDefaults
    ]

    private static let syncQueue = DispatchQueue(label: "com.vibefocus.prefsync", qos: .utility)

    // MARK: - 启动时恢复（磁盘 → UserDefaults）

    /// 从 ~/.vibefocus/config.json 读取配置并写入 UserDefaults。
    /// 如果文件不存在或格式错误，不覆盖任何现有 UserDefaults 值。
    static func restoreFromDisk() {
        log("PreferencesSync.restoreFromDisk entry")
        let path = configFilePath
        guard FileManager.default.fileExists(atPath: path) else {
            log("PreferencesSync: no config file found, skipping restore", fields: ["path": path])
            return
        }

        guard let data = FileManager.default.contents(atPath: path),
              let dict = try? JSONDecoder().decode([String: PreferenceValue].self, from: data) else {
            log("PreferencesSync: failed to decode config file", level: .warn, fields: ["path": path])
            return
        }

        var restored = 0
        for (key, value) in dict {
            if key == ClaudeHookPreferences.tokenKey { continue }
            value.writeToUserDefaults(key: key)
            restored += 1
        }
        log("PreferencesSync: restored \(restored) keys from disk", fields: ["path": path])

        ensureDefaultsPopulated()
    }

    // MARK: - 运行时持久化（UserDefaults → 磁盘）

    /// 将当前所有偏好设置写入 ~/.vibefocus/config.json。
    /// 应在每次配置变更时调用。
    static func persistToDisk() {
        syncQueue.async {
            _persistToDiskSync()
        }
    }

    /// 同步版本，用于 applicationWillTerminate 等需要确保写入完成的场景
    static func persistToDiskAndWait() {
        syncQueue.sync {
            _persistToDiskSync()
        }
    }

    private static func _persistToDiskSync() {
        log("PreferencesSync._persistToDiskSync entry", level: .debug)
        var dict: [String: PreferenceValue] = [:]

        let allKeys = Set(preferenceRegistry.keys)
        for key in allKeys {
            if let value = PreferenceValue.readFromUserDefaults(key: key) {
                dict[key] = value
            }
        }

        guard let data = try? JSONEncoder().encode(dict) else {
            log("PreferencesSync: failed to encode preferences", level: .error)
            return
        }

        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".vibefocus")
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        let tmpPath = configFilePath + ".tmp"
        guard FileManager.default.createFile(atPath: tmpPath, contents: data) else {
            log("PreferencesSync: failed to write temp file", level: .error)
            return
        }
        do {
            _ = try FileManager.default.replaceItemAt(
                URL(fileURLWithPath: configFilePath),
                withItemAt: URL(fileURLWithPath: tmpPath)
            )
            log("PreferencesSync: persisted \(dict.count) keys to disk", level: .debug)
        } catch {
            log("PreferencesSync: replaceItemAt failed, trying fallback", level: .warn, fields: [
                "error": error.localizedDescription
            ])
            do {
                try FileManager.default.removeItem(atPath: configFilePath)
            } catch {
                log("PreferencesSync: removeItemAt failed in fallback", level: .warn, fields: [
                    "error": error.localizedDescription
                ])
            }
            try? FileManager.default.moveItem(atPath: tmpPath, toPath: configFilePath)
            log("PreferencesSync: persisted via fallback move", level: .debug)
        }
    }

    // MARK: - 确保默认值

    private static func ensureDefaultsPopulated() {
        for (key, defaultValue) in preferenceRegistry {
            if UserDefaults.standard.object(forKey: key) == nil {
                if let data = defaultValue as? Data {
                    UserDefaults.standard.set(data, forKey: key)
                } else if let str = defaultValue as? String {
                    UserDefaults.standard.set(str, forKey: key)
                } else if let num = defaultValue as? Int {
                    UserDefaults.standard.set(num, forKey: key)
                } else if let bool = defaultValue as? Bool {
                    UserDefaults.standard.set(bool, forKey: key)
                } else if let codable = defaultValue as? Codable {
                    if let encoded = try? JSONEncoder().encode(codable) {
                        UserDefaults.standard.set(encoded, forKey: key)
                    }
                }
            }
        }
    }
}

// MARK: - PreferenceValue — 类型安全的 UserDefaults 值包装

enum PreferenceValue: Codable {
    case bool(Bool)
    case int(Int)
    case string(String)
    case data(Data)

    // MARK: - 自定义 Codable（生成简洁 JSON 而非嵌套 {"_0": ...}）

    private enum CodingKeys: String, CodingKey { case type, value }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bool(let v):
            try container.encode("bool", forKey: .type)
            try container.encode(v, forKey: .value)
        case .int(let v):
            try container.encode("int", forKey: .type)
            try container.encode(v, forKey: .value)
        case .string(let v):
            try container.encode("string", forKey: .type)
            try container.encode(v, forKey: .value)
        case .data(let v):
            try container.encode("data", forKey: .type)
            try container.encode(v.base64EncodedString(), forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "bool":
            self = .bool(try container.decode(Bool.self, forKey: .value))
        case "int":
            self = .int(try container.decode(Int.self, forKey: .value))
        case "string":
            self = .string(try container.decode(String.self, forKey: .value))
        case "data":
            let base64 = try container.decode(String.self, forKey: .value)
            guard let d = Data(base64Encoded: base64) else {
                throw DecodingError.dataCorruptedError(forKey: .value, in: container, debugDescription: "Invalid base64 data")
            }
            self = .data(d)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown type: \(type)")
        }
    }

    func writeToUserDefaults(key: String) {
        switch self {
        case .bool(let v): UserDefaults.standard.set(v, forKey: key)
        case .int(let v): UserDefaults.standard.set(v, forKey: key)
        case .string(let v): UserDefaults.standard.set(v, forKey: key)
        case .data(let v): UserDefaults.standard.set(v, forKey: key)
        }
    }

    static func readFromUserDefaults(key: String) -> PreferenceValue? {
        if UserDefaults.standard.object(forKey: key) is Bool {
            return .bool(UserDefaults.standard.bool(forKey: key))
        }
        if UserDefaults.standard.object(forKey: key) is Int {
            return .int(UserDefaults.standard.integer(forKey: key))
        }
        if let str = UserDefaults.standard.string(forKey: key) {
            return .string(str)
        }
        if let data = UserDefaults.standard.data(forKey: key) {
            return .data(data)
        }
        return nil
    }
}
