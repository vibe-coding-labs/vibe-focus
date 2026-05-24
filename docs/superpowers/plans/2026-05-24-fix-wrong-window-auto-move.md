# Bug Fix: Stop 事件触发错误窗口移动到主屏幕

**Symptom:** 用户有多个 iTerm2 窗口，部分运行 Claude Code，部分不运行。当任意 Claude 会话结束时，可能移动到非 Claude 窗口到主屏幕
**Root Cause:** `findWindowByTerminalContext` 在多 iTerm2 窗口场景下，TTY 匹配依赖窗口标题（iTerm2 不暴露标题给 CGWindowList），导致匹配主要依赖 iTerm2 AppleScript API，如果 API 返回错误的窗口 ID，SessionStart 绑定错误窗口，Stop 时移动错误窗口
**Impact:** 用户看到非 Claude 窗口被自动移动到主屏幕，"事件和 WindowId 对应关系混乱"
**Scope:** Small
**Risk:** Low

**Risks:**
- 增加窗口位置检查可能漏掉某些合法的移动场景 → 已排除：窗口在主屏时已有 `already_on_main_screen` 守卫

---

### Task 1: 在 moveBindingToMainScreen 增加窗口位置合理性校验

**Depends on:** None
**Files:**
- Modify: `Sources/Hook/HookEventHandler+WindowMove.swift:83-155`

在 `moveBindingToMainScreen` 函数中，在 `isWindowOnMainScreen` 检查之后，增加**窗口是否在副屏**的验证。如果窗口已经在主屏上，跳过；如果窗口不在主屏但绑定时的窗口和当前窗口信息不匹配（PID 变化、CGWindowNumber 被回收），也跳过。

同时增强日志，记录绑定创建时间和当前窗口位置，方便诊断。

- [ ] **Step 1: 修改 moveBindingToMainScreen 增加绑定年龄校验**

文件: `Sources/Hook/HookEventHandler+WindowMove.swift:83-156`（修改 `moveBindingToMainScreen` 函数）

在 `isWindowOnMainScreen` 检查之后、`isTerminalOrIDEApp` 检查之前，增加绑定年龄校验：如果绑定创建超过 30 分钟且窗口从未被移动（`isCompleted=false`），说明绑定可能已过期（窗口可能已被关闭/重建/CGWindowNumber 被回收），增加额外验证。

