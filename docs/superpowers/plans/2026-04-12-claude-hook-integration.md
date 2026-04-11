# Claude Code Hook 集成 — 对话完成自动聚焦窗口到主屏

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 当 Claude Code 对话完成时，自动将对应的终端/IDE 窗口移动到主屏幕并最大化。用户按 Ctrl+M 可恢复原位。

**Architecture:** VibeFocus 内置 HTTP 服务器（NWListener），监听 `127.0.0.1:39277`。Claude Code 通过 `type: "http"` Hook 配置直接 POST JSON 到该端点。`SessionStart` 事件绑定前台窗口到 `session_id`；`Stop` 事件（对话完成）触发窗口移动。Settings UI 提供一键安装 Hook 配置到 `~/.claude/settings.json`（安全 merge）、状态监控、测试按钮。

**Tech Stack:** Swift, SwiftUI, NWListener, AppKit Accessibility API, Claude Code HTTP Hooks, yabai (optional)

---

## 背景：Claude Code Hook 工作原理

### Hook 配置格式（写入 ~/.claude/settings.json）

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [{ "type": "http", "url": "http://127.0.0.1:39277/claude/hook", "timeout": 5 }]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [{ "type": "http", "url": "http://127.0.0.1:39277/claude/hook", "timeout": 5 }]
      }
    ]
  }
}
```

### 事件 Payload（Claude Code POST 到我们的端点）

**SessionStart：**
```json
{ "session_id": "abc-123", "hook_event_name": "SessionStart", "cwd": "/Users/x/project", "model": "claude-sonnet-4-6", "source": "startup" }
```

**Stop（每次对话完成）：**
```json
{ "session_id": "abc-123", "hook_event_name": "Stop", "stop_hook_active": true, "last_assistant_message": "..." }
```

**SessionEnd（进程退出）：**
```json
{ "session_id": "abc-123", "hook_event_name": "SessionEnd", "reason": "other" }
```

### 数据流

```
Claude Code ──POST──→ ClaudeHookServer ──SessionStart──→ SessionWindowRegistry(绑定窗口)
                      127.0.0.1:39277   ──Stop────────→ WindowManager.moveWindowToMainScreen()
                                                         ↓
                                                      窗口移动到主屏+最大化
