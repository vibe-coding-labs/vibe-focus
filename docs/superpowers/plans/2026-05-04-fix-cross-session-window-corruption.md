# Bug Fix: 跨会话窗口恢复 — 不相关 Terminal 窗口被错误移动

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 VibeFocus 窗口管理中跨会话状态污染导致的严重 bug：当一个 Claude Code 会话的 SubAgent/AgentTeam 退出时，不相关的 Terminal 窗口被错误地从主屏移动到副屏。

**Root Cause:** 三个相互关联的架构缺陷共同导致：

1. **savedWindowStates 是无会话归属的全局列表**（WindowManager.swift:12）— 所有会话共享同一个状态数组，app-level fallback 按 `appName` 匹配时会找到其他会话的状态
2. **hydrateMemory 设置全局单例状态**（WindowManagerSupport.swift:2156-2171）— `lastWindowToken`/`lastWindowFrame`/`lastTargetFrame` 是全局变量，Session A 的状态会覆盖 Session B 的
3. **UserPromptSubmit handler 无会话隔离**（ClaudeHookServer.swift:549）— app-level fallback 用 `appName` 匹配（不限 sessionID），performDirectSecondaryRestore 无条件移动任何 bound 窗口到副屏

**Architecture:** 修复方案：在 UserPromptSubmit handler 中，所有 savedWindowState 查询必须加 `sessionID == payload.sessionID` 约束；删除或限域 app-level fallback 和 generic restore 路径；restore 操作直接传递 state 参数而非依赖全局 hydrateMemory。

**Tech Stack:** Swift 5.9, macOS 14+, CoreGraphics, AXUIElement

**Risks:**
- 修改核心恢复逻辑可能影响单会话场景的正常工作 → 缓解：单会话时 sessionID 匹配自然通过，行为不变
- 移除 app-level fallback 可能导致某些边缘场景无法恢复 → 缓解：这些场景本身就是错误恢复，不恢复比恢复错窗口好

---

### Task 1: Session-Scoped Saved State Matching

**Depends on:** None
**Files:**
- Modify: `Sources/ClaudeHookServer.swift:495-590`（handleUserPromptSubmit 中的 saved state 匹配逻辑）

- [ ] **Step 1: 修改 handleUserPromptSubmit 的 saved state 匹配 — 加入 sessionID 约束，修复 app-level fallback**

文件: `Sources/ClaudeHookServer.swift:495-590`（handleUserPromptSubmit 中 binding 存在时的 saved state 搜索逻辑）

