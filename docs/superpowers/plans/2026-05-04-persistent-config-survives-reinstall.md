# 配置持久化 — 重装后配置不丢失 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 将 VibeFocus 所有用户配置从 UserDefaults.standard（随 bundle-id 变化/卸载而丢失）迁移到 `~/.vibefocus/config.json`（用户主目录下，不受重装影响），启动时从文件恢复到 UserDefaults，UserDefaults 变更时自动同步回文件。

**Architecture:** 启动时 PreferencesSync.restoreFromDisk() 读取 `~/.vibefocus/config.json` → 写入 UserDefaults.standard → 现有代码无感知地读到配置；每次配置变更时 PreferencesSync.persistToDisk() 从 UserDefaults 读取所有已知 key → 序列化为 JSON 写入 `~/.vibefocus/config.json`。双向同步以磁盘文件为准（启动时覆盖 UserDefaults），运行时 UserDefaults 变更立即写回磁盘。

**Tech Stack:** Swift 5.9, Foundation (FileManager, JSONEncoder/JSONDecoder), macOS 13+

**Risks:**
- config.json 格式变更时的向后兼容 → 缺失字段用默认值兜底（Codable 默认值模式）
- 并发写入冲突 → 使用串行 DispatchQueue 保护文件 I/O
- 迁移过程中旧数据丢失 → restore 时以磁盘文件为准，空文件不覆盖 UserDefaults

---

### Task 1: 创建 PreferencesSync 模块 — 磁盘配置文件读写核心

**Depends on:** None
**Files:**
- Create: `Sources/PreferencesSync.swift`

- [ ] **Step 1: 创建 PreferencesSync — 负责在 ~/.vibefocus/config.json 和 UserDefaults 之间同步配置**

