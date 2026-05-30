# Bug Fix: Stop 事件无法区分本地/远程 session 导致远程 UPS 自动恢复失败

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Symptom:** 远程 SSH session (local-server-002) 的 UserPromptSubmit 自动恢复不工作。Stop 事件要么完全不移动窗口 (`triggerOnStop=false`)，要么导致本地 session 窗口跳跃 (`triggerOnStop=true`)。

**Root Cause:** `HookEventHandler.swift:579` — `guard ClaudeHookPreferences.triggerOnStop` 是全局开关，无法区分本地和远程 session。当 `triggerOnStop=false` 时，远程 session 的 Stop 事件被完全忽略，导致：窗口不被移动到主屏 → 无 ToggleRecord → UPS 自动恢复失败。

**Impact:** 所有远程 SSH session 的 Stop 事件无法触发窗口移动，UPS 自动恢复链路断裂。

**Scope:** Small
**Risk:** Medium
**Risks:**
- 修改 `handleWindowMoveTrigger` 签名 — 缓解：新参数有默认值，SessionEnd 调用方无需改动
- `triggerOnStop=false` 语义变化（从"完全不处理"变为"只处理远程"）— 缓解：这是正确的语义，本地窗口在用户面前不需要 Stop 移动
- 现有 14 个 decideWindowMove 测试 — 缓解：新参数有默认值，无需修改现有测试

**Architecture:** Stop 事件 → `handleStop` 判断 `triggerOnStop` → 传递 `remoteOnly` 标志给 `handleWindowMoveTrigger` → 绑定解析后检查 `bindingType` → 本地绑定跳过 / 远程绑定继续移动。数据流：`handleStop(remoteOnly)` → `handleWindowMoveTrigger` → binding resolution → `localBindingSkip` guard → `moveBindingToMainScreen`。

**Tech Stack:** Swift 5, XCTest (swift-testing), macOS AppKit

**Autonomy Level:** Full

---

### Task 1: 添加 remoteOnly 决策逻辑到决策枚举、纯函数和处理器

**Depends on:** None
**Files:**
- Modify: `Sources/Hook/HookEventHandler+WindowMove.swift:10-20` (WindowMoveDecision enum)
- Modify: `Sources/Hook/HookEventHandler+WindowMove.swift:24-53` (decideWindowMove 纯函数)
- Modify: `Sources/Hook/HookEventHandler+WindowMove.swift:57-164` (handleWindowMoveTrigger)
- Modify: `Sources/Hook/HookEventHandler.swift:576-599` (handleStop)

- [ ] **Step 1: 给 WindowMoveDecision 枚举添加 localBindingSkip case**

文件: `Sources/Hook/HookEventHandler+WindowMove.swift:10-20`（替换整个枚举定义）

```swift
    enum WindowMoveDecision: Equatable {
        case autoFocusDisabled
        case localBindingSkip
        case noBindingSkip
        case bindingVerificationFailed
        case alreadyCompleted
        case alreadyOnMainScreen
        case restoreCooldownActive
        case staleBindingPIDMismatch
        case nonTerminalWindow
        case proceedToMove(source: String)
    }
```

- [ ] **Step 2: 给 decideWindowMove 纯函数添加 remoteOnly 和 isLocalBinding 参数及守卫**

文件: `Sources/Hook/HookEventHandler+WindowMove.swift:24-53`（替换整个函数）

```swift
    static func decideWindowMove(
        autoFocusEnabled: Bool,
        hasBinding: Bool,
        bindingVerified: Bool,
        isWindowOnMainScreen: Bool,
        isInCooldown: Bool,
        bindingAge: TimeInterval,
        pidMatches: Bool?,
        isTerminalOrIDE: Bool,
        remoteOnly: Bool = false,
        isLocalBinding: Bool = false
    ) -> WindowMoveDecision {
        guard autoFocusEnabled else { return .autoFocusDisabled }

        if remoteOnly && isLocalBinding { return .localBindingSkip }

        if !hasBinding {
            return .noBindingSkip
        }

        guard bindingVerified else { return .bindingVerificationFailed }

        if isWindowOnMainScreen { return .alreadyOnMainScreen }

        if isInCooldown { return .restoreCooldownActive }

        if bindingAge > 1800 && pidMatches == false {
            return .staleBindingPIDMismatch
        }

        guard isTerminalOrIDE else { return .nonTerminalWindow }

        return .proceedToMove(source: hasBinding ? "binding" : "terminalCtx")
    }
```

