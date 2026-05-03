# 会话完成提示音系统 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 在 Claude Code 对话完成（Stop/SessionEnd）时播放提示音，支持内置音效和用户自定义本地音频文件，在设置窗口提供完整的提示音配置界面。

**Architecture:** Claude Hook 事件 → `ClaudeHookServer.handleWindowMoveTrigger` 窗口移动成功 → 调用 `SoundManager.playCompletionSound()` → 根据 `SoundPreferences` 配置播放对应音频。SoundManager 使用 macOS 原生 `NSSound` API 播放音频，支持内置音效（bundled in app bundle）和自定义本地文件（通过 `NSSound(contentsOfFile:)` 加载）。设置界面新增「提示音」SettingsCard，包含音效选择器、音量滑块、试听按钮和自定义文件选择器。

**Tech Stack:** Swift 5.9, SwiftUI, AppKit NSSound, macOS 13+, AVFoundation (可选)

**Risks:**
- Task 1 修改 ClaudeHookServer，需要在窗口移动成功路径上精确触发提示音，不能在失败或跳过时触发 → 缓解：只在 `moved == true` 的分支调用
- 内置音频文件需要用户自行准备（版权问题），Plan 中提供文件结构和脚本占位 → 缓解：提供 generate-placeholder-sounds 脚本生成测试用的静音/蜂鸣音频
- 自定义文件通过 NSOpenPanel 选择，需要正确处理 App Sandbox 和文件访问权限 → 缓解：使用 security-scoped bookmarks 或直接通过路径播放（菜单栏应用无 Sandbox 限制）
- Task 4 修改 SettingsUI.swift 文件较大（2490 行），需要精确插入位置 → 缓解：使用 SettingsCard 模式，插入到「Claude Code 集成」卡片之后

---

### Task 1: SoundManager 音频播放引擎

**Depends on:** None
**Files:**
- Create: `Sources/SoundManager.swift`

- [ ] **Step 1: 创建 SoundManager — 管理提示音播放和内置音效列表**

```swift
// Sources/SoundManager.swift
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

    /// 播放会话完成提示音（在窗口移动成功后调用）
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

    /// 试听提示音（设置界面使用）
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

    /// 停止当前播放
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
        // 从 app bundle 的 Resources/Sounds/ 目录加载音频
        if let url = Bundle.main.url(forResource: name, withExtension: "m4a", subdirectory: "Sounds") {
            return NSSound(contentsOf: url, byReference: false)
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Sounds") {
            return NSSound(contentsOf: url, byReference: false)
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "mp3", subdirectory: "Sounds") {
            return NSSound(contentsOf: url, byReference: false)
        }
        // fallback: 不带 subdirectory
        if let url = Bundle.main.url(forResource: name, withExtension: "m4a") {
            return NSSound(contentsOf: url, byReference: false)
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "wav") {
            return NSSound(contentsOf: url, byReference: false)
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "mp3") {
            return NSSound(contentsOf: url, byReference: false)
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
```

- [ ] **Step 2: 验证 SoundManager 编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"
  - Output does NOT contain: "error:"

- [ ] **Step 3: 提交**
Run: `git add Sources/SoundManager.swift && git commit -m "feat(sound): add SoundManager with built-in and custom sound support"`

---

### Task 2: 内置音频资源文件和打包配置

**Depends on:** Task 1
**Files:**
- Create: `Resources/Sounds/ding.wav`
- Create: `Resources/Sounds/ping.wav`
- Create: `Resources/Sounds/complete.wav`
- Create: `Resources/Sounds/are-you-ok.wav`
- Modify: `Package.swift:23-26`（添加 Sounds 资源目录）
- Modify: `scripts/dev-build.sh:44-45`（确保音频文件被复制到 app bundle）

- [ ] **Step 1: 创建内置音频文件目录并生成占位音频**

生成 4 个测试用的蜂鸣音频文件。使用 macOS 自带的 `afconvert` 或 `say` 命令生成：

Run: `mkdir -p /Users/cc11001100/github/vibe-coding-labs/vibe-focus/Resources/Sounds`

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && python3 -c "
import subprocess, struct, os

