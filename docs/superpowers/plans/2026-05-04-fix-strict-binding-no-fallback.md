# Bug Fix: 窗口到处乱跳 — 根除兜底逻辑，建立严格的 Session → Terminal 绑定验证

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 VibeFocus 窗口到处乱跳的根本问题：Claude Code session → Terminal window 的绑定没有验证机制，兜底逻辑在跨会话操作错误窗口。修复策略：在绑定中存储 TTY 用于验证，删除所有兜底路径，验证失败时不操作。

**Root Cause:** `SessionWindowBinding` 只存储 `(sessionID, windowID, pid, appName)` 但不存储 TTY。Hook 事件到达时，代码盲目信任 binding 中的 windowID，不验证该窗口是否仍属于同一个 Terminal 会话。当窗口 ID 被复用、Terminal 重启、或多个 Terminal 窗口共存时，binding 指向错误窗口，兜底逻辑进一步扩大伤害范围。

**Architecture:**
- 数据流：`SessionStart hook → 通过 TTY/PPID 找到 Terminal 窗口 → 绑定(sessionID, windowID, pid, TTY)` → 事件到达 → 重新验证窗口 TTY 是否匹配 → 匹配才操作，不匹配不操作
- 关键组件：`SessionWindowBinding` 增加 `terminalTTY` 字段；`ClaudeHookServer` 增加 `verifyBinding()` 方法
- 为什么这样做：TTY 是 Terminal 会话的唯一稳定标识，窗口 ID 会变但 TTY 在会话期间不变

**Tech Stack:** Swift 5.9, macOS 14+, CGWindowList, ps command for TTY lookup

**Risks:**
- 删除兜底后，某些边缘场景（Terminal 重启后 TTY 变化）可能无法自动恢复 → 这比恢复错窗口好得多
- TTY 验证需要调用 `ps` 命令，有微量性能开销 → 可接受
- 每次改一个函数就提交，确保可回滚

---

### Task 1: 增强 SessionWindowBinding — 存储 TTY 用于验证

**Depends on:** None
**Files:**
- Modify: `Sources/ClaudeHookModels.swift:25-32`（SessionWindowBinding 结构体）

- [ ] **Step 1: 修改 SessionWindowBinding — 添加 terminalTTY 和 terminalSessionID 字段**

文件: `Sources/ClaudeHookModels.swift:25-32`

```swift
// 替换 SessionWindowBinding 结构体（完整替换）
struct SessionWindowBinding: Codable, Equatable {
    let sessionID: String
    var windowIdentity: WindowIdentity
    let createdAt: Date
    var lastSeenAt: Date
    var isCompleted: Bool
    var completedAt: Date?

    /// 绑定时的 Terminal TTY（如 "/dev/ttys003"）
    /// 用于验证 binding 是否仍然有效 — 窗口 ID 可能被复用，但 TTY 在会话期间不变
    var terminalTTY: String?

    /// 绑定时的 Terminal Session ID（macOS Terminal.app 的 TERM_SESSION_ID）
    var terminalSessionID: String?
}
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/ClaudeHookModels.swift && git commit -m "fix(binding): add terminalTTY and terminalSessionID to SessionWindowBinding for verification"`

---

### Task 2: 在 handleSessionStart 中存储 TTY 到 binding

**Depends on:** Task 1
**Files:**
- Modify: `Sources/ClaudeHookServer.swift:293-447`（handleSessionStart 函数）

- [ ] **Step 1: 修改 handleSessionStart — 绑定时保存 terminal context**

文件: `Sources/ClaudeHookServer.swift`

在 `SessionWindowRegistry.shared.bind(...)` 调用处（约 line 417），将 terminal context 信息传入 binding。

首先修改 `SessionWindowRegistry.bind` 方法签名以接受 TTY 信息：

文件: `Sources/SessionWindowRegistry.swift:29-60`

