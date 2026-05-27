# Bug Fix: Stop 事件 30s 防抖导致窗口无法移到主屏

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Symptom:** 部分 SSH 远程 session 在 Claude 完成后窗口不自动移到主屏，后续 UserPromptSubmit 永远 `restore_skipped_window_not_on_main`

**Root Cause:** `handleStop` 的 30s 防抖机制（HookEventHandler.swift:581-604）。UserPromptSubmit 设置 `lastActivityBySession` → Claude 快速完成 → Stop 在 30s 内触发 → 被防抖跳过 → 窗口永远不移动到主屏 → 没有 ToggleRecord → 后续 restore 全部失败

**Impact:** 所有 Claude 在 30s 内完成的远程 session 都无法触发窗口移动

**Scope:** Tiny
**Risk:** Low — `handleWindowMoveTrigger` 已有 `alreadyOnMainScreen`、`alreadyCompleted` 防护

---

### Task 1: 移除 handleStop 的 30s 防抖 — 让 Stop 事件始终执行窗口移动检查

**Depends on:** None
**Files:**
- Modify: `Sources/Hook/HookEventHandler.swift:576-628`（handleStop 方法）

- [ ] **Step 1: 移除 handleStop 的防抖逻辑 — 删除 lastActivityBySession 检查**

文件: `Sources/Hook/HookEventHandler.swift:576-628`（替换整个 handleStop 方法）

```swift
    // MARK: - Stop

    func handleStop(
        payload: ClaudeHookPayload
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        guard ClaudeHookPreferences.triggerOnStop else {
            SessionWindowRegistry.shared.touch(
                sessionID: payload.sessionID,
                message: "Stop 收到（Stop 触发已关闭）"
            )
            log(
                "[HookEventHandler] Stop received but trigger disabled",
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

        lastActivityBySession.removeValue(forKey: payload.sessionID)
        return handleWindowMoveTrigger(payload: payload, triggerName: "Stop")
    }
```

- [ ] **Step 2: 清理不再使用的 lastActivityBySession 属性和 stopDebounceInterval**

文件: `Sources/Hook/HookEventHandler.swift:8-9`（删除这两行）

删除:
```swift
    private var lastActivityBySession: [String: Date] = [:]
    private let stopDebounceInterval: TimeInterval = 30.0
```

同时从 `handleUserPromptSubmit` 中删除对 `lastActivityBySession` 的写入:

文件: `Sources/Hook/HookEventHandler.swift:191`（删除这一行）

删除:
```swift
        lastActivityBySession[payload.sessionID] = Date()
```

- [ ] **Step 3: 清理不再使用的 shouldDebounceStop 纯函数**

文件: `Sources/Hook/HookEventHandler.swift:16-22`（删除整个 shouldDebounceStop 方法）

删除:
```swift
    /// Pure: should a Stop event be debounced because the session was recently active?
    static func shouldDebounceStop(elapsed: TimeInterval, threshold: TimeInterval = 30.0) -> Bool {
        elapsed < threshold
    }
```

- [ ] **Step 4: 编译检查**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:" or "warning:" related to HookEventHandler

- [ ] **Step 5: 部署并验证**
Run: `bash scripts/dev-build.sh 2>&1 | tail -3`
Expected:
  - Contains "构建成功" or similar success indicator

然后验证 Stop 事件不再被防抖:
Run: `kill $(pgrep -f "VibeFocus.app/Contents/MacOS/VibeFocus") 2>/dev/null; sleep 1; open /Applications/VibeFocus.app; sleep 2 && curl -s -X POST "http://127.0.0.1:39277/claude/hook?token=1d9df73f1b8c43aeb465a937c0c51981" -H "Content-Type: application/json" -H "X-VibeFocus-Token: 1d9df73f1b8c43aeb465a937c0c51981" -d '{"hook_event_name":"UserPromptSubmit","session_id":"debounce-test","cwd":"/home/test","terminal_ctx":{"machine_label":"local-server-002"}}' && sleep 1 && curl -s -X POST "http://127.0.0.1:39277/claude/hook?token=1d9df73f1b8c43aeb465a937c0c51981" -H "Content-Type: application/json" -H "X-VibeFocus-Token: 1d9df73f1b8c43aeb465a937c0c51981" -d '{"hook_event_name":"Stop","session_id":"debounce-test","cwd":"/home/test","terminal_ctx":{"machine_label":"local-server-002"}}' | python3 -m json.tool`
Expected:
  - Stop response code is NOT "stop_debounced"
  - Stop response code is one of: "window_focused", "already_on_main_screen", "no_binding_skip"

- [ ] **Step 6: 提交**
Run: `git add Sources/Hook/HookEventHandler.swift && git commit -m "fix(hook): remove 30s Stop debounce that prevented window from moving to main screen"`
