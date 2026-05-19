# Bug Fix: Hook auto-restore 与手动热键冲突 + 缺少 PID fallback

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 Hook 触发的 auto-restore 与手动热键 toggle 之间的竞态条件，以及 Hook 路径缺少 PID fallback 导致 restore 失败

**Architecture:** Hook 路径（HookEventHandler → ToggleEngine.restore）不检查 `HotKeyManager.isToggleInFlight`，也不传 `fallbackPID`。修复两处：(1) 在 Hook 调用 restore 前检查 isToggleInFlight，(2) 传递 PID 给 ToggleEngine.restore

**Tech Stack:** Swift 5.9, macOS Accessibility API

**Scope:** Tiny
**Risk:** Low — 只添加防护检查和一个参数

**Risks:**
- 修改 HookEventHandler 可能影响 auto-restore 的触发频率 → 缓解：isToggleInFlight 只在 toggle 执行期间为 true（< 1s），正常 prompt submit 不受影响

**Autonomy Level:** Full

---

## Bug Summary

| # | Symptom | Root Cause | Impact | File |
|---|---------|-----------|--------|------|
| 1 | 窗口在手动热键和 hook auto-restore 同时触发时来回跳动 | HookEventHandler 不检查 `HotKeyManager.isToggleInFlight`，与手动热键冲突 | 窗口最终位置不确定，用户体验混乱 | `HookEventHandler.swift:326-367` |
| 2 | Hook auto-restore 在 CGWindowNumber 变化后找不到 toggle record | `engine.restore()` 调用不传 `fallbackPID`，而之前修复的 PID fallback 需要这个参数 | iTerm2 等应用的窗口无法通过 hook 自动 restore | `HookEventHandler.swift:363-367` |

---

### Task 1: 添加 isToggleInFlight 检查 + 传递 fallbackPID 给 Hook auto-restore

**Depends on:** None
**Files:**
- Modify: `Sources/Hook/HookEventHandler.swift:326-367`

**Symptom:** 用户按热键的同时 Claude 提交了一个 prompt，两个 restore 操作同时执行，窗口被来回移动。

**Root Cause:** `HookEventHandler.handleUserPromptSubmit()` 在调用 `engine.restore()` 前不检查 `HotKeyManager.shared.isToggleInFlight`。热键路径有这个检查（`HotKeyManager+Monitors.swift:58`），但 hook 路径没有。

- [ ] **Step 1: 在 Hook auto-restore 调用前添加 isToggleInFlight 防护**

文件: `Sources/Hook/HookEventHandler.swift`（在 `guard isOnMain else {` 之前，约第 326 行）

找到这段代码：
```swift
        guard isOnMain else {
```

在它前面插入：
```swift
        // 防止与手动热键 toggle 冲突 — 如果用户正在按热键，跳过 auto-restore
        if HotKeyManager.shared.isToggleInFlight {
            log(
                "[HookEventHandler] UserPromptSubmit skipped: toggle already in flight",
                level: .info,
                fields: [
                    "traceID": traceID,
                    "sessionID": payload.sessionID,
                    "windowID": String(identity.windowID)
                ]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "toggle_in_flight",
                    message: "Toggle in flight, skipping auto-restore",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }
```

- [ ] **Step 2: 给 engine.restore 调用添加 fallbackPID 参数**

文件: `Sources/Hook/HookEventHandler.swift`（约第 363-367 行）

找到这段代码：
```swift
                let success = engine.restore(
                    windowID: identity.windowID,
                    triggerSource: "user_prompt_submit",
                    traceID: traceID
                )
```

替换为：
```swift
                let success = engine.restore(
                    windowID: identity.windowID,
                    fallbackPID: identity.pid,
                    triggerSource: "user_prompt_submit",
                    traceID: traceID
                )
```

- [ ] **Step 3: 验证编译通过**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/Hook/HookEventHandler.swift && git commit -m "$(cat <<'EOF'
fix(hook): add isToggleInFlight guard and fallbackPID to auto-restore

Two bugs in the hook-driven auto-restore path:

1. HookEventHandler did not check HotKeyManager.isToggleInFlight before
   calling ToggleEngine.restore(). If a hotkey toggle was in progress,
   both restore operations would execute simultaneously, causing the
   window to bounce between screens.

2. engine.restore() was called without fallbackPID. When CGWindowNumber
   changes after cross-display moves (iTerm2), the windowID lookup fails
   and the PID fallback cannot activate without this parameter.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`