- [ ] **Step 3: 给 handleWindowMoveTrigger 添加 remoteOnly 参数及本地绑定跳过逻辑**

文件: `Sources/Hook/HookEventHandler+WindowMove.swift:57-60`（修改函数签名）

```swift
    func handleWindowMoveTrigger(
        payload: ClaudeHookPayload,
        triggerName: String,
        remoteOnly: Bool = false
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
```

文件: `Sources/Hook/HookEventHandler+WindowMove.swift:141`（在 binding 解析完成后、verifyBinding 之前插入）

在 line 141 (`}` 结束 binding 解析 else-if-else 块) 之后、line 143 (`guard SessionWindowRegistry.shared.verifyBinding`) 之前插入：

```swift

        // remoteOnly 模式：仅处理远程 session 的 Stop 事件，跳过本地绑定
        if remoteOnly && binding.bindingType == .local {
            SessionWindowRegistry.shared.touch(
                sessionID: payload.sessionID,
                message: "\(triggerName) 本地绑定跳过（Stop 仅限远程）"
            )
            log(
                "[HookEventHandler] \(triggerName) local binding skipped (remoteOnly mode)",
                level: .debug,
                fields: [
                    "sessionID": payload.sessionID,
                    "windowID": String(binding.windowID),
                    "bindingType": "local"
                ]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "local_binding_skip",
                    message: "Stop trigger skipped for local binding (remoteOnly mode)",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }
```

- [ ] **Step 4: 修改 handleStop 传递 remoteOnly 标志**

文件: `Sources/Hook/HookEventHandler.swift:576-599`（替换整个 handleStop 方法）

```swift
    func handleStop(
        payload: ClaudeHookPayload
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        // triggerOnStop=true: 处理所有 session（本地+远程）
        // triggerOnStop=false: 仅处理远程 session（跳过本地绑定）
        let remoteOnly = !ClaudeHookPreferences.triggerOnStop
        return handleWindowMoveTrigger(payload: payload, triggerName: "Stop", remoteOnly: remoteOnly)
    }
```

- [ ] **Step 5: 质量门禁 — 编译检查**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"
  - Output does NOT contain: "error:"

---

### Task 2: 更新测试覆盖 remoteOnly 决策逻辑

**Depends on:** Task 1
**Files:**
- Modify: `Tests/XCTest/WindowMoveDecisionTests.swift:207-224` (assertDecision helper)
- Modify: `Tests/XCTest/WindowMoveDecisionTests.swift` (添加新测试)

- [ ] **Step 1: 更新 assertDecision helper 添加 localBindingSkip case**

文件: `Tests/XCTest/WindowMoveDecisionTests.swift:207-224`（替换 assertDecision 函数，约 line 207）

定位方式：搜索 `private func assertDecision` — 在 `// MARK: - Helper` 注释下方。

```swift
    private func assertDecision(
        _ result: HookEventHandler.WindowMoveDecision,
        expected: String
    ) {
        let actual: String
        switch result {
        case .autoFocusDisabled: actual = "autoFocusDisabled"
        case .localBindingSkip: actual = "localBindingSkip"
        case .noBindingSkip: actual = "noBindingSkip"
        case .bindingVerificationFailed: actual = "bindingVerificationFailed"
        case .alreadyCompleted: actual = "alreadyCompleted"
        case .alreadyOnMainScreen: actual = "alreadyOnMainScreen"
        case .restoreCooldownActive: actual = "restoreCooldownActive"
        case .staleBindingPIDMismatch: actual = "staleBindingPIDMismatch"
        case .nonTerminalWindow: actual = "nonTerminalWindow"
        case .proceedToMove: actual = "proceedToMove"
        }
        #expect(actual == expected, "Expected \(expected), got \(actual)")
    }
```

- [ ] **Step 2: 添加 remoteOnly 决策测试用例**

文件: `Tests/XCTest/WindowMoveDecisionTests.swift`（在 `// MARK: - Guard priority` 注释之前插入新 section）

定位方式：搜索 `// MARK: - Guard priority` — 在该行之前插入。

