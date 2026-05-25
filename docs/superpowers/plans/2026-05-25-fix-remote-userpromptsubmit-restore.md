# Bug Fix: 远程 Session UserPromptSubmit 窗口不回退

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Symptom:** 远程 SSH 机器（如 local-server-002）上 Claude Code 提交提示词后，macOS 端的 iTerm 窗口不会自动移回主屏
**Root Cause:** `HookEventHandler.handleUserPromptSubmit` L229 调用 `validateRestoreEligibility`，该函数 L377 要求 `ToggleRecord` 存在。远程 session 通过 LAN remote binding 映射窗口，窗口从未被 Ctrl+Q toggle 过，因此没有 ToggleRecord → 返回 nil → response `no_action_needed`
**Impact:** 所有远程（LAN）session 的 UserPromptSubmit auto-restore 不工作。本地 session 通过 Ctrl+Q toggle 产生 ToggleRecord，不受影响
**Scope:** Small
**Risk:** Medium — 修改共享的 UserPromptSubmit 处理逻辑，需确保本地 session 行为不变

**Architecture:** 当 `validateRestoreEligibility` 返回 nil（无 ToggleRecord）时，检查窗口是否在副屏。如果是，fallback 到 `moveWindowToMainScreen`（复用 SessionEnd 使用的窗口移动逻辑）。数据流：UserPromptSubmit → resolveWindowIdentity → validateRestoreEligibility → (nil) → isWindowOnMainScreen? → (no) → moveWindowToMainScreen

**Tech Stack:** Swift 5.9+, swift-testing framework

**Risks:**
- 修改 `handleUserPromptSubmit` 可能影响本地 session → 缓解：fallback 仅在 `validateRestoreEligibility` 返回 nil 时触发，本地 session 有 ToggleRecord 不会走到 fallback
- `isWindowOnMainScreen` 对已丢失的窗口可能返回错误值 → 缓解：`resolveWindowIdentity` 已经验证了窗口存在

**Autonomy Level:** Full

---

### Task 1: 修改 handleUserPromptSubmit 添加无 ToggleRecord 的 fallback

**Depends on:** None
**Files:**
- Modify: `Sources/Hook/HookEventHandler.swift:228-238`

- [ ] **Step 1: 修改 handleUserPromptSubmit 的 validateRestoreEligibility 失败分支 — 添加 moveWindowToMainScreen fallback**

文件: `Sources/Hook/HookEventHandler.swift:228-238`（替换 `validateRestoreEligibility` 返回 nil 的 guard 分支）

```swift
        // 3. 验证是否应该 restore
        guard let validation = validateRestoreEligibility(identity: identity, traceID: traceID) else {
            // 无 ToggleRecord（如远程 session 从未被 toggle 过）→ fallback: 直接移到主屏
            if !WindowManager.shared.isWindowOnMainScreen(windowID: identity.windowID) {
                log(
                    "[HookEventHandler] UserPromptSubmit: no toggle record, falling back to moveWindowToMainScreen",
                    fields: [
                        "traceID": traceID,
                        "sessionID": payload.sessionID,
                        "windowID": String(identity.windowID)
                    ]
                )
                let moved = WindowManager.shared.moveWindowToMainScreen(
                    identity: identity,
                    reason: .claudeSessionEnd,
                    sessionID: payload.sessionID
                )
                if moved {
                    lastAutoRestoreByWindowID[identity.windowID] = Date()
                }
                return (
                    200,
                    ClaudeHookResponse(
                        ok: true,
                        code: moved ? "window_moved" : "window_move_failed",
                        message: moved ? "Window moved to main screen (no toggle record)" : "Move to main screen failed",
                        sessionID: payload.sessionID,
                        handled: moved
                    )
                )
            }
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "no_action_needed",
                    message: "Window not eligible for restore",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }
```