```swift
private func moveBindingToMainScreen(
    binding: WindowState,
    payload: ClaudeHookPayload,
    triggerName: String
) -> (statusCode: Int, response: ClaudeHookResponse) {
    if binding.isCompleted {
        log(
            "[HookEventHandler] \(triggerName) already completed",
            fields: ["sessionID": payload.sessionID]
        )
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "already_completed",
                message: "Session already completed",
                sessionID: payload.sessionID, handled: false
            )
        )
    }

    let windowID = binding.windowID

    // 预检：如果窗口已在主屏幕上，跳过移动
    if WindowManager.shared.isWindowOnMainScreen(windowID: windowID) {
        SessionWindowRegistry.shared.setLastEventDescription(
            "\(triggerName) 窗口已在主屏幕，跳过移动"
        )
        log(
            "[HookEventHandler] \(triggerName) window already on main screen, skipping move",
            fields: [
                "sessionID": payload.sessionID,
                "windowID": String(windowID),
                "app": binding.appName ?? "unknown"
            ]
        )
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "already_on_main_screen",
                message: "Window already on main screen, no action needed",
                sessionID: payload.sessionID, handled: false
            )
        )
    }

    // 绑定年龄校验：如果绑定超过 30 分钟且未完成，验证窗口 PID 是否仍匹配
    let bindingAge = Date().timeIntervalSince(binding.createdAt)
    if bindingAge > 1800 {
        let options: CGWindowListOption = [.optionAll]
        if let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]],
           let matchedWindow = windowList.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == windowID }) {
            let actualPID = matchedWindow[kCGWindowOwnerPID as String] as? Int32
            if actualPID != binding.pid {
                log(
                    "[HookEventHandler] \(triggerName) stale binding: window PID mismatch (binding age: \(Int(bindingAge))s)",
                    level: .warn,
                    fields: [
                        "sessionID": payload.sessionID,
                        "windowID": String(windowID),
                        "boundPID": String(binding.pid),
                        "actualPID": String(describing: actualPID),
                        "bindingAge": String(Int(bindingAge))
                    ]
                )
                // 清理过期绑定
                SessionWindowRegistry.shared.markCompleted(sessionID: payload.sessionID)
                return (
                    200,
                    ClaudeHookResponse(
                        ok: true, code: "stale_binding_pid_mismatch",
                        message: "Stale binding: window PID no longer matches",
                        sessionID: payload.sessionID, handled: false
                    )
                )
            }
        }
    }

    // 安全检查：确保绑定的是终端/IDE 窗口
    let isTerminalBinding = Self.isTerminalOrIDEApp(
        appName: binding.appName,
        bundleIdentifier: binding.bundleIdentifier
    )

    if !isTerminalBinding {
        SessionWindowRegistry.shared.setLastEventDescription(
            "\(triggerName) 绑定窗口非终端应用：\(binding.appName ?? "Unknown")"
        )
        log(
            "[HookEventHandler] \(triggerName) bound window is non-terminal app, skipping",
            level: .warn,
            fields: [
                "sessionID": payload.sessionID,
                "app": binding.appName ?? "unknown",
                "bundleID": binding.bundleIdentifier ?? "nil",
                "windowID": String(windowID)
            ]
        )
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "non_terminal_binding",
                message: "Bound window is not a terminal/IDE app, skipping",
                sessionID: payload.sessionID, handled: false
            )
        )
    }

    log(
        "[HookEventHandler] \(triggerName) moving window",
        fields: [
            "sessionID": payload.sessionID,
            "app": binding.appName ?? "unknown",
            "title": binding.title ?? "untitled",
            "windowID": String(windowID),
            "pid": String(binding.pid),
            "cwd": payload.cwd ?? "nil",
            "bindingAge": String(Int(bindingAge))
        ]
    )

    let identity = WindowIdentity(
        windowID: windowID,
        pid: binding.pid,
        bundleIdentifier: binding.bundleIdentifier,
        appName: binding.appName,
        windowNumber: binding.axWindowNumber,
        title: binding.title,
        capturedAt: binding.createdAt
    )

    let moved = WindowManager.shared.moveWindowToMainScreen(
        identity: identity,
        reason: .claudeSessionEnd,
        sessionID: payload.sessionID
    )
    if moved {
        SessionWindowRegistry.shared.markCompleted(sessionID: payload.sessionID)
        log(
            "[HookEventHandler] \(triggerName) window moved successfully",
            fields: [
                "sessionID": payload.sessionID,
                "app": binding.appName ?? "unknown",
                "title": binding.title ?? "untitled"
            ]
        )
        Task { @MainActor in
            SoundManager.shared.playCompletionSound()
            DockBadgeManager.shared.showBadge(
                targetBundleID: binding.bundleIdentifier,
                targetAppName: binding.appName
            )
        }
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "window_focused",
                message: "Window moved to main screen and maximized",
                sessionID: payload.sessionID, handled: true
            )
        )
    }

    SessionWindowRegistry.shared.touch(
        sessionID: payload.sessionID,
        message: "\(triggerName) 命中绑定，但移动窗口失败"
    )
    log(
        "[HookEventHandler] \(triggerName) window move failed",
        level: .error,
        fields: [
            "sessionID": payload.sessionID,
            "app": binding.appName ?? "unknown",
            "windowID": String(windowID)
        ]
    )
    return (
        409,
        ClaudeHookResponse(
            ok: false, code: "window_move_failed",
            message: "Found session binding but failed to move window",
            sessionID: payload.sessionID, handled: false
        )
    )
}
```

- [ ] **Step 2: 质量门禁检查**

Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - 无编译错误

- [ ] **Step 3: 提交**

Run: `git add Sources/Hook/HookEventHandler+WindowMove.swift && git commit -m "fix(hook): add stale binding PID check before auto-moving window on Stop"`

---

### Task 2: 部署并验证

**Depends on:** Task 1
**Files:** None

- [ ] **Step 1: 构建签名部署**

Run: `./scripts/dev-build.sh 2>&1 | tail -10`
Expected:
  - Exit code: 0

- [ ] **Step 2: 部署到本地应用**

Run: `open /Applications/VibeFocus.app`
Expected:
  - VibeFocus 重启

- [ ] **Step 3: 日志验证 — 确认新守卫生效**

Run: `tail -200 ~/Library/Logs/VibeFocus/vibefocus.log | grep -E "stale_binding|bindingAge|PID mismatch"`
Expected:
  - 当有 Stop 事件触发时，日志中出现 `bindingAge` 字段
  - 如果绑定过期（PID 不匹配），出现 `stale_binding_pid_mismatch` 并跳过移动