```swift

    // MARK: - remoteOnly (Stop for remote sessions only)

    @Test("remoteOnly + local binding → localBindingSkip")
    func remoteOnlyLocalBindingSkip() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: true,
            hasBinding: true, bindingVerified: true,
            isWindowOnMainScreen: false, isInCooldown: false,
            bindingAge: 100,
            pidMatches: true, isTerminalOrIDE: true,
            remoteOnly: true, isLocalBinding: true
        )
        assertDecision(result, expected: "localBindingSkip")
    }

    @Test("remoteOnly + remote binding → proceedToMove")
    func remoteOnlyRemoteBindingProceeds() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: true,
            hasBinding: true, bindingVerified: true,
            isWindowOnMainScreen: false, isInCooldown: false,
            bindingAge: 100,
            pidMatches: true, isTerminalOrIDE: true,
            remoteOnly: true, isLocalBinding: false
        )
        if case .proceedToMove = result { } else {
            #expect(Bool(false), "Expected .proceedToMove, got \(result)")
        }
    }

    @Test("remoteOnly + autoFocus disabled → autoFocusDisabled takes priority")
    func remoteOnlyAutoFocusPriority() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: false,
            hasBinding: true, bindingVerified: true,
            isWindowOnMainScreen: false, isInCooldown: false,
            bindingAge: 100,
            pidMatches: true, isTerminalOrIDE: true,
            remoteOnly: true, isLocalBinding: true
        )
        assertDecision(result, expected: "autoFocusDisabled")
    }

    @Test("remoteOnly=false + local binding → proceedToMove (no restriction)")
    func noRemoteOnlyLocalBindingProceeds() {
        let result = HookEventHandler.decideWindowMove(
            autoFocusEnabled: true,
            hasBinding: true, bindingVerified: true,
            isWindowOnMainScreen: false, isInCooldown: false,
            bindingAge: 100,
            pidMatches: true, isTerminalOrIDE: true,
            remoteOnly: false, isLocalBinding: true
        )
        if case .proceedToMove = result { } else {
            #expect(Bool(false), "Expected .proceedToMove, got \(result)")
        }
    }

```

- [ ] **Step 3: 验证测试通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift test --filter WindowMoveDecision 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output contains: "Test Suite" and "passed"
  - Output does NOT contain: "failed" or "FAIL"

---

### Task 3: 全量测试 + 构建 + 部署 + 验证

**Depends on:** Task 1, Task 2
**Files:** None (commands only)

- [ ] **Step 1: 全量回归测试**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift test 2>&1 | tail -30`
Expected:
  - Exit code: 0
  - Output contains: "Test Suite" and "passed"
  - Output does NOT contain: "failed"

- [ ] **Step 2: 构建并部署**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && bash scripts/dev-build.sh 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - VibeFocus.app 构建成功并启动

- [ ] **Step 3: 验证 hook 配置和日志**

确认 `triggerOnStop` 保持 `false`（无需改动）：

Run: `cat ~/.vibefocus/config.json | python3 -c "import json,sys; d=json.load(sys.stdin); print('triggerOnStop:', d.get('claudeHookTriggerOnStop', 'NOT_FOUND'))"`
Expected:
  - Output: `triggerOnStop: False`

等待远程 session 的 Stop 事件触发后检查日志：

Run: `grep -E "(local_binding_skip|remoteOnly|Stop.*moving window)" ~/Library/Logs/VibeFocus/vibefocus.log | tail -10`
Expected:
  - 本地 session Stop → 包含 `local_binding_skip`
  - 远程 session Stop → 包含 `moving window`（正常移动）

- [ ] **Step 4: 提交**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && git add Sources/Hook/HookEventHandler.swift Sources/Hook/HookEventHandler+WindowMove.swift Tests/XCTest/WindowMoveDecisionTests.swift && git commit -m "$(cat <<'EOF'
fix(stop): make Stop event remote-only when triggerOnStop disabled

When triggerOnStop=false, Stop events now only process remote sessions,
skipping local bindings. This enables the Stop→UPS auto-restore pipeline
for remote SSH sessions without causing window jumping for local sessions.

- Add localBindingSkip case to WindowMoveDecision enum
- Add remoteOnly/isLocalBinding params to decideWindowMove pure function
- Add remoteOnly param to handleWindowMoveTrigger (default: false)
- handleStop passes remoteOnly=!triggerOnStop
- Add 4 new test cases for remoteOnly decision logic

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`