```

---

## 改动范围

**已有代码（需扩展）：**
- `Sources/ClaudeHookModels.swift` — 添加 Stop 事件、hook_event_name 兼容
- `Sources/ClaudeHookServer.swift` — 处理 Stop 事件
- `Sources/ClaudeHookPreferences.swift` — 触发偏好 + Hook 安装方法
- `Sources/SessionWindowRegistry.swift` — UI 数据查询方法
- `Sources/SettingsUI.swift` — Hook 设置卡片 + 辅助方法 + AppDelegate 启动
- `Sources/Support.swift` — 通知名

**不需要改动：**
- `Sources/WindowManager.swift` — 已有 moveWindowToMainScreen()
- `Sources/SpaceController.swift` — 已有跨工作区支持
- `Sources/NativeSpaceBridge.swift` — 已有原生 API fallback

---

## Part A: 数据模型层（Task 1-6）

### Task 1: ClaudeHookEventType — 添加 Stop 事件枚举值

**Files:** Modify: `Sources/ClaudeHookModels.swift:3-6`

- [ ] **在 ClaudeHookEventType 枚举中添加 stop case**

当前：
```swift
enum ClaudeHookEventType: String, Codable, CaseIterable {
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
}
```

改为：
```swift
enum ClaudeHookEventType: String, Codable, CaseIterable {
    case sessionStart = "SessionStart"
    case stop = "Stop"
    case sessionEnd = "SessionEnd"
}
```

---

### Task 2: ClaudeHookPayload — 添加新 CodingKeys

**Files:** Modify: `Sources/ClaudeHookModels.swift:38-44`

- [ ] **在 CodingKeys 枚举中添加 hookEventName、cwd、model**

当前：
```swift
private enum CodingKeys: String, CodingKey {
    case event
    case sessionID = "session_id"
    case sessionId
    case source
    case timestamp
}
```

改为：
```swift
private enum CodingKeys: String, CodingKey {
    case event
    case hookEventName = "hook_event_name"
    case sessionID = "session_id"
    case sessionId
    case source
    case timestamp
    case cwd
    case model
}
```

---

### Task 3: ClaudeHookPayload — 添加 cwd 和 model 属性

**Files:** Modify: `Sources/ClaudeHookModels.swift:32-37`

- [ ] **在 struct 属性声明中添加 cwd 和 model**

当前：
```swift
struct ClaudeHookPayload: Decodable {
    let event: ClaudeHookEventType
    let sessionID: String
    let source: String?
    let timestamp: String?
```

改为：
```swift
struct ClaudeHookPayload: Decodable {
    let event: ClaudeHookEventType
    let sessionID: String
    let source: String?
    let timestamp: String?
    let cwd: String?
    let model: String?
```

---

### Task 4: ClaudeHookPayload — 兼容 hook_event_name 解码

**Files:** Modify: `Sources/ClaudeHookModels.swift:46-51`

- [ ] **修改 init(from:) 先尝试 event 字段，再 fallback 到 hook_event_name**

当前事件解码：
```swift
event = try container.decode(ClaudeHookEventType.self, forKey: .event)
```

改为：
```swift
if let e = try? container.decode(ClaudeHookEventType.self, forKey: .event) {
    event = e
} else if let e = try? container.decode(ClaudeHookEventType.self, forKey: .hookEventName) {
    event = e
} else {
    throw DecodingError.dataCorruptedError(
        forKey: .event, in: container,
        debugDescription: "Neither 'event' nor 'hook_event_name' found"
    )
}
```

---

### Task 5: ClaudeHookPayload — 解码新字段 cwd 和 model

**Files:** Modify: `Sources/ClaudeHookModels.swift:62-63`

- [ ] **在 init(from:) 末尾（timestamp 解码之后）添加 cwd 和 model 解码**

在 `timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)` 之后添加：
```swift
cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
model = try container.decodeIfPresent(String.self, forKey: .model)
```

---

### Task 6: 编译验证 — 数据模型层

- [ ] **编译**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected: `Build complete!`

---

## Part B: 偏好配置层（Task 7-18）

### Task 7: ClaudeHookPreferences — 添加触发事件键常量

**Files:** Modify: `Sources/ClaudeHookPreferences.swift:5-8`

- [ ] **在现有键常量之后添加 triggerOnStopKey 和 triggerOnSessionEndKey**

在 `static let autoFocusOnSessionEndKey` 之后添加：
```swift
static let triggerOnStopKey = "claudeHookTriggerOnStop"
static let triggerOnSessionEndKey = "claudeHookTriggerOnSessionEnd"
```

---

### Task 8: ClaudeHookPreferences — 添加 triggerOnStop 存取属性

**Files:** Modify: `Sources/ClaudeHookPreferences.swift` (autoFocusOnSessionEnd 之后)

- [ ] **添加 triggerOnStop 计算属性**

```swift
static var triggerOnStop: Bool {
    get { UserDefaults.standard.object(forKey: triggerOnStopKey) as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: triggerOnStopKey) }
}
```

---

### Task 9: ClaudeHookPreferences — 添加 triggerOnSessionEnd 存取属性

**Files:** Modify: `Sources/ClaudeHookPreferences.swift`

- [ ] **添加 triggerOnSessionEnd 计算属性**

```swift
static var triggerOnSessionEnd: Bool {
    get { UserDefaults.standard.object(forKey: triggerOnSessionEndKey) as? Bool ?? false }
    set { UserDefaults.standard.set(newValue, forKey: triggerOnSessionEndKey) }
}
```

---

### Task 10: ClaudeHookPreferences — 添加 Claude settings 路径常量

**Files:** Modify: `Sources/ClaudeHookPreferences.swift`

- [ ] **在 normalizePort 方法之后添加 Claude settings 路径属性**

```swift
// MARK: - Claude Settings Integration