sounds_dir = 'Resources/Sounds'
os.makedirs(sounds_dir, exist_ok=True)

def generate_tone_wav(filename, freq, duration, sample_rate=44100):
    n_samples = int(sample_rate * duration)
    samples = []
    for i in range(n_samples):
        t = i / sample_rate
        # Apply fade in/out
        fade = min(i, n_samples - i, int(sample_rate * 0.05)) / (sample_rate * 0.05)
        val = int(32767 * 0.5 * fade * __import__('math').sin(2 * __import__('math').pi * freq * t))
        samples.append(struct.pack('<h', max(-32768, min(32767, val))))
    data = b''.join(samples)
    header = struct.pack('<4sI4s', b'RIFF', 36 + len(data), b'WAVE')
    fmt = struct.pack('<4sIHHIIHH', b'fmt ', 16, 1, 1, sample_rate, sample_rate * 2, 2, 16)
    with open(os.path.join(sounds_dir, filename), 'wb') as f:
        f.write(header + fmt + b'data' + struct.pack('<I', len(data)) + data)

# ding: short high tone
generate_tone_wav('ding.wav', 880, 0.3)
# ping: medium tone
generate_tone_wav('ping.wav', 660, 0.4)
# complete: ascending two-tone
generate_tone_wav('complete.wav', 1046, 0.5)
print('Generated ding.wav, ping.wav, complete.wav')
"`

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && say -v Ting-Ting 'Are you OK' -o Resources/Sounds/are-you-ok.aiff && afconvert Resources/Sounds/are-you-ok.aiff Resources/Sounds/are-you-ok.wav -f WAVE -d LEI16@22050 2>/dev/null; rm -f Resources/Sounds/are-you-ok.aiff; echo "Generated are-you-ok.wav"`

Run: `ls -la /Users/cc11001100/github/vibe-coding-labs/vibe-focus/Resources/Sounds/`
Expected:
  - Exit code: 0
  - Output contains: "ding.wav", "ping.wav", "complete.wav", "are-you-ok.wav"

- [ ] **Step 2: 修改 Package.swift 添加音频资源目录**
文件: `Package.swift:23-26`（resources 数组，在现有 `.copy` 之后）

```swift
// 替换 Package.swift:23-26 的 resources 数组
resources: [
    .copy("../Resources/yabai-space-changed.sh"),
    .copy("../Resources/claude-session-hook-example.sh"),
    .copy("../Resources/Sounds")
]
```

- [ ] **Step 3: 修改 dev-build.sh 确保音频文件复制到 app bundle**
文件: `scripts/dev-build.sh:44-45`（资源复制区块）

```bash
# 替换 scripts/dev-build.sh:44-45 的资源复制部分
# Copy resources
cp -R "Resources/" "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true

# Ensure Sounds directory exists in app bundle
if [ -d "Resources/Sounds" ]; then
    mkdir -p "$APP_BUNDLE/Contents/Resources/Sounds"
    cp -R "Resources/Sounds/" "$APP_BUNDLE/Contents/Resources/Sounds/" 2>/dev/null || true
    echo "   ✓ 音频资源已复制"
fi
```

- [ ] **Step 4: 同步修改 package_release.sh 确保发布包也包含音频**
文件: `scripts/package_release.sh`（在复制 icon 资源之后添加）

找到以下内容（在复制 StatusBarIcon.png 之后）：
```bash
if [ -f "$ROOT_DIR/assets/StatusBarIcon.png" ]; then
  cp "$ROOT_DIR/assets/StatusBarIcon.png" "$RESOURCES_DIR/StatusBarIcon.png"
fi
```

在其之后添加：
```bash
# Copy sound resources
if [ -d "$ROOT_DIR/Resources/Sounds" ]; then
  mkdir -p "$RESOURCES_DIR/Sounds"
  cp -R "$ROOT_DIR/Resources/Sounds/" "$RESOURCES_DIR/Sounds/"
  echo "   ✓ Sound resources copied"
