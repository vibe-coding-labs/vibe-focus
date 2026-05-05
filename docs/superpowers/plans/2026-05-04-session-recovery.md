# Session Recovery — 机器重启后自动恢复 Claude Code 工作区

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 机器重启后，VibeFocus 能自动恢复用户之前的完整 Claude Code 工作区：打开 Terminal 窗口 → CD 到项目目录 → 用 `claude --resume <session_id>` 恢复会话。手动 exit 退出（`/exit` 命令）的会话不恢复。

**Architecture:** 
- 数据流：SessionStart hook → 采集 (sessionID, cwd, model, terminalApp, TTY, PPID) → 持久化到 SessionSnapshot → SessionEnd hook 标记 `manuallyExited=true/false` → 重启后 RecoveryManager 读取未完成 snapshots → 按终端 App 分组 → 打开终端 → CD → `claude --resume`
- 关键组件：SessionSnapshot（持久化模型）、RecoveryManager（恢复逻辑）、RecoverySettingsView（UI 开关）
- 设计理由：复用现有 SessionWindowRegistry 的 UserDefaults 持久化，不引入新存储层

**Tech Stack:** Swift 5.9, macOS 14+, UserDefaults, NSWorkspace, Process (NSTask)

**Risks:**
- Claude Code `--resume` 需要验证在当前版本是否可用 → 缓解：先运行 `claude --help` 验证
- Terminal.app 不支持 `open -a Terminal` 传入命令 → 缓解：用 `osascript` 执行 AppleScript 打开终端并执行命令
- 多个 snapshot 恢复时可能打开重复终端窗口 → 缓解：按终端 App 去重，一个 App 只打开一个窗口恢复所有 sessions
- SessionEnd 事件可能不在所有 Claude Code 版本中触发 → 缓解：用 Stop + debounce 作为 fallback

---

### Task 1: 扩展 SessionWindowBinding — 添加 cwd、model、manuallyExited 字段

**Depends on:** None
**Files:**
- Modify: `Sources/ClaudeHookModels.swift:25-33`（SessionWindowBinding struct）

- [ ] **Step 1: 修改 SessionWindowBinding — 添加会话恢复所需的持久化字段**

文件: `Sources/ClaudeHookModels.swift:25-33`

```swift
struct SessionWindowBinding: Codable, Equatable {
    let sessionID: String
    var windowIdentity: WindowIdentity
    let createdAt: Date
    var lastSeenAt: Date
    var isCompleted: Bool
    var completedAt: Date?

    /// 绑定创建时终端的 TTY 路径（如 /dev/ttys001），用于严格验证窗口身份
    let terminalTTY: String?
    /// 终端会话标识（TERM_SESSION_ID 或 ITERM_SESSION_ID）
    let terminalSessionID: String?

    // --- 会话恢复字段 ---

    /// Claude Code 启动时的工作目录（项目路径）
    let cwd: String?
    /// Claude Code 使用的模型名称
    let model: String?
    /// 用户是否手动退出（/exit 或 Ctrl+C 确认退出）
    /// true = 不恢复, false/null = 可以恢复
    var manuallyExited: Bool?
}
```

- [ ] **Step 2: 更新所有 SessionWindowBinding 创建点 — 传入新字段**

需要在以下位置添加 `cwd`、`model`、`manuallyExited` 参数：

1. `Sources/SessionWindowRegistry.swift:47-56` — `bind()` 方法中的新建路径：
```swift
bindings[normalizedSession] = SessionWindowBinding(
    sessionID: normalizedSession,
    windowIdentity: windowIdentity,
    createdAt: now,
    lastSeenAt: now,
    isCompleted: false,
    completedAt: nil,
    terminalTTY: terminalTTY,
    terminalSessionID: terminalSessionID,
    cwd: nil,  // 将由 handleSessionStart 传入
    model: nil,
    manuallyExited: nil
)
```

2. `Sources/ClaudeHookServer.swift` 中所有 `SessionWindowBinding(...)` 构造调用 — 添加 `cwd: payload.cwd, model: payload.model, manuallyExited: nil`