static var claudeSettingsPath: String {
    (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
}

static var claudeSettingsDir: String {
    (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
}

static var claudeSettingsExists: Bool {
    FileManager.default.fileExists(atPath: claudeSettingsPath)
}
```

---

### Task 11: ClaudeHookPreferences — 添加 isHookInstalled 检测

**Files:** Modify: `Sources/ClaudeHookPreferences.swift`

- [ ] **添加 isHookInstalled 方法，遍历 settings.json hooks 检测是否包含我们端点**

```swift
static var isHookInstalled: Bool {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: claudeSettingsPath)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let hooks = json["hooks"] as? [String: Any] else {
        return false
    }
    let targetURL = endpointURLString()
    for (_, entries) in hooks {
        guard let entryList = entries as? [[String: Any]] else { continue }
        for entry in entryList {
            guard let hookList = entry["hooks"] as? [[String: Any]] else { continue }
            for hook in hookList {
                if let url = hook["url"] as? String, url == targetURL {
                    return true
                }
            }
        }
    }
    return false
}
```

---

### Task 12: ClaudeHookPreferences — 添加 makeHookEntry 辅助方法

**Files:** Modify: `Sources/ClaudeHookPreferences.swift`

- [ ] **添加单个 Hook 条目生成方法**

```swift
// MARK: - Hook Config Generation

private static func makeHookEntry(url: String) -> [String: Any] {
    [
        "matcher": "",
        "hooks": [
            ["type": "http", "url": url, "timeout": 5]
        ]
    ]
}
```

---

### Task 13: ClaudeHookPreferences — 添加 generateHooksDict 方法

**Files:** Modify: `Sources/ClaudeHookPreferences.swift`

- [ ] **生成 VibeFocus 需要的 hooks 字典**

```swift
static func generateHooksDict() -> [String: Any] {
    let url = endpointURLString()
    var hooks: [String: Any] = [:]

    // SessionStart 始终安装
    hooks["SessionStart"] = [makeHookEntry(url: url)]

    if triggerOnStop {
        hooks["Stop"] = [makeHookEntry(url: url)]
    }
    if triggerOnSessionEnd {
        hooks["SessionEnd"] = [makeHookEntry(url: url)]
    }

    return hooks
}
```

---

### Task 14: ClaudeHookPreferences — 添加 generateHooksJSON 方法

**Files:** Modify: `Sources/ClaudeHookPreferences.swift`

- [ ] **生成完整 settings.json JSON 字符串（用于复制到剪贴板）**

```swift
static func generateHooksJSON() -> String {
    let hooks = generateHooksDict()
    let settings: [String: Any] = ["hooks": hooks]
    guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]),
          let json = String(data: data, encoding: .utf8) else {
        return "{\n  \"hooks\": {}\n}"
    }
    return json
}
```

---

### Task 15: ClaudeHookPreferences — 添加 installHookToClaudeSettings 方法

**Files:** Modify: `Sources/ClaudeHookPreferences.swift`

- [ ] **安全 merge Hook 到 Claude settings.json**

```swift
static func installHookToClaudeSettings() -> (Bool, String) {
    let path = claudeSettingsPath
    let dir = claudeSettingsDir

    do {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    } catch {
        return (false, "无法创建目录: \(error.localizedDescription)")
    }

    var settings: [String: Any] = [:]
    if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
       let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        settings = existing
    }

    var existingHooks = (settings["hooks"] as? [String: Any]) ?? [:]
    let ourHooks = generateHooksDict()
    for (key, value) in ourHooks {
        existingHooks[key] = value
    }
    if !triggerOnStop { existingHooks.removeValue(forKey: "Stop") }
    if !triggerOnSessionEnd { existingHooks.removeValue(forKey: "SessionEnd") }
    settings["hooks"] = existingHooks

    guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else {
        return (false, "无法序列化 JSON")
    }
    do {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return (true, "已安装到 \(path)")
    } catch {
        return (false, "写入失败: \(error.localizedDescription)")
    }
}
```

---

### Task 16: ClaudeHookPreferences — 添加 uninstallHookFromClaudeSettings 方法

**Files:** Modify: `Sources/ClaudeHookPreferences.swift`

- [ ] **从 Claude settings.json 中精确移除 VibeFocus Hook**

```swift
static func uninstallHookFromClaudeSettings() -> (Bool, String) {
    let path = claudeSettingsPath
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          var hooks = settings["hooks"] as? [String: Any] else {
        return (false, "无法读取 Claude 配置")
    }

    let targetURL = endpointURLString()
    for key in ["SessionStart", "Stop", "SessionEnd"] {
        guard var entries = hooks[key] as? [[String: Any]] else { continue }
        entries.removeAll { entry in
            guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
            return hookList.contains { $0["url"] as? String == targetURL }
        }
        if entries.isEmpty { hooks.removeValue(forKey: key) }
        else { hooks[key] = entries }
    }

    settings["hooks"] = hooks.isEmpty ? nil : hooks
    guard let outputData = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else {
        return (false, "无法序列化配置")
    }
    do {
        try outputData.write(to: URL(fileURLWithPath: path), options: .atomic)
        return (true, "已移除 Hook")
    } catch {
        return (false, "写入失败: \(error.localizedDescription)")
    }
}
```

---

### Task 17: ClaudeHookPreferences — 更新 hookCommandExample 适配新事件

**Files:** Modify: `Sources/ClaudeHookPreferences.swift:63-83`

- [ ] **更新 hookCommandExample 方法，添加 Stop 事件到 curl 示例**

在 `EVENT="$1"` 的注释区域中，更新示例使其支持三种事件。

---

### Task 18: 编译验证 — 偏好配置层

- [ ] **编译**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected: `Build complete!`

---

## Part C: Hook Server 事件处理层（Task 19-24）

### Task 19: ClaudeHookServer — 提取 handleWindowMoveTrigger 方法

**Files:** Modify: `Sources/ClaudeHookServer.swift` (在 handleRequest 方法之后)

- [ ] **添加私有的窗口移动触发方法**

```swift
private func handleWindowMoveTrigger(
    payload: ClaudeHookPayload,
    triggerName: String
) -> (statusCode: Int, response: ClaudeHookResponse) {
    guard ClaudeHookPreferences.autoFocusOnSessionEnd else {
        SessionWindowRegistry.shared.touch(
            sessionID: payload.sessionID,
            message: "\(triggerName) 收到（自动聚焦已关闭）"
        )
        handledRequestCount += 1
        return (200, ClaudeHookResponse(ok: true, code: "auto_focus_disabled",
            message: "\(triggerName) received, auto focus disabled",
            sessionID: payload.sessionID, handled: false))
    }

    guard let binding = SessionWindowRegistry.shared.binding(for: payload.sessionID) else {
        unmatchedSessionCount += 1
        SessionWindowRegistry.shared.setLastEventDescription("\(triggerName) 未命中绑定：\(payload.sessionID)")
        return (404, ClaudeHookResponse(ok: false, code: "binding_not_found",
            message: "No bound window for session",
            sessionID: payload.sessionID, handled: false))
    }

    if binding.isCompleted {
        handledRequestCount += 1
        return (200, ClaudeHookResponse(ok: true, code: "already_completed",
            message: "Session already completed",
            sessionID: payload.sessionID, handled: false))
    }

    let moved = WindowManager.shared.moveWindowToMainScreen(
        identity: binding.windowIdentity,
        reason: .claudeSessionEnd,
        sessionID: payload.sessionID
    )
    if moved {
        SessionWindowRegistry.shared.markCompleted(sessionID: payload.sessionID)
        handledRequestCount += 1
        return (200, ClaudeHookResponse(ok: true, code: "window_focused",
            message: "Window moved to main screen and maximized",
            sessionID: payload.sessionID, handled: true))
    }

    SessionWindowRegistry.shared.touch(
        sessionID: payload.sessionID,
        message: "\(triggerName) 命中绑定，但移动窗口失败"
    )
    return (409, ClaudeHookResponse(ok: false, code: "window_move_failed",
        message: "Found session binding but failed to move window",
        sessionID: payload.sessionID, handled: false))
}
```

---

### Task 20: ClaudeHookServer — 更新 sessionStart case 增强日志

**Files:** Modify: `Sources/ClaudeHookServer.swift:270-296`

- [ ] **在 sessionStart case 的 log 中加入 cwd 和 model**

在现有的 SessionStart 处理成功后的 log 调用中添加：
```swift
"cwd": payload.cwd ?? "nil",
"model": payload.model ?? "nil"
```

---

### Task 21: ClaudeHookServer — 添加 stop case 处理

**Files:** Modify: `Sources/ClaudeHookServer.swift:298`

- [ ] **在 sessionEnd case 之前添加 stop case**

```swift
case .stop:
    guard ClaudeHookPreferences.triggerOnStop else {
        SessionWindowRegistry.shared.touch(
            sessionID: payload.sessionID,
            message: "Stop 收到（Stop 触发已关闭）"
        )
        handledRequestCount += 1
        return (200, ClaudeHookResponse(ok: true, code: "stop_trigger_disabled",
            message: "Stop received, trigger disabled",
            sessionID: payload.sessionID, handled: false))
    }
    return handleWindowMoveTrigger(payload: payload, triggerName: "Stop")