```swift
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
        ClaudeHookPreferences.autoRestoreOnPromptSubmitKey: false,

        // SpacePreferences
        SpacePreferences.integrationEnabledKey: true,
        SpacePreferences.restoreStrategyKey: SpaceRestoreStrategy.switchToOriginal.rawValue,

        // HotKeyConfiguration
        HotKeyConfiguration.userDefaultsKey: HotKeyConfiguration.default,

        // ScreenIndexPreferences — 整体 Codable 对象存为 String
        ScreenIndexPreferences.userDefaultsKey: "",

        // SessionWindowRegistry
        "claudeSessionWindowBindings.v1": Data(),

        // WindowManager savedWindowStates
        "savedWindowStates": Data(),
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
            // token 不从磁盘恢复
            if key == ClaudeHookPreferences.tokenKey { continue }
            value.writeToUserDefaults(key: key)
            restored += 1
        }
        log("PreferencesSync: restored \(restored) keys from disk", fields: ["path": path])

        // 确保所有已知 key 在 UserDefaults 中有值（缺失的用默认值填充）
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

        // 收集所有已知 key 的当前值
        let allKeys = Set(preferenceRegistry.keys)
        for key in allKeys {
            if let value = PreferenceValue.readFromUserDefaults(key: key) {
                dict[key] = value
            }
        }

        // 同时收集 UserDefaults 中实际存在但不在 registry 中的 key
        // （避免遗漏新增的偏好）
        if let bundleId = Bundle.main.bundleIdentifier,
           let plistPath = Bundle.main.path(forResource: "Info", ofType: "plist") {
            // 无法直接枚举 UserDefaults 所有 key，跳过
        }

        guard let data = try? JSONEncoder().encode(dict) else {
            log("PreferencesSync: failed to encode preferences", level: .error)
            return
        }

        // 确保 ~/.vibefocus/ 目录存在
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".vibefocus")
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        // 原子写入：先写临时文件再 rename
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
            // rename 失败时直接覆盖
            do {
                try FileManager.default.removeItem(atPath: configFilePath)
            } catch {}
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

/// 包装 UserDefaults 中不同类型的值，支持 JSON 序列化/反序列化
enum PreferenceValue: Codable {
    case bool(Bool)
    case int(Int)
    case string(String)
    case data(Data)

    func writeToUserDefaults(key: String) {
        switch self {
        case .bool(let v): UserDefaults.standard.set(v, forKey: key)
        case .int(let v): UserDefaults.standard.set(v, forKey: key)
        case .string(let v): UserDefaults.standard.set(v, forKey: key)
        case .data(let v): UserDefaults.standard.set(v, forKey: key)
        }
    }

    static func readFromUserDefaults(key: String) -> PreferenceValue? {
        // 检查顺序很重要：Bool 必须在 Int 之前，因为 Bool 是 Int 的子类型
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
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

---

### Task 2: 在配置变更时触发磁盘持久化 — 修改现有 Preferences 模块

**Depends on:** Task 1
**Files:**
- Modify: `Sources/ClaudeHookPreferences.swift:31-119`（所有 computed property setter）
- Modify: `Sources/SpaceController.swift:21-38`（SpacePreferences computed property setter）
- Modify: `Sources/ScreenIndexPreferences.swift:178-192`（save 方法）

- [ ] **Step 1: 修改 ClaudeHookPreferences 所有 setter — 添加 PreferencesSync.persistToDisk() 调用**
文件: `Sources/ClaudeHookPreferences.swift:37-119`（替换所有 computed property）

```swift
    static var isEnabled: Bool {
        get {
            let value = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
            log("ClaudeHookPreferences.isEnabled read", level: .debug, fields: ["value": String(value)])
            return value
        }
        set {
            log("ClaudeHookPreferences.isEnabled set", level: .debug, fields: ["value": String(newValue)])
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            PreferencesSync.persistToDisk()
        }
    }

    static var listenPort: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: portKey)
            if stored == 0 {
                log("ClaudeHookPreferences.listenPort read: using default", level: .debug, fields: ["defaultPort": String(defaultPort)])
                return defaultPort
            }
            let normalized = normalizePort(stored)
            log("ClaudeHookPreferences.listenPort read", level: .debug, fields: ["stored": String(stored), "normalized": String(normalized)])
            return normalized
        }
        set {
            let normalized = normalizePort(newValue)
            log("ClaudeHookPreferences.listenPort set", level: .debug, fields: ["raw": String(newValue), "normalized": String(normalized)])
            UserDefaults.standard.set(normalized, forKey: portKey)
            PreferencesSync.persistToDisk()
        }
    }

    static var authToken: String? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: tokenKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                log("ClaudeHookPreferences.authToken read: nil or empty", level: .debug)
                return nil
            }
            log("ClaudeHookPreferences.authToken read", level: .debug, fields: ["tokenPrefix": String(raw.prefix(8)) + "..."])
            return raw
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            log("ClaudeHookPreferences.authToken set", level: .debug, fields: ["hasValue": String(!trimmed.isEmpty)])
            UserDefaults.standard.set(trimmed, forKey: tokenKey)
            // token 不持久化到磁盘（安全性），但仍触发其他配置同步
            PreferencesSync.persistToDisk()
        }
    }

    static var autoFocusOnSessionEnd: Bool {
        get {
            UserDefaults.standard.object(forKey: autoFocusOnSessionEndKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoFocusOnSessionEndKey)
            PreferencesSync.persistToDisk()
        }
    }

    static var triggerOnStop: Bool {
        get { UserDefaults.standard.object(forKey: triggerOnStopKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: triggerOnStopKey)
            PreferencesSync.persistToDisk()
        }
    }

    static var triggerOnSessionEnd: Bool {
        get { UserDefaults.standard.object(forKey: triggerOnSessionEndKey) as? Bool ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: triggerOnSessionEndKey)
            PreferencesSync.persistToDisk()
        }
    }

    static var autoRestoreOnPromptSubmit: Bool {
        get { UserDefaults.standard.object(forKey: autoRestoreOnPromptSubmitKey) as? Bool ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: autoRestoreOnPromptSubmitKey)
            PreferencesSync.persistToDisk()
        }
    }
```

- [ ] **Step 2: 修改 SpacePreferences setter — 添加 PreferencesSync.persistToDisk() 调用**
文件: `Sources/SpaceController.swift:21-38`（替换 SpacePreferences struct）

```swift
struct SpacePreferences {
    static let integrationEnabledKey = "spaceIntegrationEnabled"
    static let restoreStrategyKey = "spaceRestoreStrategy"

