# Refactor: Hook auto-restore 路径补全 post-restore cleanup

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 在 Hook 触发的 auto-restore 成功后，补全 toggle record 清除逻辑，与热键路径的 `WindowManager.restore()` 行为对齐

**Architecture:** Hook 路径通过 session binding 定位窗口（不同于热键路径通过 focused window），因此不能直接调用 `WindowManager.restore()`。修复方式：在 Hook 的 `engine.restore()` 成功后，添加与 `WindowManager.restore()` 相同的 record cleanup 步骤。

**Tech Stack:** Swift 5.9

**Scope:** Tiny
**Risk:** Low — 添加清理逻辑，不改变 restore 本身的行为

**Risks:**
- Hook 路径使用 `identity.pid` 做 fallback，但 cleanup 需要用 record 中存储的 windowID → 缓解：复用 `WindowManager.restore()` 的同样模式（先 load record，用 record.windowID clear）

**Autonomy Level:** Full

---

### Task 1: 在 Hook restore 成功后添加 toggle record 清除

**Depends on:** None
**Files:**
- Modify: `Sources/Hook/HookEventHandler.swift:411-421`

**Symptom:** Hook 触发 restore 后 toggle record 不被清除。下次按热键时 `shouldRestoreCurrentWindow()` 找到残留 record，认为需要 restore（窗口已在原位），导致 toggle 行为异常：本应 move to main 的操作变成了无意义的 restore。

**Root Cause:** `HookEventHandler.handleUserPromptSubmit()` 在 `engine.restore()` 成功后直接 return，缺少 `engine.clear()` 调用。对比热键路径 `WindowManager.restore():115` 会在 restore 成功后 `engine.clear(windowID: record.windowID)`。

- [ ] **Step 1: 在 Hook restore 成功分支添加 record cleanup**

文件: `Sources/Hook/HookEventHandler.swift:411-421`（替换 `if success {` 区块）

```swift
                if success {
                    // 清除 toggle record — 与 WindowManager.restore() 对齐
                    // 必须用 record 中存储的 windowID（可能与 identity.windowID 不同，CGWindowNumber 变化后）
                    var record = engine.load(windowID: identity.windowID)
                    if record == nil {
                        record = engine.loadByPID(pid: identity.pid)
                    }
                    if let record {
                        engine.clear(windowID: record.windowID)
                        log(
                            "[HookEventHandler] UserPromptSubmit cleared toggle record",
                            fields: [
                                "traceID": traceID,
                                "windowID": String(record.windowID),
                                "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y)) \(Int(record.origFrame.width))x\(Int(record.origFrame.height))",
                                "sourceSpace": String(record.sourceSpace)
                            ]
                        )
                    }
                    return (
                        200,
                        ClaudeHookResponse(
                            ok: true,
                            code: "restored",
                            message: "Window restored to original position",
                            sessionID: payload.sessionID,
                            handled: true
                        )
                    )
```

- [ ] **Step 2: 验证编译通过**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/Hook/HookEventHandler.swift && git commit -m "$(cat <<'EOF'
fix(hook): clear toggle record after hook-triggered auto-restore

HookEventHandler called ToggleEngine.restore() directly but never
cleared the toggle record afterwards. This caused stale records to
persist, making the next hotkey toggle incorrectly attempt restore
instead of move-to-main.

Now after successful restore, the hook path clears the toggle record
using the same pattern as WindowManager.restore(): load the record
(with PID fallback), then clear using the stored windowID.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`
