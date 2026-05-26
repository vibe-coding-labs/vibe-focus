# Watchdog & Restore Strategy Optimization Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 消除 RestoreWatchdog 的重试风暴和频繁 auto-restore 导致的窗口抖动/焦点丢失

**Architecture:** Watchdog 从 200ms 高频轮询改为 800ms 慢速轮询，减少每次 restore 产生的 space_move 数量（从 5-6 次降到 2-3 次）。Auto-restore 增加 30 秒冷却期，防止 toggle→restore→toggle→restore 的快速循环。

**Tech Stack:** Swift 5, macOS AppKit, yabai tiling manager

**Scope:** Small
**Risk:** Low
**Risks:**
- Watchdog 放宽后 yabai tiling 可能覆盖 restore 结果 → 缓解：800ms 仍在 yabai 响应时间内，且 maxCorrections=3 足够覆盖 2-3 轮修正
- Auto-restore 冷却可能导致延迟恢复 → 缓解：冷却仅针对同一窗口，用户按 Ctrl+Q 的 toggle 不受影响

**Autonomy Level:** Full

---

### Task 1: RestoreWatchdog 策略优化 — 降低轮询频率和修正次数

**Depends on:** None
**Files:**
- Modify: `Sources/Toggle/RestoreWatchdog.swift:26-29`（参数常量）
- Modify: `Sources/Toggle/RestoreWatchdog.swift:52-53`（Timer 调度增加初始延迟）

- [ ] **Step 1: 修改 Watchdog 参数 — 降低轮询频率和修正上限**

文件: `Sources/Toggle/RestoreWatchdog.swift:26-29`

```swift
    private let tickIntervalMs: UInt64 = 800
    private let maxStableTicks = 3
    private let maxTotalTicks = 8
    private let maxCorrections = 3
```

变更说明：
- `tickIntervalMs`: 200 → 800 — 给 yabai tiling 引擎更多响应时间，避免在同一轮 tiling 内重复检测
- `maxStableTicks`: 5 → 3 — 稳定确认从 5 次降到 3 次（2.4 秒 vs 1 秒），够用
- `maxTotalTicks`: 15 → 8 — 总运行时间从 3 秒延长到 6.4 秒，但操作更少
- `maxCorrections`: 5 → 3 — 最多 3 次修正（原 5 次太多，审计日志显示通常 5 次全用完说明在无效循环）

- [ ] **Step 2: 增加 Watchdog 初始延迟 — 避免 yabai 异步操作期间的误判**

文件: `Sources/Toggle/RestoreWatchdog.swift:53`（替换 timer 调度行）

在 `startMonitoring` 方法中，替换 timer 调度：

```swift
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        t.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(Int(tickIntervalMs)))
```

变更说明：初始延迟从 200ms（tickIntervalMs）改为固定 500ms，给 restore 操作完成后的 yabai 异步处理留出时间。

- [ ] **Step 3: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 4: 质量门禁**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | grep -c "error:"`
Expected:
  - Output: "0"
  - 无未使用的 import 或 dead code

- [ ] **Step 5: 提交**
Run: `git add Sources/Toggle/RestoreWatchdog.swift && git commit -m "$(cat <<'EOF'
opt(watchdog): reduce polling frequency to prevent space_move retry storms

RestoreWatchdog now polls at 800ms (was 200ms), max 3 corrections (was 5),
with 500ms initial delay. This reduces visible space jitter from 5-6
space_move commands per restore to 2-3, while still covering yabai tiling
interference within the 6.4s monitoring window.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

### Task 2: Auto-restore 冷却机制 — 防止同一窗口快速重复 restore

**Depends on:** None
**Files:**
- Modify: `Sources/Hook/HookEventHandler.swift`（增加冷却期逻辑）
- Modify: `Sources/Window/WindowManager+Toggle.swift`（toggle 时清除冷却）

- [ ] **Step 1: 添加冷却状态存储 — 在 HookEventHandler 中追踪最近 auto-restore 时间**

文件: `Sources/Hook/HookEventHandler.swift`

在类属性区域（`lastActivityBySession` 附近）添加：

```swift
    /// auto-restore 冷却期：同一窗口在 N 秒内不重复 restore
    private static let autoRestoreCooldownSeconds: TimeInterval = 30
    private var lastAutoRestoreByWindowID: [UInt32: Date] = [:]
```

- [ ] **Step 2: 在 handleUserPromptSubmit 中添加冷却检查**

文件: `Sources/Hook/HookEventHandler.swift`（在 `validateRestoreEligibility` 调用之前，即 "2. 验证是否应该 restore" 之前插入）

在 `guard let identity = resolveWindowIdentity(...)` 之后，`guard let validation = validateRestoreEligibility(...)` 之前，插入冷却检查：

```swift
        // 2.5 冷却检查：同一窗口在冷却期内不重复 auto-restore
        if let lastRestore = lastAutoRestoreByWindowID[identity.windowID],
           Date().timeIntervalSince(lastRestore) < Self.autoRestoreCooldownSeconds {
            let remaining = Int(Self.autoRestoreCooldownSeconds - Date().timeIntervalSince(lastRestore))
            log(
                "[HookEventHandler] UserPromptSubmit: auto-restore cooldown active, skipping",
                level: .info,
                fields: [
                    "traceID": traceID,
                    "windowID": String(identity.windowID),
                    "cooldownRemaining": String(remaining) + "s"
                ]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "cooldown_active",
                    message: "Auto-restore cooldown active (\(remaining)s remaining)",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }
```

- [ ] **Step 3: 在 executeRestore 成功后记录冷却时间**

文件: `Sources/Hook/HookEventHandler.swift`

找到 `executeRestore` 方法的调用处（在 `handleUserPromptSubmit` 中 `let success = executeRestore(...)` 之后），在 return 之前插入：

```swift
        if success {
            lastAutoRestoreByWindowID[identity.windowID] = Date()
        }
```

- [ ] **Step 4: 在 toggle_move_to_main 时清除冷却 — 新的 toggle 周期开始**

文件: `Sources/Window/WindowManager+Toggle.swift`

在 `moveToMainScreen` 方法中，在 `let moved = moveWindowToMainScreen(...)` 调用之前插入冷却清除：

```swift
        // 清除 auto-restore 冷却 — 用户主动 toggle 表示新的操作周期
        HookEventHandler.shared.clearAutoRestoreCooldown(windowID: identity.windowID)
```

同步在 HookEventHandler 中添加公开方法：

文件: `Sources/Hook/HookEventHandler.swift`（在类末尾添加）

```swift
    func clearAutoRestoreCooldown(windowID: UInt32) {
        lastAutoRestoreByWindowID.removeValue(forKey: windowID)
    }
```

- [ ] **Step 5: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 6: 质量门禁**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | grep -c "error:"`
Expected:
  - Output: "0"
  - 无遗留 debug 语句

- [ ] **Step 7: 提交**
Run: `git add Sources/Hook/HookEventHandler.swift Sources/Window/WindowManager+Toggle.swift && git commit -m "$(cat <<'EOF'
opt(restore): add 30s cooldown for auto-restore to prevent rapid toggle cycles

UserPromptSubmit auto-restore now skips if the same window was restored
within the last 30 seconds. Cooldown is cleared when user manually toggles
the window back to main screen, starting a new restore cycle. This eliminates
the rapid toggle→restore→toggle→watchdog loop that causes visible jitter.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`