- [ ] **Step 3: 更新 bind() 方法签名 — 传入 cwd 和 model**

文件: `Sources/SessionWindowRegistry.swift` — `bind()` 方法

```swift
func bind(
    sessionID: String,
    windowIdentity: WindowIdentity,
    terminalTTY: String? = nil,
    terminalSessionID: String? = nil,
    cwd: String? = nil,
    model: String? = nil
) {
```

新建 binding 时传入:
```swift
cwd: cwd,
model: model,
manuallyExited: nil
```

- [ ] **Step 4: 更新 handleSessionStart 中 bind 调用 — 传入 cwd 和 model**

文件: `Sources/ClaudeHookServer.swift` — handleSessionStart 中的 bind 调用

```swift
SessionWindowRegistry.shared.bind(
    sessionID: payload.sessionID,
    windowIdentity: identity,
    terminalTTY: payload.terminalCtx?.tty,
    terminalSessionID: payload.terminalCtx?.termSessionID ?? payload.terminalCtx?.itermSessionID,
    cwd: payload.cwd,
    model: payload.model
)
```

- [ ] **Step 5: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 6: 提交**
Run: `git add Sources/ClaudeHookModels.swift Sources/ClaudeHookServer.swift Sources/SessionWindowRegistry.swift && git commit -m "feat(recovery): add cwd, model, manuallyExited fields to SessionWindowBinding"`

---

### Task 2: 配置 SessionEnd Hook — 采集会话退出事件

**Depends on:** None
**Files:**
- Modify: `~/.claude/settings.json` — 添加 SessionEnd hook
- Modify: `Sources/ClaudeHookModels.swift` — 确保 SessionEnd 已在 enum 中

- [ ] **Step 1: 确认 ClaudeHookEventType 已包含 SessionEnd**

文件: `Sources/ClaudeHookModels.swift:3-8`

已有 `case sessionEnd = "SessionEnd"`，无需修改。

- [ ] **Step 2: 确认 handleSessionEnd 路由存在**

文件: `Sources/ClaudeHookServer.swift` — 搜索 `handleSessionEnd`

确认路由逻辑：SessionEnd → handleWindowMoveTrigger（已有）。

- [ ] **Step 3: 在 handleSessionEnd 中标记 manuallyExited — 区分手动退出和异常终止**

文件: `Sources/ClaudeHookServer.swift` — handleSessionEnd 路由处

需要在 SessionEnd 事件处理时，将 binding 的 `manuallyExited` 设为 `false`（正常结束 = 不需要恢复）。
同时将 `isCompleted` 设为 true，`completedAt` 设为当前时间。

```swift
// 在 handleSessionEnd 路由中（ClaudeHookServer.swift 的 routeRequest 函数）
// SessionEnd 表示 Claude Code 会话正常结束
case .sessionEnd:
    // 标记会话为手动结束（用户主动退出或会话自然结束）— 不应恢复
    SessionWindowRegistry.shared.markManuallyExited(sessionID: payload.sessionID)
    SessionWindowRegistry.shared.markCompleted(sessionID: payload.sessionID)
    SessionWindowRegistry.shared.touch(
        sessionID: payload.sessionID,
        message: "SessionEnd 收到：会话正常结束"
    )
    handledRequestCount += 1
    return (
        200,
        ClaudeHookResponse(
            ok: true, code: "session_ended",
            message: "Session ended normally",
            sessionID: payload.sessionID, handled: true
        )
    )
```

- [ ] **Step 4: 在 SessionWindowRegistry 中添加 markManuallyExited 方法**

文件: `Sources/SessionWindowRegistry.swift`

```swift
func markManuallyExited(sessionID: String) {
    let normalizedSession = normalizeSessionID(sessionID)
    guard !normalizedSession.isEmpty, var binding = bindings[normalizedSession] else { return }
    binding.manuallyExited = true
    binding.lastSeenAt = Date()
    bindings[normalizedSession] = binding
    persistBindings()
}
```