```

---

### Task 22: ClaudeHookServer — 更新 sessionEnd case 使用共享方法

**Files:** Modify: `Sources/ClaudeHookServer.swift:298-380`

- [ ] **将现有的 sessionEnd 处理逻辑替换为一行调用**

当前整个 sessionEnd 的处理块替换为：
```swift
case .sessionEnd:
    return handleWindowMoveTrigger(payload: payload, triggerName: "SessionEnd")
```

---

### Task 23: ClaudeHookServer — 添加状态变更通知

**Files:** Modify: `Sources/ClaudeHookServer.swift:80-105`

- [ ] **在 handleListenerState 的 .ready case 中添加通知**

在 `log("[ClaudeHookServer] listening on 127.0.0.1:\(port)")` 之后添加：
```swift
NotificationCenter.default.post(name: .hookServerStateChanged, object: nil)
```

- [ ] **在 .failed case 中添加通知**

在 `listener = nil` 之后添加：
```swift
NotificationCenter.default.post(name: .hookServerStateChanged, object: nil)
```

---

### Task 24: 编译验证 — Server 层

- [ ] **编译**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected: `Build complete!`

---

## Part D: Session Registry UI 支持（Task 25-27）

### Task 25: SessionWindowRegistry — 添加 activeBindingsForUI

**Files:** Modify: `Sources/SessionWindowRegistry.swift`

- [ ] **在 setLastEventDescription 方法之后添加 UI 查询属性**

```swift
// MARK: - UI Support

var activeBindingsForUI: [SessionWindowBinding] {
    bindings.values
        .filter { !$0.isCompleted }
        .sorted { $0.createdAt > $1.createdAt }
}
```

---

### Task 26: SessionWindowRegistry — 添加 recentCompletedBindings 和 clearAllBindings

**Files:** Modify: `Sources/SessionWindowRegistry.swift`

- [ ] **添加最近完成绑定列表和清除方法**

```swift
var recentCompletedBindings: [SessionWindowBinding] {
    let now = Date()
    return bindings.values
        .filter { binding in
            guard binding.isCompleted else { return false }
            let deadline = (binding.completedAt ?? binding.lastSeenAt).addingTimeInterval(30 * 60)
            return deadline > now
        }
        .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
}

