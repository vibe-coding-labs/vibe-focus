# Bug Fix: Stop 事件误触发完成音效 — Claude Code 仍在执行时播放 Glass 音效

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 Claude Code 仍在执行时频繁播放 Glass 完成音效的问题，以及 Stop 事件在会话未真正结束时错误触发窗口操作的根本原因。

**Root Cause:** 两个独立的触发路径共同导致：

1. **Stop hook 中直接调用 `afplay Glass.aiff`**（settings.json 的 Stop hook 配置）— Claude Code 的 `Stop` 事件在每个 response turn 完成时都会触发（不只是 session 结束时）。当使用 Agent Teams / SubAgent 时，Claude 在处理每个 agent 返回结果后会触发 `Stop`，导致 `afplay` 在 agent 执行期间被反复调用。

2. **VibeFocus 的 handleStop 没有防抖机制**（ClaudeHookServer.swift:762-785）— 虽然 `claudeHookTriggerOnStop = 0`（当前禁用），但一旦用户重新启用，每次 Stop 都会立即处理，没有任何 idle 检测。

**Architecture:**
- 当前：`Claude Stop event → afplay Glass.aiff`（每次 Stop 都响）
- 修复后：`Claude Stop event → VibeFocus debounce (30s idle check) → SoundManager.playCompletionSound()`（仅在真正空闲时响）
- 移除 settings.json 中的 `afplay` hook，改由 VibeFocus 的 SoundManager 统一控制声音播放时机

**Tech Stack:** Swift 5.9, macOS 14+, NSSound, Claude Code Hooks

**Risks:**
- 移除 afplay hook 后，如果 VibeFocus 的 Stop trigger 未启用，则不会播放任何声音 → 缓解：用户在 VibeFocus 偏好设置中启用 Stop trigger + sound 即可恢复
- 30 秒 debounce 可能对快速交互场景太长 → 缓解：这是可配置参数，默认 30 秒

---

### Task 1: Remove Direct Sound from Stop Hook

**Depends on:** None
**Files:**
- Modify: `~/.claude/settings.json` — 移除 Stop hook 中的 `afplay Glass.aiff`

- [ ] **Step 1: 从 Stop hook 配置中移除 afplay 命令 — 声音改由 VibeFocus SoundManager 控制**

通过 update-config skill 修改 settings.json，移除 Stop 事件中的 `afplay` hook。

修改前（settings.json hooks.Stop 数组有 2 项）：
```json
"Stop": [
    {
        "hooks": [{"command": "bash ~/.vibefocus/hook-forwarder.sh", "timeout": 10, "type": "command"}],
        "matcher": ""
    },
    {
        "hooks": [{"command": "afplay /System/Library/Sounds/Glass.aiff 2>/dev/null || tput bel", "timeout": 5, "type": "command"}],
        "matcher": ""
    }
]
```

修改后（只保留 VibeFocus hook-forwarder）：
```json
"Stop": [
    {
        "hooks": [{"command": "bash ~/.vibefocus/hook-forwarder.sh", "timeout": 10, "type": "command"}],
        "matcher": ""
    }
]
```

Run: `python3 << 'PYEOF'
import json

with open('/Users/cc11001100/.claude/settings.json', 'r') as f:
    data = json.load(f)

hooks = data.get('hooks', {})
if 'Stop' in hooks:
    # Remove afplay hooks, keep only hook-forwarder
    original_count = len(hooks['Stop'])
    hooks['Stop'] = [
        h for h in hooks['Stop']
        if any(
            hook.get('command', '').find('hook-forwarder') >= 0
            for hook in h.get('hooks', [])
        )
    ]
    removed = original_count - len(hooks['Stop'])
    print(f"Removed {removed} afplay hook(s) from Stop event")

with open('/Users/cc11001100/.claude/settings.json', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
print("settings.json updated")
PYEOF`
Expected:
  - Output contains: "Removed 1 afplay hook(s) from Stop event"
  - Output contains: "settings.json updated"

- [ ] **Step 2: 验证 Stop hook 配置正确**
Run: `python3 -c "
import json
with open('/Users/cc11001100/.claude/settings.json') as f:
    data = json.load(f)
stop_hooks = data.get('hooks', {}).get('Stop', [])
print(f'Stop hooks count: {len(stop_hooks)}')
for h in stop_hooks:
    for hook in h.get('hooks', []):
        print(f'  - {hook.get(\"command\", \"\")[:100]}')
"`
Expected:
  - Output contains: "Stop hooks count: 1"
  - Output contains: "hook-forwarder"
  - Output does NOT contain: "afplay"

- [ ] **Step 3: 提交配置变更说明**（settings.json 不在 git 中，此 step 记录变更）
Note: `~/.claude/settings.json` 是用户配置文件，不在 VibeFocus git 仓库中。变更已在 Step 1 直接生效。

---

### Task 2: Add Debounce to VibeFocus Stop Handler

**Depends on:** None
**Files:**
- Modify: `Sources/ClaudeHookServer.swift:762-785`（handleStop 函数）
- Modify: `Sources/ClaudeHookModels.swift` — 添加 lastActivityTimestamp 跟踪