- [ ] **Step 5: 在 settings.json 中添加 SessionEnd hook**

SessionEnd hook 需要转发到 VibeFocus：

Run: `python3 << 'PYEOF'
import json

with open('/Users/cc11001100/.claude/settings.json', 'r') as f:
    data = json.load(f)

hooks = data.setdefault('hooks', {})
session_end = hooks.setdefault('SessionEnd', [])

# 检查是否已有 hook-forwarder
has_forwarder = any(
    any(hook.get('command', '').find('hook-forwarder') >= 0 for hook in h.get('hooks', []))
    for h in session_end
)

if not has_forwarder:
    session_end.append({
        "hooks": [{"command": "bash ~/.vibefocus/hook-forwarder.sh", "timeout": 10, "type": "command"}],
        "matcher": ""
    })
    print("Added SessionEnd hook")
else:
    print("SessionEnd hook already exists")

with open('/Users/cc11001100/.claude/settings.json', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
print("settings.json updated")
PYEOF`

Expected:
  - Output contains: "Added SessionEnd hook" 或 "SessionEnd hook already exists"

- [ ] **Step 6: 验证编译 + settings.json**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 7: 提交**
Run: `git add Sources/ClaudeHookServer.swift Sources/SessionWindowRegistry.swift && git commit -m "feat(recovery): add SessionEnd hook handler — mark sessions as manually exited for recovery logic"`

---

### Task 3: 创建 SessionSnapshot 持久化 — 重启后可恢复的会话快照

**Depends on:** Task 1, Task 2
**Files:**
- Create: `Sources/SessionSnapshot.swift`
- Modify: `Sources/SessionWindowRegistry.swift` — 在 binding 创建/完成时同步快照

- [ ] **Step 1: 创建 SessionSnapshot model — 独立于 binding 的恢复数据结构**

```swift
// Sources/SessionSnapshot.swift
import Foundation

/// 会话快照：持久化到 UserDefaults，用于机器重启后恢复 Claude Code 会话
/// 与 SessionWindowBinding 的区别：Snapshot 是面向恢复的精简数据，不依赖运行时窗口 ID
struct SessionSnapshot: Codable, Equatable {
    /// Claude Code session ID（用于 claude --resume）
    let sessionID: String
    /// 项目工作目录
    let cwd: String
    /// Claude 模型名称
    let model: String?
    /// 终端 App 的 bundleIdentifier（如 com.apple.Terminal）
    let terminalBundleID: String?
    /// 终端 App 名称（如 Terminal, iTerm2）
    let terminalAppName: String?
    /// 终端的 TTY（仅记录用，重启后可能变化）
    let tty: String?
    /// 快照创建时间
    let createdAt: Date
    /// 最后活跃时间
    var lastActiveAt: Date
    /// 用户是否手动退出（true = 不恢复）
    var manuallyExited: Bool
    /// 恢复状态：pending = 待恢复, restored = 已恢复, expired = 已过期
    var restoreStatus: RestoreStatus

    enum RestoreStatus: String, Codable {
        case pending    // 待恢复（未手动退出 + 未恢复）
        case restored   // 已恢复
        case expired    // 已过期（超过恢复窗口期）
    }
}

@MainActor
final class SessionSnapshotStore: ObservableObject {
    static let shared = SessionSnapshotStore()

    private let storeKey = "vibefocus.sessionSnapshots.v1"
    @Published private(set) var snapshots: [SessionSnapshot] = []

    private init() {
        snapshots = loadSnapshots()
    }

    // MARK: - Public API

    /// 保存或更新快照
    func upsert(_ snapshot: SessionSnapshot) {
        if let idx = snapshots.firstIndex(where: { $0.sessionID == snapshot.sessionID }) {
            snapshots[idx] = snapshot
        } else {
            snapshots.append(snapshot)
        }
        persist()
    }

    /// 标记会话为手动退出
    func markManuallyExited(sessionID: String) {
        guard let idx = snapshots.firstIndex(where: { $0.sessionID == sessionID }) else { return }
        snapshots[idx].manuallyExited = true
        snapshots[idx].restoreStatus = .expired
        persist()
    }

    /// 获取所有待恢复的快照（未手动退出 + 未恢复 + 未过期）
    func pendingSnapshots(maxAge: TimeInterval = 24 * 60 * 60) -> [SessionSnapshot] {
        let cutoff = Date().addingTimeInterval(-maxAge)
        return snapshots.filter { snap in
            !snap.manuallyExited
                && snap.restoreStatus == .pending
                && snap.lastActiveAt > cutoff
        }
    }

    /// 标记快照为已恢复
    func markRestored(sessionID: String) {
        guard let idx = snapshots.firstIndex(where: { $0.sessionID == sessionID }) else { return }
        snapshots[idx].restoreStatus = .restored
        persist()
    }

    /// 清理过期快照（7 天以上）
    func pruneExpired() {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        snapshots.removeAll { $0.lastActiveAt < cutoff }
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }

    private func loadSnapshots() -> [SessionSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([SessionSnapshot].self, from: data) else {
            return []
        }
        return decoded
    }
}
```