func clearAllBindings() {
    bindings.removeAll()
    lastEventDescription = "所有绑定已清除"
    persistBindings()
}
```

---

### Task 27: 编译验证 — Registry 层

- [ ] **编译**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected: `Build complete!`

---

## Part E: 通知名 + AppDelegate 启动（Task 28-29）

### Task 28: Support.swift — 添加 hookServerStateChanged 通知名

**Files:** Modify: `Sources/Support.swift:369`

- [ ] **在 Notification.Name extension 中添加**

在 `static let hotKeyConfigurationDidChange` 之后添加：
```swift
static let hookServerStateChanged = Notification.Name("ClaudeHookServerStateChanged")
```

---

### Task 29: AppDelegate — 启动时自动启动 Hook Server

**Files:** Modify: `Sources/SettingsUI.swift:1538`

- [ ] **在 HotKeyManager.shared.setup() 之后添加**

```swift
ClaudeHookServer.shared.applyPreferences()
```

---

## Part F: Settings UI（Task 30-44）

### Task 30: SettingsView — 添加属性声明

**Files:** Modify: `Sources/SettingsUI.swift:389`

- [ ] **在 SettingsView 的 @State 属性区域之后添加 Hook 相关属性**

在 `@State private var isCheckingInstallations = false` 之后添加：
```swift
@StateObject private var hookServer = ClaudeHookServer.shared
@StateObject private var sessionRegistry = SessionWindowRegistry.shared
@AppStorage(ClaudeHookPreferences.enabledKey) private var hookEnabled = false
@AppStorage(ClaudeHookPreferences.portKey) private var hookPort = ClaudeHookPreferences.defaultPort
@AppStorage(ClaudeHookPreferences.tokenKey) private var hookToken = ""
@AppStorage(ClaudeHookPreferences.autoFocusOnSessionEndKey) private var autoFocusOnSessionEnd = true
@AppStorage(ClaudeHookPreferences.triggerOnStopKey) private var triggerOnStop = true
@AppStorage(ClaudeHookPreferences.triggerOnSessionEndKey) private var triggerOnSessionEnd = false
@State private var hookInstallMessage: String?
@State private var hookInstallSucceeded = false
```

---

### Task 31: SettingsUI — 添加 Hook 设置卡片外壳和服务开关

**Files:** Modify: `Sources/SettingsUI.swift`

- [ ] **在"跨工作区（高级）"卡片之后插入新 SettingsCard 的开头部分**

在"屏幕序号显示"卡片之前插入。这部分是卡片外壳 + 服务开关 + Divider：

```swift
SettingsCard(
    title: "Claude Code 集成",
    subtitle: "对话完成时自动将终端窗口拉回主屏幕。安装 Hook 后，Claude Code 会直接通知 VibeFocus。"
) {
    SettingsRow(
        title: "Hook 服务",
        detail: hookServer.isRunning ? hookServer.statusDescription : "未启动"
    ) {
        HStack(spacing: 10) {
            SettingsStatusPill(
                title: hookServer.isRunning ? "运行中" : "未启动",
                tint: hookServer.isRunning ? .green : .gray
            )
            Toggle("", isOn: Binding(
                get: { hookEnabled },
                set: { newValue in
                    hookEnabled = newValue
                    ClaudeHookPreferences.isEnabled = newValue
                    hookServer.applyPreferences()
                }
            ))
            .labelsHidden()
        }
    }

    Divider()
```

---

### Task 32: SettingsUI — Hook 安装状态和安装/卸载按钮

**Files:** Modify: `Sources/SettingsUI.swift`

- [ ] **在 Task 31 的 Divider 之后继续添加安装区块**

```swift
    SettingsRow(
        title: "Hook 安装状态",
        detail: ClaudeHookPreferences.isHookInstalled
            ? "已安装到 ~/.claude/settings.json"
            : "尚未安装"
    ) {
        SettingsStatusPill(
            title: ClaudeHookPreferences.isHookInstalled ? "已安装" : "未安装",
            tint: ClaudeHookPreferences.isHookInstalled ? .green : .orange
        )
    }

    HStack(spacing: 12) {
        Button(ClaudeHookPreferences.isHookInstalled ? "重新安装" : "一键安装 Hook") {
            let (ok, msg) = ClaudeHookPreferences.installHookToClaudeSettings()
            hookInstallSucceeded = ok
            hookInstallMessage = msg
        }
        .buttonStyle(.borderedProminent)
        .disabled(!hookEnabled)

        if ClaudeHookPreferences.isHookInstalled {
            Button("卸载") {
                let (ok, msg) = ClaudeHookPreferences.uninstallHookFromClaudeSettings()
                hookInstallSucceeded = ok
                hookInstallMessage = msg
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.red)
        }

        Button("复制配置 JSON") {
            let json = ClaudeHookPreferences.generateHooksJSON()
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(json, forType: .string)
            hookInstallMessage = "已复制到剪贴板"
            hookInstallSucceeded = true
        }
        .buttonStyle(.bordered)

        Spacer()
    }

    if let msg = hookInstallMessage {
        Text(msg)
            .font(.system(size: 12))
            .foregroundStyle(hookInstallSucceeded ? .green : .red)
    }

    Divider()
```

---

### Task 33: SettingsUI — 触发时机选择

**Files:** Modify: `Sources/SettingsUI.swift`

- [ ] **添加 Stop/SessionEnd 触发开关**

```swift
    SettingsRow(title: "触发时机", detail: "选择何时自动将终端窗口拉回主屏幕") {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("对话完成（Stop 事件，推荐）", isOn: Binding(
                get: { triggerOnStop },
                set: { newValue in triggerOnStop = newValue; ClaudeHookPreferences.triggerOnStop = newValue }
            ))
            .toggleStyle(.checkbox)

            Toggle("会话结束（SessionEnd 事件）", isOn: Binding(
                get: { triggerOnSessionEnd },
                set: { newValue in triggerOnSessionEnd = newValue; ClaudeHookPreferences.triggerOnSessionEnd = newValue }
            ))
            .toggleStyle(.checkbox)
        }
    }

    Text("Stop：每次 Claude 回复完成后触发。SessionEnd：Claude 进程退出时触发。")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)

    Divider()