```swift
// 替换 SessionWindowRegistry.bind 函数
func bind(sessionID: String, windowIdentity: WindowIdentity, terminalTTY: String? = nil, terminalSessionID: String? = nil) {
    log("SessionWindowRegistry.bind entry", level: .debug, fields: [
        "sessionID": sessionID,
        "appName": windowIdentity.appName ?? "nil",
        "title": windowIdentity.title ?? "nil",
        "terminalTTY": terminalTTY ?? "nil"
    ])
    let now = Date()
    let normalizedSession = normalizeSessionID(sessionID)
    guard !normalizedSession.isEmpty else {
        log("SessionWindowRegistry.bind empty sessionID after normalization", level: .debug)
        return
    }

    if var existing = bindings[normalizedSession] {
        log("SessionWindowRegistry.bind updating existing binding", level: .debug, fields: ["normalizedSession": normalizedSession])
        existing.windowIdentity = windowIdentity
        existing.lastSeenAt = now
        existing.isCompleted = false
        existing.completedAt = nil
        existing.terminalTTY = terminalTTY
        existing.terminalSessionID = terminalSessionID
        bindings[normalizedSession] = existing
    } else {
        log("SessionWindowRegistry.bind creating new binding", level: .debug, fields: ["normalizedSession": normalizedSession])
        bindings[normalizedSession] = SessionWindowBinding(
            sessionID: normalizedSession,
            windowIdentity: windowIdentity,
            createdAt: now,
            lastSeenAt: now,
            isCompleted: false,
            completedAt: nil,
            terminalTTY: terminalTTY,
            terminalSessionID: terminalSessionID
        )
    }
    lastEventDescription = "SessionStart 绑定窗口：\(windowIdentity.appName ?? "Unknown") / \(windowIdentity.title ?? "Untitled")"
    pruneExpiredBindings(shouldPersist: false)
    persistBindings()
    log("SessionWindowRegistry.bind exit", level: .debug, fields: ["normalizedSession": normalizedSession, "totalBindings": String(bindings.count)])
}
```

然后修改 handleSessionStart 中的 bind 调用，传入 TTY：

文件: `Sources/ClaudeHookServer.swift` handleSessionStart 中 `SessionWindowRegistry.shared.bind(...)` 调用处

```swift
// 替换 handleSessionStart 中的 bind 调用（约 line 417）
// 从 payload.terminalCtx 中提取 TTY 和 session ID
let tty = payload.terminalCtx?.tty
let termSessionID = payload.terminalCtx?.termSessionID

SessionWindowRegistry.shared.bind(
    sessionID: payload.sessionID,
    windowIdentity: identity,
    terminalTTY: tty,
    terminalSessionID: termSessionID
)
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0

- [ ] **Step 3: 提交**
Run: `git add Sources/ClaudeHookServer.swift Sources/SessionWindowRegistry.swift && git commit -m "fix(binding): store TTY in session binding during SessionStart for later verification"`

---

### Task 3: 添加绑定验证方法 — 检查窗口是否仍属于同一 Terminal 会话

**Depends on:** Task 2
**Files:**
- Modify: `Sources/ClaudeHookServer.swift` — 添加 verifyBinding 方法

- [ ] **Step 1: 在 ClaudeHookServer 中添加 verifyBinding — 通过 TTY 验证窗口归属**

文件: `Sources/ClaudeHookServer.swift`

在 `handleStop` 函数之前添加验证方法：

```swift
// MARK: - Binding Verification