- [ ] **Step 2: 在 handleSessionStart 中创建快照 — 绑定成功时保存恢复数据**

文件: `Sources/ClaudeHookServer.swift` — handleSessionStart 绑定成功后

```swift
// 在 SessionWindowRegistry.shared.bind(...) 之后添加
if let cwd = payload.cwd, !cwd.isEmpty {
    let snapshot = SessionSnapshot(
        sessionID: payload.sessionID,
        cwd: cwd,
        model: payload.model,
        terminalBundleID: identity.bundleIdentifier,
        terminalAppName: identity.appName,
        tty: payload.terminalCtx?.tty,
        createdAt: Date(),
        lastActiveAt: Date(),
        manuallyExited: false,
        restoreStatus: .pending
    )
    SessionSnapshotStore.shared.upsert(snapshot)
}
```

- [ ] **Step 3: 在 handleUserPromptSubmit 中更新快照活跃时间**

文件: `Sources/ClaudeHookServer.swift` — handleUserPromptSubmit 开头（lastActivityBySession 之后）

```swift
// 更新快照活跃时间
if let existing = SessionSnapshotStore.shared.snapshots.first(where: { $0.sessionID == payload.sessionID }) {
    SessionSnapshotStore.shared.upsert(SessionSnapshot(
        sessionID: existing.sessionID,
        cwd: existing.cwd,
        model: existing.model,
        terminalBundleID: existing.terminalBundleID,
        terminalAppName: existing.terminalAppName,
        tty: existing.tty,
        createdAt: existing.createdAt,
        lastActiveAt: Date(),
        manuallyExited: existing.manuallyExited,
        restoreStatus: existing.restoreStatus
    ))
}
```

- [ ] **Step 4: 在 SessionEnd handler 中标记快照为手动退出**

已在 Task 2 Step 3 中添加 `markManuallyExited`。SessionSnapshotStore 也有同名方法，需要在 handleSessionEnd 中同时调用：

```swift
// 在 SessionWindowRegistry.shared.markManuallyExited 之后添加
SessionSnapshotStore.shared.markManuallyExited(sessionID: payload.sessionID)
```

- [ ] **Step 5: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 6: 提交**
Run: `git add Sources/SessionSnapshot.swift Sources/ClaudeHookServer.swift && git commit -m "feat(recovery): add SessionSnapshot persistence — save session state for post-restart recovery"`

---

### Task 4: 创建 RecoveryManager — 重启后恢复 Claude Code 会话

**Depends on:** Task 3
**Files:**
- Create: `Sources/RecoveryManager.swift`

- [ ] **Step 1: 创建 RecoveryManager — 核心恢复逻辑**