fi
```

- [ ] **Step 5: 验证构建包含音频资源**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

Run: `ls -la /Users/cc11001100/github/vibe-coding-labs/vibe-focus/.build/release/VibeFocusHotkeys_VibeFocusHotkeys.bundle/Resources/Sounds/ 2>/dev/null || echo "Checking alternative path..." && find /Users/cc11001100/github/vibe-coding-labs/vibe-focus/.build/release/ -name "ding.wav" 2>/dev/null`
Expected:
  - Output contains: "ding.wav"

- [ ] **Step 6: 提交**
Run: `git add Resources/Sounds/ Package.swift scripts/dev-build.sh scripts/package_release.sh && git commit -m "feat(sound): add built-in sound resources and bundle configuration"`

---

### Task 3: Hook 服务器集成提示音播放

**Depends on:** Task 1, Task 2
**Files:**
- Modify: `Sources/ClaudeHookServer.swift:927-950`（在窗口移动成功后播放提示音）

- [ ] **Step 1: 在 moveBindingToMainScreen 成功路径中调用 SoundManager**
文件: `Sources/ClaudeHookServer.swift:932-950`（`if moved {` 区块内部）

将以下代码：
```swift
        if moved {
            SessionWindowRegistry.shared.markCompleted(sessionID: payload.sessionID)
            handledRequestCount += 1
            log(
                "[ClaudeHookServer] \(triggerName) window moved successfully",
                fields: [
                    "sessionID": payload.sessionID,
                    "app": binding.windowIdentity.appName ?? "unknown",
                    "title": binding.windowIdentity.title ?? "untitled"
                ]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "window_focused",
                    message: "Window moved to main screen and maximized",
                    sessionID: payload.sessionID, handled: true
                )
            )
        }
```

替换为：
```swift
        if moved {
            SessionWindowRegistry.shared.markCompleted(sessionID: payload.sessionID)
            handledRequestCount += 1
            log(
                "[ClaudeHookServer] \(triggerName) window moved successfully",
                fields: [
                    "sessionID": payload.sessionID,
                    "app": binding.windowIdentity.appName ?? "unknown",
                    "title": binding.windowIdentity.title ?? "untitled"
                ]
            )
            Task { @MainActor in
                SoundManager.shared.playCompletionSound()
            }
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "window_focused",
                    message: "Window moved to main screen and maximized",
                    sessionID: payload.sessionID, handled: true
                )
            )
        }
```

- [ ] **Step 2: 同样在 fallbackToCWDMatching 的成功路径中触发提示音**
文件: `Sources/ClaudeHookServer.swift`（`fallbackToCWDMatching` 方法中调用 `moveBindingToMainScreen` 的位置）

搜索 `fallbackToCWDMatching` 方法中第二个 `moveBindingToMainScreen` 调用（约 line 823），由于该方法直接调用 `moveBindingToMainScreen`，提示音已在 `moveBindingToMainScreen` 内部触发，无需额外修改。

确认：`fallbackToCWDMatching` 最终也调用 `moveBindingToMainScreen`（line 823），提示音已在 Step 1 中统一处理，无需重复。

- [ ] **Step 3: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/ClaudeHookServer.swift && git commit -m "feat(sound): play completion sound on successful window move from Claude hooks"`

---

### Task 4: 设置界面提示音配置面板

**Depends on:** Task 1, Task 2
**Files:**
- Modify: `Sources/SettingsUI.swift:385-407`（SettingsView 属性声明区域）
- Modify: `Sources/SettingsUI.swift:1266-1546`（在「屏幕序号显示」SettingsCard 之后添加提示音设置卡片）

- [ ] **Step 1: 在 SettingsView 中添加 SoundManager 和提示音相关状态**

文件: `Sources/SettingsUI.swift:397-406`（在 `@State private var hookInstallMessage` 之前插入）

在以下行之前：
```swift
    @State private var hookInstallMessage: String?
```

插入：
```swift
    // 提示音设置
    @StateObject private var soundManager = SoundManager.shared
    @State private var isPreviewPlaying = false
    @State private var showFileImporter = false
```

- [ ] **Step 2: 创建提示音设置卡片视图**