/// 验证 binding 中的窗口是否仍属于同一个 Terminal 会话
/// 通过检查 binding 的 TTY 与窗口当前 TTY 是否一致来判断
/// 如果 TTY 不匹配（窗口被关闭/复用），返回 false
private func verifyBinding(_ binding: SessionWindowBinding, payload: ClaudeHookPayload) -> Bool {
    // 1. 检查窗口是否仍然存在
    let windowID = binding.windowIdentity.windowID
    guard windowID > 0 else {
        log(
            "[ClaudeHookServer] verifyBinding: invalid windowID",
            level: .warn,
            fields: ["sessionID": payload.sessionID]
        )
        return false
    }

    guard WindowManager.shared.getCurrentWindowFrame(windowID: windowID) != nil else {
        log(
            "[ClaudeHookServer] verifyBinding: window no longer exists",
            level: .warn,
            fields: [
                "sessionID": payload.sessionID,
                "windowID": String(windowID)
            ]
        )
        return false
    }

    // 2. 检查窗口 PID 是否仍匹配
    let options: CGWindowListOption = [.optionOnScreenOnly]
    guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        log("[ClaudeHookServer] verifyBinding: CGWindowList failed", level: .warn)
        return false
    }

    guard let windowInfo = windowList.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == windowID }) else {
        log(
            "[ClaudeHookServer] verifyBinding: window not found in CGWindowList",
            level: .warn,
            fields: ["sessionID": payload.sessionID, "windowID": String(windowID)]
        )
        return false
    }

    let currentPID = windowInfo[kCGWindowOwnerPID as String] as? Int32
    if currentPID != binding.windowIdentity.pid {
        log(
            "[ClaudeHookServer] verifyBinding: PID mismatch — window was reused by different process",
            level: .warn,
            fields: [
                "sessionID": payload.sessionID,
                "expectedPID": String(binding.windowIdentity.pid),
                "actualPID": String(currentPID ?? 0),
                "windowID": String(windowID)
            ]
        )
        return false
    }

    // 3. 如果 binding 有 TTY，验证窗口对应的 TTY 仍然一致
    if let boundTTY = binding.terminalTTY, !boundTTY.isEmpty {
        // 通过 binding 的 PID 查找该进程的 TTY
        let currentTTY = resolveTTYForPID(binding.windowIdentity.pid)
        if let currentTTY, currentTTY != boundTTY {
            log(
                "[ClaudeHookServer] verifyBinding: TTY mismatch — window belongs to different terminal session",
                level: .warn,
                fields: [
                    "sessionID": payload.sessionID,
                    "boundTTY": boundTTY,
                    "currentTTY": currentTTY,
                    "windowID": String(windowID)
                ]
            )
            return false
        }
    }

    log(
        "[ClaudeHookServer] verifyBinding: passed",
        fields: [
            "sessionID": payload.sessionID,
            "windowID": String(windowID),
            "pid": String(binding.windowIdentity.pid)
        ]
    )
    return true
}

/// 通过 PID 查找该进程的 TTY
private func resolveTTYForPID(_ pid: Int32) -> String? {
    let result = runShellCommand("/bin/ps", args: ["-p", String(pid), "-o", "tty="])
    guard result.exitCode == 0 else { return nil }
    let tty = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !tty.isEmpty, tty != "??" else { return nil }
    return "/dev/\(tty)"
}

/// 运行 shell 命令的辅助方法
private func runShellCommand(_ command: String, args: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: command)
    process.arguments = args
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    do {
        try process.run()
        process.waitUntilExit()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    } catch {
        return (1, "", error.localizedDescription)
    }
}
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0

- [ ] **Step 3: 提交**
Run: `git add Sources/ClaudeHookServer.swift && git commit -m "fix(binding): add verifyBinding — check PID and TTY match before any window operation"`

---

### Task 4: 删除所有兜底逻辑 — handleUserPromptSubmit 只走严格验证路径

**Depends on:** Task 3
**Files:**
- Modify: `Sources/ClaudeHookServer.swift:449-638`（handleUserPromptSubmit 完整重写）

- [ ] **Step 1: 重写 handleUserPromptSubmit — 只在有有效绑定且验证通过时才操作窗口**

文件: `Sources/ClaudeHookServer.swift:449-638`（完整替换 handleUserPromptSubmit）

设计原则：
- 有 binding → 验证 binding → 验证通过 → 用 sessionID 匹配 savedState → 恢复
- 有 binding → 验证失败 → 不操作，返回 binding_invalid
- 无 binding → 不操作，返回 no_binding
- **不再有任何兜底路径**