```swift
// Sources/RecoveryManager.swift
import Foundation
import AppKit

@MainActor
final class RecoveryManager: ObservableObject {
    static let shared = RecoveryManager()

    @Published private(set) var isRecovering = false
    @Published private(set) var recoveryLog: [String] = []

    private init() {}

    // MARK: - Public API

    /// 检查是否有待恢复的会话
    var hasPendingSessions: Bool {
        !SessionSnapshotStore.shared.pendingSnapshots().isEmpty
    }

    /// 获取待恢复的会话列表
    var pendingSnapshots: [SessionSnapshot] {
        SessionSnapshotStore.shared.pendingSnapshots()
    }

    /// 执行恢复：为每个 snapshot 打开终端并运行 claude --resume
    func recoverAllSessions() {
        let snapshots = SessionSnapshotStore.shared.pendingSnapshots()
        guard !snapshots.isEmpty else {
            appendLog("没有待恢复的会话")
            return
        }

        isRecovering = true
        appendLog("开始恢复 \(snapshots.count) 个会话...")

        // 按终端 App 分组
        let grouped = Dictionary(grouping: snapshots) { $0.terminalAppName ?? "Terminal" }

        for (appName, group) in grouped {
            for snapshot in group {
                recoverSession(snapshot, appName: appName)
            }
        }

        isRecovering = false
        appendLog("恢复完成")
    }

    /// 恢复单个会话
    func recoverSession(_ snapshot: SessionSnapshot, appName: String? = nil) {
        let terminalApp = appName ?? snapshot.terminalAppName ?? "Terminal"

        // 构建 claude --resume 命令
        var claudeArgs = ["--resume", snapshot.sessionID]
        if let model = snapshot.model, !model.isEmpty {
            claudeArgs += ["--model", model]
        }

        let cdCommand = "cd '\(snapshot.cwd.replacingOccurrences(of: "'", with: "'\\''"))'"
        let claudeCommand = "claude \(claudeArgs.joined(separator: " "))"

        // 用 AppleScript 在终端中执行
        let script: String
        switch terminalApp {
        case "iTerm2":
            script = """
            tell application "iTerm2"
                activate
                create window with default profile
                tell current session of current window
                    write text "\(cdCommand) && \(claudeCommand)"
                end tell
            end tell
            """
        default:
            // Terminal.app
            script = """
            tell application "Terminal"
                activate
                do script "\(cdCommand) && \(claudeCommand)"
            end tell
            """
        end switch

        let success = runAppleScript(script)
        if success {
            SessionSnapshotStore.shared.markRestored(sessionID: snapshot.sessionID)
            appendLog("已恢复: \(snapshot.sessionID.prefix(8))... (\(snapshot.cwd))")
        } else {
            appendLog("恢复失败: \(snapshot.sessionID.prefix(8))... (\(snapshot.cwd))")
        }
    }

    /// 检查并恢复 — VibeFocus 启动时调用
    func checkAndRecoverOnStartup() {
        SessionSnapshotStore.shared.pruneExpired()

        guard hasPendingSessions else {
            appendLog("启动检查: 无待恢复会话")
            return
        }

        let count = pendingSnapshots.count
        appendLog("启动检查: 发现 \(count) 个待恢复会话")

        // TODO: 根据 RecoveryPreferences.autoRestoreOnStartup 决定是否自动恢复
        // 当前先只记录，由 UI 触发恢复
    }

    // MARK: - Private

    private func runAppleScript(_ script: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let pipe = Pipe()
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func appendLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        recoveryLog.append("[\(timestamp)] \(message)")
    }
}
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/RecoveryManager.swift && git commit -m "feat(recovery): add RecoveryManager — restore Claude Code sessions via Terminal/iTerm2"`

---

### Task 5: 添加恢复偏好设置 — UI 开关和一键恢复按钮

**Depends on:** Task 4
**Files:**
- Create: `Sources/RecoveryPreferences.swift`
- Modify: `Sources/SettingsUI.swift` — 添加恢复设置 section

- [ ] **Step 1: 创建 RecoveryPreferences — 恢复相关的偏好设置**