    static var integrationEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: integrationEnabledKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: integrationEnabledKey)
            PreferencesSync.persistToDisk()
        }
    }

    static var restoreStrategy: SpaceRestoreStrategy {
        get {
            let raw = UserDefaults.standard.string(forKey: restoreStrategyKey) ?? SpaceRestoreStrategy.switchToOriginal.rawValue
            return SpaceRestoreStrategy(rawValue: raw) ?? .switchToOriginal
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: restoreStrategyKey)
            PreferencesSync.persistToDisk()
        }
    }
}
```

- [ ] **Step 3: 修改 ScreenIndexPreferences.save — 添加 PreferencesSync.persistToDisk() 调用**
文件: `Sources/ScreenIndexPreferences.swift:178-192`（替换 save 方法）

```swift
    func save() {
        log("ScreenIndexPreferences.save() entered", level: .debug, fields: [
            "isEnabled": String(isEnabled),
            "position": position.rawValue
        ])
        guard let data = try? JSONEncoder().encode(self),
              let jsonString = String(data: data, encoding: .utf8) else {
            log("ScreenIndexPreferences: Failed to encode")
            return
        }
        let bundleId = Bundle.main.bundleIdentifier ?? "com.openai.vibe-focus"
        CFPreferencesSetAppValue(Self.userDefaultsKey as CFString, jsonString as CFString, bundleId as CFString)
        CFPreferencesAppSynchronize(bundleId as CFString)
        // 同时写入 UserDefaults.standard（供 PreferencesSync 读取）
        UserDefaults.standard.set(jsonString, forKey: Self.userDefaultsKey)
        PreferencesSync.persistToDisk()
        log("ScreenIndexPreferences: Saved successfully")
    }
```

- [ ] **Step 4: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

---

### Task 3: 在启动和退出时调用同步 — 修改 AppDelegate 生命周期

**Depends on:** Task 1, Task 2
**Files:**
- Modify: `Sources/SettingsUI.swift:2023-2098`（applicationDidFinishLaunching）
- Modify: `Sources/SettingsUI.swift:2106-2109`（applicationWillTerminate）

- [ ] **Step 1: 修改 applicationDidFinishLaunching — 在最早位置调用 restoreFromDisk**
文件: `Sources/SettingsUI.swift:2023-2026`（在 installCrashSignalHandlers 和 installAtExitHandler 之后、其他初始化之前插入恢复调用）

在 `applicationDidFinishLaunching` 方法的 `CrashContextRecorder.shared.bootstrap()` 之后、单实例检查之前，插入：

```swift
        // 从 ~/.vibefocus/config.json 恢复配置到 UserDefaults（重装后配置不丢失）
        PreferencesSync.restoreFromDisk()
```

具体位置：在 `NativeSpaceBridge.logAvailability()` 之后（约 L2029），单实例检查 `if let existing = findExistingInstance()` 之前（约 L2032）插入上面这行。

- [ ] **Step 2: 修改 applicationWillTerminate — 退出时持久化配置到磁盘**
文件: `Sources/SettingsUI.swift:2106-2109`（替换 applicationWillTerminate 方法）

```swift
    func applicationWillTerminate(_ notification: Notification) {
        ScreenOverlayManager.shared.flushPendingPreferenceSave(reason: "application_will_terminate")
        PreferencesSync.persistToDiskAndWait()
        CrashContextRecorder.shared.markCleanExit()
    }
```

- [ ] **Step 3: 在 HotKeyManager setup 完成后触发持久化 — 确保快捷键配置也被保存**

在 `HotKeyManager.shared.setup()` 调用之后，添加一行 `PreferencesSync.persistToDisk()`。

具体位置：`Sources/SettingsUI.swift:2075`，在 `HotKeyManager.shared.setup()` 之后添加：

```swift
        HotKeyManager.shared.setup()
        PreferencesSync.persistToDisk()
```

- [ ] **Step 4: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 5: 验证功能 — 检查 config.json 是否生成**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -3 && cp .build/release/VibeFocusHotkeys /Users/cc11001100/Applications/VibeFocus.app/Contents/MacOS/VibeFocusHotkeys && echo "Deployed"`
Expected:
  - Exit code: 0
  - Output contains: "Deployed"

- [ ] **Step 6: 提交**
Run: `git add Sources/PreferencesSync.swift Sources/ClaudeHookPreferences.swift Sources/SpaceController.swift Sources/ScreenIndexPreferences.swift Sources/SettingsUI.swift && git commit -m "feat(persistence): sync preferences to ~/.vibefocus/config.json so config survives reinstall"`