文件: `Sources/SettingsUI.swift`（在「屏幕序号显示」SettingsCard 的结束括号之后，约 line 1546，`}` 之前插入）

找到 `SettingsCard(title: "屏幕序号显示"` 的结束位置。在该 SettingsCard 的最后一个 `}` 之后、右侧 ScrollView 的 `}` 之前插入新的 SettingsCard。

```swift
                    SettingsCard(
                        title: "提示音",
                        subtitle: "对话完成时播放提示音，支持内置音效或自定义音频文件。"
                    ) {
                        // === 提示音开关 ===
                        SettingsRow(
                            title: "启用提示音",
                            detail: "Claude 对话完成（窗口移动成功）后播放提示音"
                        ) {
                            Picker("", selection: Binding(
                                get: { soundManager.preferences.soundType },
                                set: { soundManager.updateSoundType($0) }
                            )) {
                                ForEach(CompletionSoundType.allCases, id: \.self) { type in
                                    Text(type.displayName).tag(type)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 160)
                        }

                        if soundManager.preferences.soundType != .none {
                            Divider()

                            // === 音量控制 ===
                            SettingsRow(
                                title: "音量",
                                detail: "调整提示音的音量大小"
                            ) {
                                HStack(spacing: 8) {
                                    Image(systemName: "speaker.fill")
                                        .foregroundStyle(.secondary)
                                        .font(.system(size: 11))

                                    DraggableSlider(
                                        value: Binding(
                                            get: { Double(soundManager.preferences.volume) },
                                            set: { soundManager.updateVolume(Float($0)) }
                                        ),
                                        minValue: 0.0,
                                        maxValue: 1.0,
                                        step: 0.1
                                    )
                                    .frame(width: 120)

                                    Text("\(Int(soundManager.preferences.volume * 100))%")
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 40)

                                    Image(systemName: "speaker.wave.3.fill")
                                        .foregroundStyle(.secondary)
                                        .font(.system(size: 11))
                                }
                            }

                            Divider()

                            // === 试听按钮 ===
                            HStack(spacing: 12) {
                                Button(isPreviewPlaying ? "停止" : "试听") {
                                    if isPreviewPlaying {
                                        soundManager.stopPlayback()
                                        isPreviewPlaying = false
                                    } else {
                                        soundManager.previewSound(
                                            soundManager.preferences.soundType,
                                            customPath: soundManager.preferences.customSoundPath,
                                            volume: soundManager.preferences.volume
                                        )
                                        isPreviewPlaying = true
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                                            isPreviewPlaying = false
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)

                                Spacer()
                            }

                            Text("点击试听当前选择的提示音效果")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }

                        // === 自定义文件选择 ===
                        if soundManager.preferences.soundType == .custom {
                            Divider()

                            SettingsRow(
                                title: "自定义音频文件",
                                detail: soundManager.preferences.customSoundPath ?? "未选择文件"
                            ) {
                                HStack(spacing: 10) {
                                    Button("选择文件") {
                                        showFileImporter = true
                                    }
                                    .buttonStyle(.bordered)

                                    if soundManager.preferences.customSoundPath != nil {
                                        Button("清除") {
                                            soundManager.updateCustomSoundPath(nil)
                                        }
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(.red)
                                        .font(.system(size: 11))
                                    }
                                }
                            }

                            Text("支持 WAV、MP3、M4A、AIFF 格式。选择后可点击「试听」验证效果。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Divider()

                        // === 内置音效说明 ===
                        VStack(alignment: .leading, spacing: 8) {
                            Text("内置音效说明：")
                                .font(.system(size: 13, weight: .medium))

                            HStack(spacing: 6) {
                                Image(systemName: "music.note")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 11))
                                Text("Ding — 短促清脆的提示音")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 6) {
                                Image(systemName: "music.note")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 11))
                                Text("Ping — 柔和的中频提示音")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 6) {
                                Image(systemName: "music.note")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 11))
                                Text("Complete — 完成感较强的上升音")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 6) {
                                Image(systemName: "person.wave.2")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 11))
                                Text("Are You OK — 雷军经典语音提示")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
```