```swift
// Sources/RecoveryPreferences.swift
import Foundation

struct RecoveryPreferences {
    static var autoRestoreOnStartup: Bool {
        get { UserDefaults.standard.bool(forKey: "vibefocus.autoRestoreOnStartup") }
        set { UserDefaults.standard.set(newValue, forKey: "vibefocus.autoRestoreOnStartup") }
    }

    static var showRecoveryNotification: Bool {
        get { UserDefaults.standard.object(forKey: "vibefocus.showRecoveryNotification") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "vibefocus.showRecoveryNotification") }
    }

    /// 恢复窗口期（秒），默认 24 小时
    static var recoveryWindow: TimeInterval {
        get { UserDefaults.standard.double(forKey: "vibefocus.recoveryWindow") }
        set { UserDefaults.standard.set(newValue, forKey: "vibefocus.recoveryWindow") }
    }

    static var recoveryWindowHours: Double {
        get { RecoveryPreferences.recoveryWindow / 3600 }
        set { RecoveryPreferences.recoveryWindow = newValue * 3600 }
    }

    static let recoveryWindowKey = "vibefocus.autoRestoreOnStartup"
}
```

- [ ] **Step 2: 在 SettingsUI 中添加恢复设置 section**

文件: `Sources/SettingsUI.swift` — 在 Claude Hook 设置 section 之后添加

在 SettingsUI 的 hook 相关设置区域之后，添加一个新的 "会话恢复" section：

```swift
// 在 Claude Hook 设置之后添加会话恢复 section
Divider().padding(.vertical, 8)

HStack {
    Text("会话恢复")
        .font(.headline)
    Spacer()
}

VStack(alignment: .leading, spacing: 12) {
    Toggle(isOn: Binding(
        get: { RecoveryPreferences.autoRestoreOnStartup },
        set: { RecoveryPreferences.autoRestoreOnStartup = $0 }
    )) {
        VStack(alignment: .leading) {
            Text("启动时自动恢复会话")
            Text("机器重启后自动恢复未结束的 Claude Code 会话")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    Toggle(isOn: Binding(
        get: { RecoveryPreferences.showRecoveryNotification },
        set: { RecoveryPreferences.showRecoveryNotification = $0 }
    )) {
        Text("显示恢复通知")
    }

    HStack {
        Text("恢复窗口期：")
        Slider(value: Binding(
            get: { RecoveryPreferences.recoveryWindowHours },
            set: { RecoveryPreferences.recoveryWindowHours = $0 }
        ), in: 1...72, step: 1) {
            Text("小时")
        }
        Text("\(Int(RecoveryPreferences.recoveryWindowHours)) 小时")
            .frame(width: 60)
    }

    Divider()

    HStack {
        VStack(alignment: .leading) {
            Text("待恢复会话")
                .font(.subheadline)
            if RecoveryManager.shared.hasPendingSessions {
                Text("\(RecoveryManager.shared.pendingSnapshots.count) 个会话待恢复")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("无待恢复会话")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        Spacer()
        Button("立即恢复") {
            RecoveryManager.shared.recoverAllSessions()
        }
        .disabled(!RecoveryManager.shared.hasPendingSessions)
    }

    if !RecoveryManager.shared.recoveryLog.isEmpty {
        ScrollView {
            VStack(alignment: .leading) {
                ForEach(RecoveryManager.shared.recoveryLog, id: \.self) { entry in
                    Text(entry)
                        .font(.system(.caption, design: .monospaced))
                }
            }
        }
        .frame(maxHeight: 100)
    }
}
```