```swift
// 替换 handleUserPromptSubmit 中 binding 存在时的完整 saved state 匹配逻辑
// 文件: ClaudeHookServer.swift, 从 "优先级 1: windowID + pid 精确匹配" 注释开始
// 到 "窗口不在主屏 → 最后尝试通用 restore" 逻辑结束

// 优先级 1: windowID + pid 精确匹配（限当前会话）
if let matchedState = wm.savedWindowStates.reversed().first(where: { state in
    state.windowID == targetWindowID
        && state.pid == targetPID
        && state.sessionID == payload.sessionID
        && !wm.isSavedStateCorrupted(state)
}) {
    return performRestore(
        payload: payload, matchedState: matchedState,
        matchLevel: "exact_binding_match"
    )
}

// 优先级 2: 仅 windowID 匹配（pid 可能因进程重启而不同，限当前会话）
if let matchedState := wm.savedWindowStates.reversed().first(where: { state in
    state.windowID == targetWindowID
        && state.sessionID == payload.sessionID
        && !wm.isSavedStateCorrupted(state)
}) {
    log(
        "[ClaudeHookServer] UserPromptSubmit fallback: matched by windowID only (session-scoped)",
        fields: [
            "sessionID": payload.sessionID,
            "stateWindowID": String(matchedState.windowID ?? 0),
            "statePID": String(matchedState.pid ?? 0),
            "bindingPID": String(targetPID)
        ]
    )
    return performRestore(
        payload: payload, matchedState: matchedState,
        matchLevel: "windowid_only_fallback"
    )
}

// 优先级 3: 窗口在主屏 + 同会话同 app 的 saved state
let isOnMain = wm.isWindowOnMainScreen(windowID: targetWindowID)
log(
    "[ClaudeHookServer] UserPromptSubmit no session-scoped saved state, checking main screen",
    fields: [
        "sessionID": payload.sessionID,
        "windowOnMainScreen": String(isOnMain),
        "bindingApp": binding.windowIdentity.appName ?? "unknown"
    ]
)

if isOnMain {
    // 只匹配当前会话 + 同 app 的 saved state（不再跨会话污染）
    if let appState = wm.savedWindowStates.reversed().first(where: { state in
        state.appName == binding.windowIdentity.appName
            && state.sessionID == payload.sessionID
            && !wm.isSavedStateCorrupted(state)
    }) {
        log(
            "[ClaudeHookServer] UserPromptSubmit session-scoped app fallback",
            fields: [
                "sessionID": payload.sessionID,
                "stateApp": appState.appName ?? "unknown",
                "stateWindowID": String(describing: appState.windowID),
                "bindingWindowID": String(targetWindowID)
            ]
        )
        return performRestore(
            payload: payload, matchedState: appState,
            matchLevel: "app_level_fallback_session_scoped"
        )
    }

    // 同会话无 saved state 但窗口在主屏 → 直接移到副屏
    return performDirectSecondaryRestore(
        payload: payload, binding: binding
    )
}

// 窗口不在主屏且无匹配 saved state → 不做任何操作
// 之前的 generic restore (shouldRestoreCurrentWindow) 使用全局状态，会跨会话污染
log(
    "[ClaudeHookServer] UserPromptSubmit window not on main screen and no session-scoped saved state, skipping",
    fields: [
        "sessionID": payload.sessionID,
        "windowOnMainScreen": String(isOnMain)
    ]
)
handledRequestCount += 1
return (
    200,
    ClaudeHookResponse(
        ok: true, code: "no_action_needed",
        message: "Window not on main screen and no session-scoped state to restore",
        sessionID: payload.sessionID, handled: false
    )
)
```

- [ ] **Step 2: 修改无 binding 路径 — 移除全局 shouldRestoreCurrentWindow 调用**

文件: `Sources/ClaudeHookServer.swift:591-618`（handleUserPromptSubmit 中 binding 不存在的分支）

```swift
// 替换 "无 binding 时，回退到 lastWindowToken 检查" 的整个 else 分支
// 文件: ClaudeHookServer.swift:591-618

} else {
    log(
        "[ClaudeHookServer] UserPromptSubmit no binding found, skipping restore",
        level: .warn,
        fields: [
            "sessionID": payload.sessionID,
            "savedStatesCount": String(wm.savedWindowStates.count)
        ]
    )
    // 不再调用 shouldRestoreCurrentWindow / wm.restore()
    // 这些函数使用全局 lastWindowToken/lastWindowFrame，会跨会话污染
    // 无 binding = 无窗口关联 = 不应操作任何窗口
    handledRequestCount += 1
    return (
        200,
        ClaudeHookResponse(
            ok: true, code: "no_binding_skip",
            message: "No session binding, skipping restore to prevent cross-session corruption",
            sessionID: payload.sessionID, handled: false
        )
    )
}
```

- [ ] **Step 3: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/ClaudeHookServer.swift && git commit -m "fix(hook): scope saved state matching to current session to prevent cross-session window corruption"`

---

### Task 2: Move handleStop to Use Session-Scoped State

**Depends on:** None
**Files:**
- Modify: `Sources/ClaudeHookServer.swift:788-874`（handleWindowMoveTrigger 中的 binding 解析和窗口移动逻辑）

- [ ] **Step 1: 修改 handleWindowMoveTrigger — 确保已完成会话不重复移动，终端上下文匹配限制在已绑定会话**

文件: `Sources/ClaudeHookServer.swift:788-874`

核心改动：在 `moveBindingToMainScreen` 之前增加防护 — 如果 binding 已标记完成（isCompleted=true），说明上一次 Stop 已经处理过，跳过重复移动。这防止 SubAgent Stop 事件反复触发已完成的会话的窗口移动。

```swift
// 替换 handleWindowMoveTrigger 的完整实现
// 文件: ClaudeHookServer.swift:788-874