- [ ] **Step 1: 在 ClaudeHookServer 中添加会话活动追踪 — 记录每个 session 最后活跃时间**

文件: `Sources/ClaudeHookServer.swift`

在类属性区域添加会话活动追踪字典：

```swift
// 在 ClaudeHookServer 类中添加（约 line 15-20 附近，与其他 @Published 属性一起）

/// 记录每个 session 最后收到 UserPromptSubmit 的时间
/// 用于 Stop 事件防抖：如果 session 最近活跃，Stop 可能是中间态而非真正结束
private var lastActivityBySession: [String: Date] = [:]

/// Stop 事件防抖阈值：只有超过此时间无活动的 Stop 才被视为真正的会话结束
private let stopDebounceInterval: TimeInterval = 30.0
```

在 handleUserPromptSubmit 函数开头添加活动时间记录：

```swift
// 在 handleUserPromptSubmit 函数体的最开头添加（约 line 449 之后）
// 记录此 session 的活动时间，用于 Stop 防抖
lastActivityBySession[payload.sessionID] = Date()
```

- [ ] **Step 2: 修改 handleStop — 添加防抖检查，跳过中间态 Stop 事件**

文件: `Sources/ClaudeHookServer.swift:762-785`（handleStop 函数）

```swift
// 替换 handleStop 函数的完整实现
// 文件: ClaudeHookServer.swift:762-785

private func handleStop(
    payload: ClaudeHookPayload
) -> (statusCode: Int, response: ClaudeHookResponse) {
    // 防抖检查：如果此 session 在最近 debounceInterval 内有 UserPromptSubmit，
    // 说明 Stop 是中间态（Claude 在处理中间步骤时停顿），不是真正的会话结束
    if let lastActivity = lastActivityBySession[payload.sessionID] {
        let elapsed = Date().timeIntervalSince(lastActivity)
        if elapsed < stopDebounceInterval {
            log(
                "[ClaudeHookServer] Stop debounced — session was active \(String(format: "%.1f", elapsed))s ago (threshold: \(String(format: "%.0f", stopDebounceInterval))s)",
                fields: [
                    "sessionID": payload.sessionID,
                    "elapsedSinceActivity": String(format: "%.1f", elapsed),
                    "debounceThreshold": String(format: "%.0f", stopDebounceInterval)
                ]
            )
            SessionWindowRegistry.shared.touch(
                sessionID: payload.sessionID,
                message: "Stop 收到（防抖中：会话仍活跃）"
            )
            handledRequestCount += 1
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "stop_debounced",
                    message: "Stop debounced — session still active",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }
    }

    guard ClaudeHookPreferences.triggerOnStop else {
        SessionWindowRegistry.shared.touch(
            sessionID: payload.sessionID,
            message: "Stop 收到（Stop 触发已关闭）"
        )
        handledRequestCount += 1
        log(
            "[ClaudeHookServer] Stop received but trigger disabled",
            fields: ["sessionID": payload.sessionID]
        )
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "stop_trigger_disabled",
                message: "Stop received, trigger disabled",
                sessionID: payload.sessionID, handled: false
            )
        )
    }

    // 防抖通过 + trigger 已启用 → 清理活动记录
    lastActivityBySession.removeValue(forKey: payload.sessionID)

    return handleWindowMoveTrigger(payload: payload, triggerName: "Stop")
}
```

- [ ] **Step 3: 在 handleSessionStart 中也记录活动时间 — 确保新会话的 Stop 不会被误判**

在 handleSessionStart 函数中，binding 创建成功后添加：

```swift
// 在 handleSessionStart 函数中，binding 创建/更新后添加
// 文件: ClaudeHookServer.swift handleSessionStart 函数内

// 记录 session 活动时间
lastActivityBySession[payload.sessionID] = Date()
```

- [ ] **Step 4: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 5: 提交**
Run: `git add Sources/ClaudeHookServer.swift && git commit -m "fix(hook): add 30s debounce to Stop handler — skip intermediate Stop events during active sessions"`

---

### Task 3: Build, Deploy & Verify

**Depends on:** Task 1, Task 2
**Files:**
- No new source files

- [ ] **Step 1: Release build**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 2: Deploy VibeFocus.app**

遵循 deploy workflow（完整 app bundle + code signing）：
1. 从 release build 产物创建 app bundle
2. Code sign
3. 复制到 /Applications
4. 重启 VibeFocus

- [ ] **Step 3: E2E 验证 — SubAgent 场景（bug 复现场景）**

手动测试：
1. 确认 settings.json 中 Stop hook 已移除 afplay
2. 启动 VibeFocus
3. 启动 Claude Code，要求使用 Agent tool 执行多步任务
4. 观察：在 Agent 执行期间，不应播放任何完成音效
5. 等待 Claude 完成最终响应（真正的 Stop）
6. 验证：只在真正完成时播放音效（如果 Stop trigger 已启用）

Expected:
  - Agent 执行期间无 Glass 音效
  - 只在 Claude 完全停止后播放一次音效（或根据 VibeFocus 偏好设置不播放）

- [ ] **Step 4: 提交**
Run: `git add -A && git commit -m "fix(hook): deploy Stop debounce fix — no more spurious completion sounds during agent execution"`