- [ ] **Step 3: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/RecoveryPreferences.swift Sources/SettingsUI.swift && git commit -m "feat(recovery): add recovery preferences UI — auto-restore toggle, manual restore button"`

---

### Task 6: 防止重复恢复 + 启动时自动检查

**Depends on:** Task 4, Task 5
**Files:**
- Modify: `Sources/RecoveryManager.swift` — 添加去重逻辑
- Modify: `Sources/ClaudeHookServer.swift` — SessionStart 时标记已恢复
- Modify: `Sources/AppDelegate.swift` 或入口文件 — 启动时调用检查

- [ ] **Step 1: 在 RecoveryManager 中添加去重检查 — 不恢复已在运行的会话**

文件: `Sources/RecoveryManager.swift`

在 `recoverAllSessions()` 中，恢复前检查该 sessionID 是否已经有对应的 Claude Code 进程在运行：

```swift
/// 检查某个 session 是否已在运行
private func isSessionRunning(_ sessionID: String) -> Bool {
    // 通过 ps 检查是否有 claude 进程包含该 session ID
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-eo", "command="]

    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return output.contains(sessionID)
}
```

在 `recoverSession` 开头添加:
```swift
guard !isSessionRunning(snapshot.sessionID) else {
    appendLog("跳过（已在运行）: \(snapshot.sessionID.prefix(8))...")
    SessionSnapshotStore.shared.markRestored(sessionID: snapshot.sessionID)
    return
}
```

- [ ] **Step 2: 在 VibeFocus 启动时调用恢复检查**

找到 VibeFocus 的 app 入口文件（AppDelegate 或 @main struct），在 `applicationDidFinishLaunching` 中添加：

```swift
// 在 app 启动完成后检查是否有待恢复的会话
RecoveryManager.shared.checkAndRecoverOnStartup()
```

- [ ] **Step 3: 在 handleSessionStart 中标记已恢复的 snapshot**

文件: `Sources/ClaudeHookServer.swift` — handleSessionStart 中

当新会话启动时，如果 snapshot store 中有相同 cwd 的 pending snapshot，标记为 restored（避免重复打开）：

```swift
// 在 snapshot 创建之前，检查是否已有同 cwd 的 pending snapshot
// 如果是恢复的会话（sessionID 匹配 snapshot），标记为 restored
let existingSnapshot = SessionSnapshotStore.shared.snapshots.first(where: {
    $0.sessionID == payload.sessionID && $0.restoreStatus == .pending
})
if let existing = existingSnapshot {
    SessionSnapshotStore.shared.markRestored(sessionID: existing.sessionID)
}
```

- [ ] **Step 4: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 5: 提交**
Run: `git add Sources/RecoveryManager.swift Sources/ClaudeHookServer.swift && git commit -m "feat(recovery): add dedup logic — skip already-running sessions, auto-check on startup"`

---

### Task 7: Build, Deploy & E2E Test

**Depends on:** Task 1, Task 2, Task 3, Task 4, Task 5, Task 6
**Files:**
- No new files

- [ ] **Step 1: Release build**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 2: Deploy VibeFocus.app**
Run: `bash scripts/dev-build.sh`

- [ ] **Step 3: E2E 验证 — 会话快照持久化**

手动测试：
1. 启动 VibeFocus
2. 在副屏启动 Claude Code
3. 等待 SessionStart hook 触发
4. 检查 UserDefaults 中是否保存了 SessionSnapshot：
   `defaults read com.vibefocus.app vibefocus.sessionSnapshots.v1 | head -20`
5. 输入几个 prompt，确认 lastActiveAt 更新
6. 输入 `/exit` 退出 Claude Code
7. 确认 manuallyExited 被标记为 true

Expected:
  - Snapshot 正确保存到 UserDefaults
  - /exit 后 manuallyExited = true, restoreStatus = expired

- [ ] **Step 4: E2E 验证 — 会话恢复**

手动测试：
1. 启动 VibeCode，执行几个操作
2. 不输入 /exit，直接关闭 Terminal 窗口（模拟非正常退出）
3. 确认 snapshot 的 manuallyExited 仍为 false
4. 打开 VibeFocus 设置，确认"待恢复会话"显示 1 个
5. 点击"立即恢复"
6. 确认 Terminal 打开，CD 到项目目录，执行 `claude --resume <session_id>`

Expected:
  - Terminal 窗口打开
  - 自动 CD 到项目目录
  - claude --resume 恢复了之前的会话

- [ ] **Step 5: 提交**
Run: `git add -A && git commit -m "feat(recovery): deploy session recovery — E2E verified"`