private func handleWindowMoveTrigger(
    payload: ClaudeHookPayload,
    triggerName: String
) -> (statusCode: Int, response: ClaudeHookResponse) {
    log(
        "[ClaudeHookServer] \(triggerName) triggered",
        fields: [
            "sessionID": payload.sessionID,
            "autoFocusEnabled": String(ClaudeHookPreferences.autoFocusOnSessionEnd),
            "cwd": payload.cwd ?? "nil"
        ]
    )

    guard ClaudeHookPreferences.autoFocusOnSessionEnd else {
        SessionWindowRegistry.shared.touch(
            sessionID: payload.sessionID,
            message: "\(triggerName) 收到（自动聚焦已关闭）"
        )
        handledRequestCount += 1
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "auto_focus_disabled",
                message: "\(triggerName) received, auto focus disabled",
                sessionID: payload.sessionID, handled: false
            )
        )
    }

    // 查找已绑定的会话
    let binding: SessionWindowBinding
    if let existingBinding = SessionWindowRegistry.shared.binding(for: payload.sessionID) {
        // 关键防护：如果 binding 已标记完成，跳过重复移动
        // 这防止 SubAgent/AgentTeam 的 Stop 事件反复触发已结束会话的窗口移动
        if existingBinding.isCompleted {
            log(
                "[ClaudeHookServer] \(triggerName) session already completed, skipping",
                fields: [
                    "sessionID": payload.sessionID,
                    "completedAt": existingBinding.completedAt?.description ?? "nil"
                ]
            )
            handledRequestCount += 1
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "session_already_completed",
                    message: "Session already completed, skipping duplicate Stop",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }
        binding = existingBinding
    } else if let terminalCtx = payload.terminalCtx, terminalCtx.hasUsefulContext {
        log(
            "[ClaudeHookServer] \(triggerName) no binding, trying terminal context",
            fields: [
                "sessionID": payload.sessionID,
                "tty": terminalCtx.tty ?? "nil",
                "ppid": terminalCtx.ppid ?? "nil",
                "termSessionID": terminalCtx.termSessionID ?? "nil"
            ]
        )
        guard let ctxIdentity = WindowManager.shared.findWindowByTerminalContext(terminalCtx) else {
            unmatchedSessionCount += 1
            SessionWindowRegistry.shared.setLastEventDescription(
                "\(triggerName) 终端上下文匹配失败：\(payload.sessionID)"
            )
            log(
                "[ClaudeHookServer] \(triggerName) terminal context match failed",
                level: .warn,
                fields: ["sessionID": payload.sessionID]
            )
            return fallbackToCWDMatching(payload: payload, triggerName: triggerName)
        }

        log(
            "[ClaudeHookServer] \(triggerName) matched via terminal context",
            fields: [
                "sessionID": payload.sessionID,
                "app": ctxIdentity.appName ?? "unknown",
                "title": ctxIdentity.title ?? "untitled",
                "windowID": String(ctxIdentity.windowID)
            ]
        )

        let now = Date()
        binding = SessionWindowBinding(
            sessionID: payload.sessionID,
            windowIdentity: ctxIdentity,
            createdAt: now,
            lastSeenAt: now,
            isCompleted: false,
            completedAt: nil
        )
    } else {
        return fallbackToCWDMatching(payload: payload, triggerName: triggerName)
    }

    return moveBindingToMainScreen(binding: binding, payload: payload, triggerName: triggerName)
}
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/ClaudeHookServer.swift && git commit -m "fix(hook): skip duplicate Stop events for already-completed sessions"`

---

### Task 3: Add isCompleted Guard to moveBindingToMainScreen

**Depends on:** None
**Files:**
- Modify: `Sources/ClaudeHookServer.swift:989-1094`（moveBindingToMainScreen 函数）

- [ ] **Step 1: 强化 moveBindingToMainScreen 的 isCompleted 检查 — 从 early return 变为硬性防护**

文件: `Sources/ClaudeHookServer.swift:989-1009`

当前的 isCompleted 检查在函数入口（line 995-1009），返回 `already_completed`。但这层检查可能被 handleWindowMoveTrigger 绕过（当 binding 通过 terminal context 新建时，isCompleted 默认为 false）。需要增加额外的窗口位置验证：如果窗口已在主屏幕，不要创建新的 saved state。

实际上函数已有 `isWindowOnMainScreen` 检查（line 1013-1034）。关键问题是：这个检查使用 `binding.windowIdentity.windowID`，如果 windowID 对应的是错误窗口（已被另一个 session 占用），检查就失效了。

修改方案：在移动窗口之前，验证 binding 中的 windowID 对应的窗口 title/appName 与 binding 中存储的一致。

```swift
// 在 moveBindingToMainScreen 函数中，在 "安全检查：确保绑定的是终端/IDE 窗口" 之后
// 添加窗口身份验证
// 文件: ClaudeHookServer.swift:1035 之后