- [ ] **Step 3: 添加 NSOpenPanel 文件选择器到 SettingsView**

在 SettingsView 的 body 闭包之后（`onChange(of: hookToken)` 之后），添加 `fileImporter` modifier 和 `openAudioFilePanel` 方法。

找到 SettingsView body 的最后一个 modifier（约 line 1621 `.onChange(of: hookToken)` 的结束括号），在其之后添加：

```swift
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.audio, .wav, .mp3, .aiff],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    let path = url.path
                    log("[Settings] selected custom sound file", fields: ["path": path])
                    soundManager.updateCustomSoundPath(path)
                }
            case .failure(let error):
                log("[Settings] file importer failed", level: .error, fields: [
                    "error": error.localizedDescription
                ])
            }
        }
```

注意：如果 `UTType` 不可用（macOS 13+），需要确保 `import UniformTypeIdentifiers` 已添加。在 SettingsUI.swift 文件顶部的 import 区域添加：

```swift
import UniformTypeIdentifiers
```

- [ ] **Step 4: 在左侧边栏信息卡片中添加提示音状态**

文件: `Sources/SettingsUI.swift`（约 line 551，在 `SidebarInfoCard(title: "Claude Hook"` 之后添加）

找到：
```swift
                        SidebarInfoCard(title: "Claude Hook", value: hookServer.isRunning ? "运行中" : (hookEnabled ? "已关闭" : "未启用"))
```

在其之后添加：
```swift
                        SidebarInfoCard(title: "提示音", value: soundManager.preferences.soundType == .none ? "未启用" : soundManager.preferences.soundType.displayName)
```

- [ ] **Step 5: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"
  - Output does NOT contain: "error:"

- [ ] **Step 6: 提交**
Run: `git add Sources/SettingsUI.swift && git commit -m "feat(sound): add sound settings card with preview, volume control, and file picker"`

---

### Task 5: 构建验证和端到端测试

**Depends on:** Task 3, Task 4
**Files:**
- None (验证 only)

- [ ] **Step 1: 完整构建并部署**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && ./scripts/dev-build.sh 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output contains: "构建成功" or "✅"
  - Output contains: "签名验证通过"

- [ ] **Step 2: 验证音频资源在 app bundle 中**
Run: `ls -la /Applications/VibeFocus.app/Contents/Resources/Sounds/ 2>/dev/null || echo "Sounds directory not found in app bundle"`
Expected:
  - Exit code: 0
  - Output contains: "ding.wav", "ping.wav", "complete.wav", "are-you-ok.wav"

- [ ] **Step 3: 验证 SettingsUI 中 SoundManager 正确初始化**
Run: `grep -c "SoundManager" /Users/cc11001100/github/vibe-coding-labs/vibe-focus/Sources/SettingsUI.swift && grep -c "CompletionSoundType" /Users/cc11001100/github/vibe-coding-labs/vibe-focus/Sources/SettingsUI.swift && grep -c "SoundManager" /Users/cc11001100/github/vibe-coding-labs/vibe-focus/Sources/ClaudeHookServer.swift`
Expected:
  - All counts > 0
  - SettingsUI.swift contains SoundManager references
  - ClaudeHookServer.swift contains SoundManager.playCompletionSound call

- [ ] **Step 4: 确认所有修改文件一致性检查**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && echo "=== Checking CompletionSoundType consistency ===" && grep -rn "CompletionSoundType" Sources/ | head -20 && echo "=== Checking SoundManager references ===" && grep -rn "SoundManager" Sources/ | head -20 && echo "=== Checking SoundPreferences ===" && grep -rn "SoundPreferences" Sources/ | head -10`
Expected:
  - CompletionSoundType used consistently across SoundManager.swift and SettingsUI.swift
  - SoundManager.shared.playCompletionSound() called in ClaudeHookServer.swift
  - No "SoundPreferences" direct usage outside SoundManager (preferences accessed through SoundManager)

- [ ] **Step 5: 提交（如有遗漏修复）**
Run: `git diff --stat && git status`
Expected:
  - No uncommitted changes (all committed in previous tasks)
