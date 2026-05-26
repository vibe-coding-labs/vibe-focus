# Bug Fix: 远程 SSH 窗口 UserPromptSubmit 无法自动回退

**Symptom:** 多个 SSH 到 local-server-002 的 iTerm2 窗口，提交 Claude 提示词后窗口不会自动移到主屏/还原

**Root Cause:** `handleUserPromptSubmit` 的 `validateRestoreEligibility` 要求窗口在主屏 + 有 ToggleRecord（HookEventHandler.swift:472-497）。这两个条件只有 Stop 事件成功移动窗口后才满足。远程 session 因 binding 频繁丢失，Stop 事件无法移动窗口，导致 UserPromptSubmit 永远 skip。

**Impact:** 所有远程 SSH session 的自动 restore 完全失效

**Scope:** Small
**Risk:** Medium — 修改 restore 验证逻辑，可能影响本地 session

**Risks:**
- Task 1 修改了 handleUserPromptSubmit 的核心流程 → 缓解：仅当 validateRestoreEligibility 返回 nil 且窗口不在主屏时才 fallback
- Task 2 修改 resolveWindowIdentity 的 self-heal → 缓解：仅影响远程 session，本地 session 不触发

---

### Task 1: UserPromptSubmit 添加 toggle fallback — 窗口不在主屏时主动移动

**Depends on:** None
**Files:**
- Modify: `Sources/Hook/HookEventHandler.swift:263-289`（handleUserPromptSubmit 的 restore 跳过逻辑）

当 `validateRestoreEligibility` 返回 nil 且窗口不在主屏时，不要直接 skip，而是调用 `moveWindowToMainScreenAndRespond` 将窗口移到主屏。这打破了循环依赖：即使 Stop 事件失败，UserPromptSubmit 也能将窗口移回来。

- [ ] **Step 1: 修改 handleUserPromptSubmit 的 fallback 逻辑 — 窗口不在主屏时主动 toggle**

文件: `Sources/Hook/HookEventHandler.swift:263-289`

替换整个 `guard let validation = validateRestoreEligibility(...)` 块（从 "// 3. 验证是否应该 restore" 到 return）：

```swift
        // 3. 验证是否应该 restore
        guard let validation = validateRestoreEligibility(identity: identity, traceID: traceID) else {
            let onMainScreen = WindowManager.shared.isWindowOnMainScreen(windowID: identity.windowID)

            if onMainScreen {
                // 窗口在主屏但无 ToggleRecord → 用户可能手动还原了，不操作
                log(
                    "[HookEventHandler] UserPromptSubmit: on main screen but no toggle record, skipping",
                    fields: [
                        "traceID": traceID,
                        "windowID": String(identity.windowID),
                        "app": identity.appName ?? "unknown",
                        "sessionID": payload.sessionID,
                        "reason": "no_toggle_record"
                    ]
                )
                return (
                    200,
                    ClaudeHookResponse(
                        ok: true, code: "restore_skipped_no_toggle_record",
                        message: "Window on main screen but no toggle record",
                        sessionID: payload.sessionID, handled: false
                    )
                )
            }

            // 窗口不在主屏 → 主动移到主屏（toggle fallback）
            log(
                "[HookEventHandler] UserPromptSubmit: window not on main screen, executing toggle fallback",
                level: .info,
                fields: [
                    "traceID": traceID,
                    "windowID": String(identity.windowID),
                    "app": identity.appName ?? "unknown",
                    "sessionID": payload.sessionID
                ]
            )
            let moved = WindowManager.shared.moveWindowToMainScreen(
                identity: identity,
                reason: .claudeSessionEnd,
                sessionID: payload.sessionID
            )
            if moved {
                lastAutoRestoreByWindowID[identity.windowID] = Date()
                Task { @MainActor in
                    SoundManager.shared.playCompletionSound()
                    DockBadgeManager.shared.showBadge(
                        targetBundleID: identity.bundleIdentifier,
                        targetAppName: identity.appName
                    )
                }
            }
            return (
                200,
                ClaudeHookResponse(
                    ok: true,
                    code: moved ? "toggle_fallback" : "toggle_fallback_failed",
                    message: moved ? "Window moved to main screen via toggle fallback" : "Toggle fallback failed",
                    sessionID: payload.sessionID,
                    handled: moved
                )
            )
        }
```

- [ ] **Step 2: 质量门禁 — 编译检查**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 3: 验证远程 session end-to-end**
Run: `bash scripts/dev-build.sh 2>&1 | tail -3`
Expected:
  - Contains "构建成功"

然后从远端触发测试：
Run: `ssh local-server-002 'curl -s -X POST "http://192.168.1.8:39277/claude/hook?token=1d9df73f1b8c43aeb465a937c0c51981" -H "Content-Type: application/json" -H "X-VibeFocus-Token: 1d9df73f1b8c43aeb465a937c0c51981" -d "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"toggle-fallback-test\",\"cwd\":\"/home/cc11001100/test\",\"terminal_ctx\":{\"machine_label\":\"local-server-002\"}}"'`
Expected:
  - Contains "toggle_fallback" or "window_focused" (NOT "no_binding_skip" or "restore_skipped")

- [ ] **Step 4: 提交**
Run: `git add Sources/Hook/HookEventHandler.swift && git commit -m "fix(hook): add toggle fallback for UserPromptSubmit when window not on main screen"`