// 验证窗口身份：确保 binding 中的窗口信息仍然有效
// 防止 windowID 被复用导致错误窗口被移动
if let bindingWindowID = binding.windowIdentity.windowID as? UInt32, bindingWindowID > 0 {
    if let currentFrame = WindowManager.shared.getCurrentWindowFrame(windowID: bindingWindowID) {
        // 窗口存在，验证 PID 是否匹配
        let options: CGWindowListOption = [.optionOnScreenOnly]
        if let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
            let matchedWindow = windowList.first { window in
                (window[kCGWindowNumber as String] as? UInt32) == bindingWindowID
            }
            if let matched = matchedWindow {
                let currentPID = matched[kCGWindowOwnerPID as String] as? Int32
                let currentAppName = matched[kCGWindowOwnerName as String] as? String

                // PID 不匹配说明窗口已被其他进程复用
                if currentPID != binding.windowIdentity.pid {
                    log(
                        "[ClaudeHookServer] \(triggerName) window PID mismatch, skipping",
                        level: .warn,
                        fields: [
                            "sessionID": payload.sessionID,
                            "expectedPID": String(binding.windowIdentity.pid),
                            "actualPID": String(currentPID ?? 0),
                            "windowID": String(bindingWindowID)
                        ]
                    )
                    handledRequestCount += 1
                    return (
                        200,
                        ClaudeHookResponse(
                            ok: true, code: "window_pid_mismatch",
                            message: "Window PID changed, likely reused by different process",
                            sessionID: payload.sessionID, handled: false
                        )
                    )
                }
            }
        }
    } else {
        // 窗口不存在（可能已关闭）
        log(
            "[ClaudeHookServer] \(triggerName) binding window no longer exists",
            level: .warn,
            fields: [
                "sessionID": payload.sessionID,
                "windowID": String(bindingWindowID),
                "app": binding.windowIdentity.appName ?? "unknown"
            ]
        )
        handledRequestCount += 1
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "window_not_found",
                message: "Bound window no longer exists",
                sessionID: payload.sessionID, handled: false
            )
        )
    }
}
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/ClaudeHookServer.swift && git commit -m "fix(hook): add window identity verification before move to prevent stale binding corruption"`

---

### Task 4: Build, Deploy & E2E Test

**Depends on:** Task 1, Task 2, Task 3
**Files:**
- No new files

- [ ] **Step 1: Release build**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 2: Deploy VibeFocus.app to /Applications**

遵循 deploy workflow（完整 app bundle + code signing）：
1. 从 release build 产物创建 app bundle
2. Code sign
3. 复制到 /Applications
4. 重启 VibeFocus

- [ ] **Step 3: E2E 验证 — 单会话场景**

手动测试：
1. 启动 VibeFocus
2. 在副屏启动一个 Claude Code session
3. 输入 prompt → 确认窗口不被错误移动
4. Claude 完成 → Stop → 窗口应移到主屏
5. 再输入 prompt → UserPromptSubmit → 窗口应恢复到副屏
6. 重复 3-5 次，确认行为一致且无跨会话污染

- [ ] **Step 4: E2E 验证 — 多会话 + SubAgent 场景**

手动测试（这是 bug 复现场景）：
1. 在副屏启动 Claude Code Session A
2. 在主屏启动 Claude Code Session B
3. 在 Session A 中使用 Agent Teams 创建多个 Agent
4. 等待 Agent 完成
5. 验证：Session B 的窗口应始终保持在主屏，不被移动
6. 验证：Session A 的窗口按正常流程移动

Expected:
  - Session B 的窗口位置完全不受 Session A 的 Agent 活动影响
  - 没有 "主屏窗口回退到副屏" 的情况发生

- [ ] **Step 5: 提交**
Run: `git add -A && git commit -m "fix(hook): deploy cross-session window corruption fix — e2e verified"`
