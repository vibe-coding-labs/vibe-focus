# Bug Fix: UserPromptSubmit 把窗口错误地从主屏恢复到副屏

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 UserPromptSubmit hook 在窗口已移到主屏后，仍将其恢复到副屏原始位置的 bug。用户按 Enter 提交 prompt 时，终端窗口突然从主屏跳回副屏。

**Architecture:** 两条 bug 路径：
1. **热键 toggle 路径**：用户 Ctrl+Q 把窗口移到主屏 → `moveWindowToMainScreen(sessionID: nil)` 创建 saved state（sessionID=nil）→ UserPromptSubmit 按 windowID+pid 匹配到这个 state → 恢复到副屏
2. **Stop hook 路径**：Claude 响应结束 → Stop → `moveWindowToMainScreen(sessionID: hookSessionID)` 创建 saved state → 用户按 Enter → UserPromptSubmit 匹配到这个 state → 恢复到副屏

修复策略：在 `handleUserPromptSubmit` 中增加"窗口已在主屏"防护检查——如果窗口当前在主屏上，跳过恢复。这与 `handleWindowMoveTrigger` 中已有的 `isWindowOnMainScreen` 检查逻辑一致。

**Tech Stack:** Swift 5.9, macOS 14+

**Risks:**
- 修改 `handleUserPromptSubmit` 可能导致合法的恢复被跳过 → 缓解：只在窗口已在主屏时跳过，副屏窗口仍正常恢复
- `isWindowOnMainScreen` 判断可能不准确（yabai 未运行时） → 缓解：使用 AX frame + NSScreen 双重判断

---

### Task 1: 在 handleUserPromptSubmit 中添加主屏防护检查

**Depends on:** None
**Files:**
- Modify: `Sources/ClaudeHookServer.swift:496`（matchedState 找到后、restore 执行前）

- [ ] **Step 1: 在 handleUserPromptSubmit 的 matchedState 分支中添加 isWindowOnMainScreen 检查**

文件: `Sources/ClaudeHookServer.swift:496-516`（在 `hydrateMemory` 之前插入检查）

在找到 matchedState 后、执行 hydrateMemory + restore 之前，检查窗口是否已在主屏。如果已在主屏，跳过恢复并清除 saved state。

```swift
            if let matchedState = WindowManager.shared.savedWindowStates.reversed().first(where: { state in
                state.windowID == targetWindowID
                    && state.pid == targetPID
                    && !WindowManager.shared.isSavedStateCorrupted(state)
            }) {
                // 防护：如果窗口已在主屏幕上，跳过恢复
                // 这防止 Stop/hotkey 把窗口移到主屏后，UserPromptSubmit 又把它移回副屏
                if WindowManager.shared.isWindowOnMainScreen(windowID: targetWindowID) {
                    handledRequestCount += 1
                    SessionWindowRegistry.shared.reactivate(sessionID: payload.sessionID)
                    SessionWindowRegistry.shared.setLastEventDescription(
                        "UserPromptSubmit 窗口已在主屏，跳过恢复"
                    )
                    log(
                        "[ClaudeHookServer] UserPromptSubmit window already on main screen, skipping restore",
                        fields: [
                            "sessionID": payload.sessionID,
                            "windowID": String(targetWindowID),
                            "app": binding.windowIdentity.appName ?? "unknown"
                        ]
                    )
                    return (
                        200,
                        ClaudeHookResponse(
                            ok: true, code: "already_on_main_screen",
                            message: "Window already on main screen, skipping restore",
                            sessionID: payload.sessionID, handled: false
                        )
                    )
                }

                // 从 saved state 恢复到内存
                WindowManager.shared.hydrateMemory(from: matchedState, window: nil)
```

- [ ] **Step 2: 验证构建**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/ClaudeHookServer.swift && git commit -m "fix(hook): prevent UserPromptSubmit from restoring window back to secondary screen

Root cause: When Stop hook or hotkey toggle moves window to main screen,
a savedWindowState is created with originalFrame pointing to secondary screen.
When UserPromptSubmit fires (user presses Enter), it matches this state
and restores the window back to the secondary screen, causing the window
to jump away from main screen unexpectedly.

Fix: Add isWindowOnMainScreen guard check in handleUserPromptSubmit.
If the window is already on the main screen, skip the restore entirely.
This mirrors the existing guard in handleWindowMoveTrigger (line 824).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"`