```swift
private func handleUserPromptSubmit(
    payload: ClaudeHookPayload
) -> (statusCode: Int, response: ClaudeHookResponse) {
    log(
        "[ClaudeHookServer] UserPromptSubmit triggered",
        fields: [
            "sessionID": payload.sessionID,
            "autoRestoreEnabled": String(ClaudeHookPreferences.autoRestoreOnPromptSubmit),
            "cwd": payload.cwd ?? "nil"
        ]
    )

    guard ClaudeHookPreferences.autoRestoreOnPromptSubmit else {
        SessionWindowRegistry.shared.touch(
            sessionID: payload.sessionID,
            message: "UserPromptSubmit 收到（自动恢复已关闭）"
        )
        handledRequestCount += 1
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "auto_restore_disabled",
                message: "UserPromptSubmit received, auto restore disabled",
                sessionID: payload.sessionID, handled: false
            )
        )
    }

    // 记录活动时间（用于 Stop 防抖）
    lastActivityBySession[payload.sessionID] = Date()

    // 严格路径：必须有 binding 且验证通过
    guard let binding = SessionWindowRegistry.shared.binding(for: payload.sessionID) else {
        log(
            "[ClaudeHookServer] UserPromptSubmit no binding found, skipping",
            level: .warn,
            fields: ["sessionID": payload.sessionID]
        )
        handledRequestCount += 1
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "no_binding",
                message: "No session binding, skipping restore",
                sessionID: payload.sessionID, handled: false
            )
        )
    }

    // 验证 binding：窗口是否仍属于此 session
    guard verifyBinding(binding, payload: payload) else {
        log(
            "[ClaudeHookServer] UserPromptSubmit binding verification failed",
            level: .warn,
            fields: [
                "sessionID": payload.sessionID,
                "windowID": String(binding.windowIdentity.windowID)
            ]
        )
        handledRequestCount += 1
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "binding_invalid",
                message: "Binding verification failed — window may have been closed or reassigned",
                sessionID: payload.sessionID, handled: false
            )
        )
    }

    let wm = WindowManager.shared
    let targetWindowID = binding.windowIdentity.windowID
    let targetPID = binding.windowIdentity.pid

    // 只用当前 session 的 savedState 匹配
    // 优先级 1: windowID + pid + sessionID 精确匹配
    if let matchedState = wm.savedWindowStates.reversed().first(where: { state in
        state.windowID == targetWindowID
            && state.pid == targetPID
            && state.sessionID == payload.sessionID
            && !wm.isSavedStateCorrupted(state)
    }) {
        return performRestore(
            payload: payload, matchedState: matchedState,
            matchLevel: "exact_session_match"
        )
    }

    // 优先级 2: windowID + sessionID 匹配（PID 可能变化）
    if let matchedState = wm.savedWindowStates.reversed().first(where: { state in
        state.windowID == targetWindowID
            && state.sessionID == payload.sessionID
            && !wm.isSavedStateCorrupted(state)
    }) {
        return performRestore(
            payload: payload, matchedState: matchedState,
            matchLevel: "windowid_session_match"
        )
    }

    // 无匹配的 savedState → 不操作
    // 不再使用 app-level fallback / direct secondary restore / generic restore
    log(
        "[ClaudeHookServer] UserPromptSubmit no matching saved state for this session",
        fields: [
            "sessionID": payload.sessionID,
            "windowID": String(targetWindowID),
            "savedStatesCount": String(wm.savedWindowStates.count)
        ]
    )
    handledRequestCount += 1
    SessionWindowRegistry.shared.reactivate(sessionID: payload.sessionID)
    return (
        200,
        ClaudeHookResponse(
            ok: true, code: "no_session_saved_state",
            message: "Binding valid but no saved state for this session",
            sessionID: payload.sessionID, handled: false
        )
    )
}
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0

- [ ] **Step 3: 提交**
Run: `git add Sources/ClaudeHookServer.swift && git commit -m "fix(hook): remove all fallback paths from UserPromptSubmit — strict binding verification only"`

---

### Task 5: 删除 handleWindowMoveTrigger 中的兜底 — Stop 也只走严格验证

**Depends on:** Task 3
**Files:**
- Modify: `Sources/ClaudeHookServer.swift:762-874`（handleStop + handleWindowMoveTrigger）

- [ ] **Step 1: 重写 handleStop — 添加防抖 + 严格验证**

文件: `Sources/ClaudeHookServer.swift:762-785`

```swift
private func handleStop(
    payload: ClaudeHookPayload
) -> (statusCode: Int, response: ClaudeHookResponse) {
    // 防抖：如果 session 最近活跃（30秒内有 UserPromptSubmit），跳过
    if let lastActivity = lastActivityBySession[payload.sessionID] {
        let elapsed = Date().timeIntervalSince(lastActivity)
        if elapsed < stopDebounceInterval {
            log(
                "[ClaudeHookServer] Stop debounced — session active \(String(format: "%.1f", elapsed))s ago",
                fields: ["sessionID": payload.sessionID]
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
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "stop_trigger_disabled",
                message: "Stop received, trigger disabled",
                sessionID: payload.sessionID, handled: false
            )
        )
    }

    return handleWindowMoveTrigger(payload: payload, triggerName: "Stop")
}
```

- [ ] **Step 2: 重写 handleWindowMoveTrigger — 只在有 binding 且验证通过时才移动**

文件: `Sources/ClaudeHookServer.swift:788-874`

```swift
private func handleWindowMoveTrigger(
    payload: ClaudeHookPayload,
    triggerName: String
) -> (statusCode: Int, response: ClaudeHookResponse) {
    log(
        "[ClaudeHookServer] \(triggerName) triggered",
        fields: [
            "sessionID": payload.sessionID,
            "autoFocusEnabled": String(ClaudeHookPreferences.autoFocusOnSessionEnd)
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

    // 严格路径：必须有 binding 且验证通过
    guard let binding = SessionWindowRegistry.shared.binding(for: payload.sessionID) else {
        log(
            "[ClaudeHookServer] \(triggerName) no binding, skipping",
            level: .warn,
            fields: ["sessionID": payload.sessionID]
        )
        unmatchedSessionCount += 1
        handledRequestCount += 1
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "no_binding",
                message: "No session binding, skipping",
                sessionID: payload.sessionID, handled: false
            )
        )
    }

    // 已完成的 session → 跳过
    if binding.isCompleted {
        handledRequestCount += 1
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "session_already_completed",
                message: "Session already completed",
                sessionID: payload.sessionID, handled: false
            )
        )
    }

    // 验证 binding
    guard verifyBinding(binding, payload: payload) else {
        log(
            "[ClaudeHookServer] \(triggerName) binding verification failed",
            level: .warn,
            fields: ["sessionID": payload.sessionID]
        )
        handledRequestCount += 1
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "binding_invalid",
                message: "Binding verification failed",
                sessionID: payload.sessionID, handled: false
            )
        )
    }

    return moveBindingToMainScreen(binding: binding, payload: payload, triggerName: triggerName)
}
```

- [ ] **Step 3: 删除不再使用的兜底函数**

删除以下函数（已无调用方）：
- `fallbackToCWDMatching`（ClaudeHookServer.swift 约 line 892-987）
- `performDirectSecondaryRestore`（ClaudeHookServer.swift 约 line 681-760）

在删除前确认无其他调用点：
Run: `grep -n "fallbackToCWDMatching\|performDirectSecondaryRestore" /Users/cc11001100/github/vibe-coding-labs/vibe-focus/Sources/ClaudeHookServer.swift`
Expected:
  - 只有函数定义行，无其他调用

- [ ] **Step 4: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 5: 提交**
Run: `git add Sources/ClaudeHookServer.swift && git commit -m "fix(hook): remove all fallback paths — Stop and window move now require verified binding only"`

---

### Task 6: Build, Deploy & E2E Test

**Depends on:** Task 4, Task 5
**Files:**
- No new source files

- [ ] **Step 1: Release build**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0

- [ ] **Step 2: Deploy VibeFocus.app**
遵循 deploy workflow（完整 app bundle + code signing）

- [ ] **Step 3: E2E 验证 — 多会话场景（核心 bug 修复验证）**

手动测试：
1. 启动 VibeFocus
2. 在副屏 Terminal A 启动 Claude Code Session A
3. 在主屏 Terminal B 启动 Claude Code Session B
4. Session A 中使用 Agent Teams 创建多个 Agent
5. 等待 Agent 完成
6. 验证：Terminal B 窗口位置完全不变
7. 验证：只有 Session A 绑定的 Terminal A 窗口被操作

Expected:
  - Terminal B 完全不受影响
  - Terminal A 按正常流程操作

- [ ] **Step 4: E2E 验证 — 窗口关闭后不再错误操作**

手动测试：
1. 启动 Claude Code → 绑定 Terminal 窗口
2. 关闭该 Terminal 窗口
3. 打开新的 Terminal 窗口（可能复用 window ID）
4. 触发 UserPromptSubmit
5. 验证：VibeFocus 返回 `binding_invalid`，不操作任何窗口

- [ ] **Step 5: 提交**
Run: `git add -A && git commit -m "fix(binding): deploy strict binding verification — no more cross-session window corruption"`