```

---

### Task 34: SettingsUI — 端口和 Token 配置

**Files:** Modify: `Sources/SettingsUI.swift`

- [ ] **添加端口输入框和 Token 配置**

```swift
    SettingsRow(
        title: "监听端口",
        detail: "默认 \(ClaudeHookPreferences.defaultPort)"
    ) {
        TextField("", value: Binding(
            get: { hookPort },
            set: { newValue in
                let clamped = max(1024, min(65535, newValue == 0 ? ClaudeHookPreferences.defaultPort : newValue))
                hookPort = clamped
                ClaudeHookPreferences.listenPort = clamped
                if hookEnabled { hookServer.applyPreferences() }
            }
        ), formatter: {
            let f = NumberFormatter(); f.numberStyle = .none; f.minimum = 1024; f.maximum = 65535; return f
        }())
        .textFieldStyle(.roundedBorder)
        .frame(width: 80)
    }

    SettingsRow(title: "鉴权 Token（可选）", detail: "启用后请求需携带 X-VibeFocus-Token 头") {
        HStack(spacing: 8) {
            SecureField("", text: Binding(
                get: { hookToken },
                set: { newValue in
                    hookToken = newValue
                    ClaudeHookPreferences.authToken = newValue.isEmpty ? nil : newValue
                    if hookEnabled { hookServer.applyPreferences() }
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 180)

            if hookToken.isEmpty {
                Button("随机生成") {
                    hookToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).lowercased()
                    ClaudeHookPreferences.authToken = hookToken
                    if hookEnabled { hookServer.applyPreferences() }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }
        }
    }

    Divider()
```

---

### Task 35: SettingsUI — 运行状态展示

**Files:** Modify: `Sources/SettingsUI.swift`

- [ ] **添加最近事件时间和统计计数器**

```swift
    SettingsRow(title: "运行状态", detail: sessionRegistry.lastEventDescription) {
        VStack(alignment: .trailing, spacing: 4) {
            if let lastEvent = hookServer.lastEventAt {
                Text("最近事件 \(lastEvent, style: .time)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text("已处理 \(hookServer.handledRequestCount) / 总计 \(hookServer.totalRequestCount) / 未匹配 \(hookServer.unmatchedSessionCount)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    if let error = hookServer.lastErrorMessage, !error.isEmpty {
        Text("错误：\(error)")
            .font(.system(size: 12))
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    Divider()
```

---

### Task 36: SettingsUI — 活跃会话列表

**Files:** Modify: `Sources/SettingsUI.swift`

- [ ] **添加活跃绑定列表展示**

```swift
    if !sessionRegistry.activeBindingsForUI.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
            Text("活跃会话（\(sessionRegistry.activeBindingCount)）")
                .font(.system(size: 13, weight: .medium))

            ForEach(sessionRegistry.activeBindingsForUI.prefix(5), id: \.sessionID) { binding in
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                    Text(binding.windowIdentity.appName ?? "Unknown")
                        .font(.system(size: 12, weight: .medium))
                    Text(binding.windowIdentity.title ?? "Untitled")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(binding.sessionID.prefix(8))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            if sessionRegistry.activeBindingsForUI.count > 5 {
                Text("还有 \(sessionRegistry.activeBindingsForUI.count - 5) 个...")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }
```

---

### Task 37: SettingsUI — 已完成会话列表

**Files:** Modify: `Sources/SettingsUI.swift`

- [ ] **添加最近完成的会话列表**

```swift
    if !sessionRegistry.recentCompletedBindings.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近完成（\(sessionRegistry.completedBindingCount)）")
                .font(.system(size: 13, weight: .medium))

            ForEach(sessionRegistry.recentCompletedBindings.prefix(3), id: \.sessionID) { binding in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                        .font(.system(size: 11))
                    Text(binding.windowIdentity.appName ?? "Unknown")
                        .font(.system(size: 12, weight: .medium))
                    if let completedAt = binding.completedAt {
                        Text(completedAt, style: .time)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
    }
```

---

### Task 38: SettingsUI — 测试按钮和关闭卡片

**Files:** Modify: `Sources/SettingsUI.swift`

- [ ] **添加测试事件按钮 + 清除绑定按钮 + 卡片关闭大括号**

```swift
    Divider()

    HStack(spacing: 12) {
        Button("发送测试事件") {
            sendTestHookEvent()
        }
        .buttonStyle(.bordered)
        .disabled(!hookEnabled || !hookServer.isRunning)

        Button("清除绑定") {
            sessionRegistry.clearAllBindings()
        }
        .buttonStyle(.bordered)
        .foregroundStyle(.red)

        Spacer()
    }

    Text("测试：SessionStart 绑定当前窗口 → 1 秒后 SessionEnd 触发移动")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
}
```

注意最后的 `}` 是关闭 SettingsCard。

---

### Task 39: SettingsUI — sendTestHookEvent 方法

**Files:** Modify: `Sources/SettingsUI.swift`

- [ ] **在 SettingsView 的 refreshInstallations() 之后添加测试事件发送方法**

```swift
private func sendTestHookEvent() {
    let sessionID = "test-\(UUID().uuidString.prefix(8))"
    guard let url = URL(string: ClaudeHookPreferences.endpointURLString()) else { return }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !hookToken.isEmpty {
        request.setValue(hookToken, forHTTPHeaderField: "X-VibeFocus-Token")
    }

    let startPayload: [String: String] = [
        "event": "SessionStart",
        "session_id": sessionID,
        "source": "test"
    ]
    request.httpBody = try? JSONSerialization.data(withJSONObject: startPayload)

    URLSession.shared.dataTask(with: request) { data, _, error in
        DispatchQueue.main.async {
            if let error {
                self.hookInstallMessage = "测试失败: \(error.localizedDescription)"
                self.hookInstallSucceeded = false
                return
            }
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = json["ok"] as? Bool, ok {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.sendTestEndEvent(sessionID: sessionID)
                }
            } else {
                self.hookInstallMessage = "SessionStart 失败"
                self.hookInstallSucceeded = false
            }
        }
    }.resume()
}
```

---

### Task 40: SettingsUI — sendTestEndEvent 方法

**Files:** Modify: `Sources/SettingsUI.swift`

- [ ] **添加 SessionEnd 测试方法**

```swift
private func sendTestEndEvent(sessionID: String) {
    guard let url = URL(string: ClaudeHookPreferences.endpointURLString()) else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !hookToken.isEmpty {
        request.setValue(hookToken, forHTTPHeaderField: "X-VibeFocus-Token")
    }

    let endPayload: [String: String] = [
        "event": "SessionEnd",
        "session_id": sessionID,
        "source": "test"
    ]
    request.httpBody = try? JSONSerialization.data(withJSONObject: endPayload)

    URLSession.shared.dataTask(with: request) { data, _, error in
        DispatchQueue.main.async {
            if let error {
                self.hookInstallMessage = "SessionEnd 失败: \(error.localizedDescription)"
                self.hookInstallSucceeded = false
            } else if let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let handled = json["handled"] as? Bool, handled {
                self.hookInstallMessage = "测试成功：窗口已移动，按 Ctrl+M 恢复"
                self.hookInstallSucceeded = true
            } else {
                self.hookInstallMessage = "SessionEnd 已发送但窗口未移动"
                self.hookInstallSucceeded = false
            }
        }
    }.resume()
}
```

---

### Task 41: SettingsUI — Sidebar 添加 Claude Hook 状态

**Files:** Modify: `Sources/SettingsUI.swift:534`

- [ ] **在 SidebarInfoCard 跨工作区之后添加**

在 `SidebarInfoCard(title: "跨工作区", value: spaceSidebarValue)` 之后添加：
```swift
SidebarInfoCard(title: "Claude Hook", value: hookEnabled ? (hookServer.isRunning ? "运行中" : "启动中") : "未启用")
```

---

### Task 42: SettingsUI — onChange 监听 Hook 偏好变化

**Files:** Modify: `Sources/SettingsUI.swift:1246-1261`

- [ ] **在现有 onChange 块之后添加 Hook 偏好变化的 onChange 处理**

```swift
.onChange(of: hookEnabled) { newValue in
    log("[Settings] hook enabled toggled", fields: ["enabled": String(newValue)])
}
.onChange(of: triggerOnStop) { newValue in
    log("[Settings] trigger on stop toggled", fields: ["enabled": String(newValue)])
}
```

---

### Task 43: 编译验证 — Settings UI 层

- [ ] **编译**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected: `Build complete!`

---

### Task 44: 编译验证 — 全量 debug build

- [ ] **完整编译确认无错误**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -10`
Expected: `Build complete!`

---

## Part G: 测试和提交（Task 45-52）

### Task 45: Release 构建

- [ ] **Release 构建**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -10`
Expected: `Build complete!`

---

### Task 46: 启动应用并验证 Hook 服务

- [ ] **启动应用**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && pkill -x VibeFocusHotkeys 2>/dev/null; sleep 0.3; .build/release/VibeFocusHotkeys &`

- [ ] **验证 Hook 服务未默认启动**（默认 isEnabled = false）

---

### Task 47: 测试 — 启用 Hook 服务

- [ ] **在设置窗口中开启 Hook 服务**
- [ ] **确认状态显示"运行中"**
- [ ] **确认端口显示 127.0.0.1:39277**

---

### Task 48: 测试 — 安装 Hook 到 Claude settings

- [ ] **点击"一键安装 Hook"**
- [ ] **验证文件内容**

Run: `cat ~/.claude/settings.json | python3 -m json.tool | head -30`
Expected: 包含 `hooks.SessionStart` 和 `hooks.Stop`

---

### Task 49: 测试 — 发送测试事件

- [ ] **点击"发送测试事件"**
- [ ] **观察窗口移动到主屏**
- [ ] **按 Ctrl+M 验证恢复**

---

### Task 50: 测试 — 卸载 Hook

- [ ] **点击"卸载"按钮**
- [ ] **验证 settings.json 中 hooks 被清除**

Run: `cat ~/.claude/settings.json | python3 -m json.tool`

---

### Task 51: 测试 — 检查日志

- [ ] **查看完整 Hook 日志**

Run: `grep "ClaudeHook\|session_bound\|window_focused\|hook_event_name" /tmp/vibefocus-events.jsonl | tail -20 | python3 -c "import sys,json; [print(json.dumps(json.loads(l),indent=2)) for l in sys.stdin]"`

---

### Task 52: 提交代码

- [ ] **提交**

```bash
git add Sources/ClaudeHookModels.swift Sources/ClaudeHookPreferences.swift Sources/ClaudeHookServer.swift Sources/SessionWindowRegistry.swift Sources/SettingsUI.swift Sources/Support.swift docs/superpowers/plans/2026-04-12-claude-hook-integration.md
git commit -m "feat(hooks): complete Claude Code Hook integration with settings UI

- Add Stop event support and hook_event_name field compatibility
- Add one-click install/uninstall to ~/.claude/settings.json (safe merge)
- Add settings card: service toggle, triggers, port, token, sessions, test
- Auto-start Hook server on app launch
- Generate HTTP Hook config for Claude Code settings"
```

- [ ] **打 tag**

```bash
git tag -a v0.6.0-claude-hook-integration -m "Claude Code Hook 集成"
```

---

## Dependencies

```
Part A (Models):      Task 1 → 2 → 3 → 4 → 5 → 6
Part B (Preferences): Task 7 → 8 → 9 → 10 → 11 → 12 → 13 → 14 → 15 → 16 → 17 → 18
Part C (Server):      Task 19 → 20 → 21 → 22 → 23 → 24
Part D (Registry):    Task 25 → 26 → 27
Part E (Support):     Task 28 → 29
Part F (Settings UI): Task 30 → 31 → 32 → 33 → 34 → 35 → 36 → 37 → 38 → 39 → 40 → 41 → 42 → 43 → 44
Part G (Test+Commit): Task 45 → 46 → 47 → 48 → 49 → 50 → 51 → 52
```

Part A 和 Part D 可以并行。Part B 依赖 Part A。Part C 依赖 Part A + Part B。Part F 依赖 Part A-D。Part G 依赖 Part A-F。

## Risks

1. **settings.json merge** — 安装时只覆盖 SessionStart/Stop/SessionEnd，保留用户其他 hooks
2. **Stop 事件频率** — 每次回复都触发，isCompleted 标记保证幂等
3. **窗口 ID 失效** — resolveWindow() 有 fallback 匹配（pid+title+position）
4. **端口冲突** — NWListener 返回 .failed 状态，UI 展示错误信息
5. **hook_event_name vs event** — 同时支持两种字段名确保兼容