- [ ] **Step 2: 验证编译通过**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 3: 运行全量测试**
Run: `swift test 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "passed"

- [ ] **Step 4: 质量门禁**
Run: `swift build 2>&1 | grep -c "error:" && swift test 2>&1 | grep -c "failed"`
Expected:
  - Exit code: 0
  - Output: `0` (zero errors) then `0` (zero failures)

- [ ] **Step 5: 提交**
Run: `git add Sources/Hook/HookEventHandler.swift && git commit -m "fix(hook): UserPromptSubmit auto-restore for remote sessions without ToggleRecord"`

---

### Task 2: 补充 decideRestoreEligibility 测试 — noRecord fallback 决策

**Depends on:** Task 1
**Files:**
- Modify: `Tests/XCTest/IntegrationMockTests.swift:153-162`（在 noRecord 测试之后追加）

- [ ] **Step 1: 追加 noRecord 场景的 fallback 决策测试**

文件: `Tests/XCTest/IntegrationMockTests.swift:162`（在 `eligibilityNoRecord` 测试之后追加）

```swift
    @Test("decideRestoreEligibility: noRecord with window off main → noRecord (caller handles fallback)")
    func eligibilityNoRecordOffMain() {
        // When no toggle record exists, decideRestoreEligibility still returns .noRecord
        // regardless of window position — the caller (handleUserPromptSubmit) decides
        // whether to fallback to moveWindowToMainScreen
        let result = HookEventHandler.decideRestoreEligibility(
            isToggleInFlight: false,
            isWindowOnMainScreen: false,
            record: nil,
            mainScreenFrame: nil
        )
        assertEligibility(result, expected: "windowNotOnMainScreen")
    }
```

- [ ] **Step 2: 运行全量测试**
Run: `swift test 2>&1 | tail -5`
Expected:
  - Exit code: 0

- [ ] **Step 3: 质量门禁**
Run: `swift build 2>&1 | grep -c "error:" && swift test 2>&1 | tail -3`
Expected:
  - Exit code: 0

- [ ] **Step 4: 提交**
Run: `git add Tests/XCTest/IntegrationMockTests.swift && git commit -m "test: add decideRestoreEligibility noRecord-off-main test"`

---

### Task 3: 端到端验证 — 从 local-server-002 触发真实 hook

**Depends on:** Task 1, Task 2
**Files:** None (manual verification)

- [ ] **Step 1: 部署到本地 VibeFocus**

Run: `bash Tests/run_all_tests.sh 2>&1 | tail -3`
Expected:
  - Exit code: 0
  - All tests pass

- [ ] **Step 2: 重建并启动 VibeFocus**
Run: `open /Applications/VibeFocus.app`
Expected:
  - VibeFocus 启动成功（menu bar 出现图标）

- [ ] **Step 3: 从 local-server-002 发送 SessionStart + UserPromptSubmit 测试**
Run:
```bash
ssh -T local-server-002 << 'TEST'
echo '{"event":"SessionStart","session_id":"fix-verify-001","terminal_ctx":{"TERM_SESSION_ID":"v","TTY":"/dev/pts/1","PPID":"425","machine_label":"local-server-002"},"source":"startup","model":"test"}' | bash ~/.vibefocus/hook-forwarder.sh
echo ""
echo "=== UserPromptSubmit ==="
echo '{"event":"UserPromptSubmit","session_id":"fix-verify-001","terminal_ctx":{"TERM_SESSION_ID":"v","TTY":"/dev/pts/1","PPID":"425","machine_label":"local-server-002"}}' | bash ~/.vibefocus/hook-forwarder.sh
TEST
```
Expected:
  - SessionStart: `"code":"session_bound"`
  - UserPromptSubmit: NOT `"no_action_needed"` — should be `"window_moved"` or `"already_on_main_screen"`

- [ ] **Step 4: 提交验证结果**
确认 UserPromptSubmit 不再返回 `no_action_needed`，窗口成功移动或已在主屏。
