# Fix: Hook 自动恢复链路可靠性

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 Hook 自动恢复链路（Stop → 移动到主屏 → UserPromptSubmit → 恢复到原位）中三个导致失败的 bug，使 Claude Code hooks 能可靠地自动移动和恢复终端窗口。

**Architecture:** Hook 链路数据流：Claude Code Stop hook → hook-forwarder.sh（捕获 PPID/TTY/termSessionID）→ ClaudeHookServer.handleWindowMoveTrigger → WindowManager.moveWindowToMainScreen → 保存 SavedWindowState(sessionID) → Claude Code UserPromptSubmit hook → handleUserPromptSubmit → 按 sessionID 查找 SavedWindowState → WindowManager.restore。修复三个断裂点：(1) findWindowByTerminalContext 忽略 PPID 的 TTY 解析；(2) cwd 回退 Strategy 4 返回任意焦点窗口；(3) UserPromptSubmit 找不到 state 时无回退逻辑。

**Tech Stack:** Swift 5.9, AppKit, JXA (JavaScript for Automation), CGWindowList API

**Risks:**
- Task 1 新增 `ps -o tty=` 调用解析 PPID 的 TTY，可能因进程已退出返回空 → 缓解：空结果时静默跳过，不影响后续 PPID ancestor 匹配
- Task 2 限制 Strategy 4 只匹配 Terminal/IDE 窗口，可能导致部分 Stop 返回 404 → 缓解：Task 1 的 TTY 解析大幅提高匹配成功率，减少对 Strategy 4 的依赖
- Task 2 的 UserPromptSubmit 回退可能恢复错误窗口 → 缓解：使用与 hotkey 路径完全相同的 shouldRestoreCurrentWindow 逻辑，已长期验证

---

### Root Cause Analysis

**完整失败链路**（以日志 14:40:03 Stop 为例）：

```
Stop sessionID=b1c4a78d cwd=vibe-focus
  → SessionStart binding 缺失
  → terminal context: tty="not a tty", ppid=95780, termSessionID=27F6155A-...
  → findWindowByTerminalContext: 只检查 TTY 和 PPID ancestor，忽略 termSessionID
  → TTY 匹配失败（tty="not a tty"），PPID ancestor 失败
  → cwd 回退: findClaudeCodeWindow Strategies 1-3 无匹配
  → Strategy 4: 返回焦点窗口（claude-pet 的 Terminal，已在主屏）
  → moveWindowToMainScreen: "skipped: already on main screen" → 返回 true 但不保存状态
  → Stop 报告 "moved successfully" 但无 SavedWindowState
  → UserPromptSubmit: "no matching saved state"
```

**Bug #1: findWindowByTerminalContext 不解析 PPID 的 TTY**

`Sources/WindowManagerSupport.swift:235-269` — 函数接收 PPID 但只用它做进程树遍历（findWindowByProcessAncestor），不解析其 TTY。Claude Code (node) 进程由终端启动，`ps -o tty= -p <node_PID>` 返回有效 TTY（如 `ttys001`），但 hook-forwarder 自身不是终端进程所以 `tty` 命令返回 "not a tty"。

**Bug #2: findClaudeCodeWindow Strategy 4 返回任意窗口**

`Sources/WindowManagerSupport.swift:206-214` — 当 cwd 项目名在副屏窗口标题中无匹配时，Strategy 4 回退到 `captureFocusedWindowIdentity()` 返回当前焦点窗口（可能是 Chrome、飞书等任何应用），导致 Stop 移动错误窗口或在窗口已在主屏时跳过（不保存状态）。

**Bug #3: UserPromptSubmit 无回退匹配逻辑**

`Sources/ClaudeHookServer.swift:247-269` — 只按 `state.sessionID == payload.sessionID` 查找状态。当 Stop 保存的状态 sessionID 不匹配（跨会话场景）或 Stop 根本没保存状态（Bug #1/#2 导致），直接返回 404，不尝试已有的 shouldRestoreCurrentWindow 匹配逻辑。

---

### Task 1: Add PPID TTY Resolution to findWindowByTerminalContext

**Depends on:** None
**Files:**
- Modify: `Sources/WindowManagerSupport.swift:235-269` (findWindowByTerminalContext 函数)

- [ ] **Step 1: 添加 resolveTTY 辅助方法 — 通过 ps 命令解析进程的 TTY 设备**

文件: `Sources/WindowManagerSupport.swift:269` (在 `findWindowByTerminalContext` 函数之后、`findWindowByTTY` 之前插入)

```swift
    /// 通过 ps 命令解析指定 PID 进程关联的 TTY 设备
    /// Claude Code (node) 由终端启动，ps -o tty= 可返回有效 TTY（如 ttys001）
    /// 即使 hook-forwarder 自身 tty 命令返回 "not a tty"
    private func resolveTTY(forPID pid: Int32) -> String? {
        let output = runShellCommand("/bin/ps", args: ["-o", "tty=", "-p", String(pid)])
        let tty = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if tty.isEmpty || tty == "??" || tty == "?" {
            return nil
        }
        return tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
    }
```

- [ ] **Step 2: 修改 findWindowByTerminalContext — 在 TTY 匹配和 PPID ancestor 之间插入 PPID TTY 解析策略**

文件: `Sources/WindowManagerSupport.swift:235-269` (替换整个 `findWindowByTerminalContext` 函数)

```swift
    func findWindowByTerminalContext(_ ctx: TerminalContext) -> WindowIdentity? {
        // 策略 1: 通过 TTY 匹配 Terminal.app / iTerm2 窗口（原始路径）
        if let tty = ctx.tty, !tty.isEmpty, tty != "not a tty" {
            if let identity = findWindowByTTY(tty) {
                log(
                    "[WindowManager] findWindowByTerminalContext matched by TTY",
                    fields: ["tty": tty, "app": identity.appName ?? "unknown"]
                )
                return identity
            }
        }

        // 策略 1.5: 通过 PPID 解析 TTY 再匹配
        // hook-forwarder 的 tty 返回 "not a tty"，但 PPID（Claude Code node 进程）
        // 关联了终端的 TTY，ps -o tty= -p <PPID> 可以返回有效值
        if let ppidStr = ctx.ppid, let ppid = Int32(ppidStr), ppid > 1 {
            if let resolvedTTY = resolveTTY(forPID: ppid) {
                if let identity = findWindowByTTY(resolvedTTY) {
                    log(
                        "[WindowManager] findWindowByTerminalContext matched by resolved TTY from PPID",
                        fields: [
                            "ppid": ppidStr,
                            "resolvedTTY": resolvedTTY,
                            "app": identity.appName ?? "unknown"
                        ]
                    )
                    return identity
                }
            }
        }

        // 策略 2: 通过 PPID 进程树匹配（适用于 IDE 集成终端等场景）
        if let ppidStr = ctx.ppid, let shellPID = Int32(ppidStr), shellPID > 1 {
            if let identity = findWindowByProcessAncestor(pid: shellPID) {
                log(
                    "[WindowManager] findWindowByTerminalContext matched by process ancestor",
                    fields: ["ppid": ppidStr, "app": identity.appName ?? "unknown"]
                )
                return identity
            }
        }

        log(
            "[WindowManager] findWindowByTerminalContext: no match",
            level: .warn,
            fields: [
                "tty": ctx.tty ?? "nil",
                "ppid": ctx.ppid ?? "nil",
                "termSessionID": ctx.termSessionID ?? "nil",
                "itermSessionID": ctx.itermSessionID ?? "nil"
            ]
        )
        return nil
    }
```

- [ ] **Step 3: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/WindowManagerSupport.swift && git commit -m "fix(hooks): resolve TTY from PPID for reliable terminal window matching"`

---

### Task 2: Restrict Stop Fallback + Add UserPromptSubmit Restore Fallback

**Depends on:** Task 1
**Files:**
- Modify: `Sources/ClaudeHookServer.swift:425-477` (fallbackToCWDMatching 函数)
- Modify: `Sources/ClaudeHookServer.swift:219-306` (handleUserPromptSubmit 函数)

- [ ] **Step 1: 修改 fallbackToCWDMatching — 限制 Strategy 4 只匹配终端/IDE 窗口**

文件: `Sources/ClaudeHookServer.swift:425-477` (替换整个 `fallbackToCWDMatching` 函数)

```swift
    private func fallbackToCWDMatching(
        payload: ClaudeHookPayload,
        triggerName: String
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        log(
            "[ClaudeHookServer] \(triggerName) no binding found, falling back to cwd matching",
            fields: [
                "sessionID": payload.sessionID,
                "cwd": payload.cwd ?? "nil"
            ]
        )
        guard let focusedIdentity = WindowManager.shared.findClaudeCodeWindow(cwd: payload.cwd) else {
            unmatchedSessionCount += 1
            SessionWindowRegistry.shared.setLastEventDescription(
                "\(triggerName) 未命中绑定且无前台窗口：\(payload.sessionID)"
            )
            log(
                "[ClaudeHookServer] \(triggerName) no binding and no focused window",
                level: .warn,
                fields: ["sessionID": payload.sessionID]
            )
            return (
                404,
                ClaudeHookResponse(
                    ok: false, code: "binding_not_found",
                    message: "No bound window for session and no focused window available",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 安全检查：findClaudeCodeWindow 的 Strategy 4（焦点窗口回退）
        // 可能返回非终端/IDE 窗口（Chrome、飞书等），这类窗口不应被自动移动
        let terminalAppNames: Set<String> = [
            "Terminal", "iTerm2", "Warp", "Ghostty", "Alacritty", "kitty",
            "Cursor", "Code", "Visual Studio Code",
            "com.apple.Terminal", "com.googlecode.iterm2",
            "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"
        ]
        let isTerminalApp: Bool = {
            if let appName = focusedIdentity.appName, terminalAppNames.contains(appName) {
                return true
            }
            if let bundleID = focusedIdentity.bundleIdentifier, terminalAppNames.contains(bundleID) {
                return true
            }
            return false
        }()

        // 如果 cwd 匹配到了非终端窗口（如 Chrome），检查窗口标题是否包含 cwd 项目名
        // 只有标题明确包含项目名时才认为是 Claude Code 相关窗口
        if !isTerminalApp {
            let projectName = payload.cwd?
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .components(separatedBy: "/")
                .last?
                .lowercased()
            let titleContainsProject = projectName.map { p in
                (focusedIdentity.title ?? "").lowercased().contains(p)
            } ?? false

            if !titleContainsProject {
                unmatchedSessionCount += 1
                log(
                    "[ClaudeHookServer] \(triggerName) cwd fallback matched non-terminal app without project name in title, skipping",
                    level: .warn,
                    fields: [
                        "sessionID": payload.sessionID,
                        "app": focusedIdentity.appName ?? "unknown",
                        "title": focusedIdentity.title ?? "untitled",
                        "windowID": String(focusedIdentity.windowID)
                    ]
                )
                return (
                    404,
                    ClaudeHookResponse(
                        ok: false, code: "non_terminal_window",
                        message: "Matched non-terminal window without project name correlation",
                        sessionID: payload.sessionID, handled: false
                    )
                )
            }
        }

        log(
            "[ClaudeHookServer] \(triggerName) using cwd fallback",
            fields: [
                "sessionID": payload.sessionID,
                "app": focusedIdentity.appName ?? "unknown",
                "title": focusedIdentity.title ?? "untitled",
                "windowID": String(focusedIdentity.windowID),
                "isTerminalApp": String(isTerminalApp)
            ]
        )

        let now = Date()
        let binding = SessionWindowBinding(
            sessionID: payload.sessionID,
            windowIdentity: focusedIdentity,
            createdAt: now,
            lastSeenAt: now,
            isCompleted: false,
            completedAt: nil
        )

        return moveBindingToMainScreen(binding: binding, payload: payload, triggerName: triggerName)
    }
```

- [ ] **Step 2: 修改 handleUserPromptSubmit — 添加 shouldRestoreCurrentWindow 回退逻辑**

文件: `Sources/ClaudeHookServer.swift:219-306` (替换整个 `handleUserPromptSubmit` 函数)

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

        // 优先级 1: 按 sessionID 查找对应的 saved state
        let matchedState = WindowManager.shared.savedWindowStates.reversed().first { state in
            state.sessionID == payload.sessionID && !WindowManager.shared.isSavedStateCorrupted(state)
        }

        if let savedState = matchedState {
            // 从 saved state 恢复到内存
            WindowManager.shared.hydrateMemory(from: savedState, window: nil)

            log(
                "[ClaudeHookServer] UserPromptSubmit restoring window",
                fields: [
                    "sessionID": payload.sessionID,
                    "stateID": savedState.id,
                    "app": savedState.appName ?? "unknown",
                    "windowID": String(describing: savedState.windowID),
                    "originalFrame": String(describing: savedState.originalFrame.cgRect)
                ]
            )

            // 执行恢复
            WindowManager.shared.restore(
                operationID: makeOperationID(prefix: "hook-restore"),
                triggerSource: "user_prompt_submit"
            )

            // 重新激活绑定，使下一个 Stop 事件能再次触发窗口移动
            SessionWindowRegistry.shared.reactivate(sessionID: payload.sessionID)

            handledRequestCount += 1
            SessionWindowRegistry.shared.setLastEventDescription(
                "UserPromptSubmit 恢复窗口：\(savedState.appName ?? "Unknown")"
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "window_restored",
                    message: "Window restored to original position",
                    sessionID: payload.sessionID, handled: true
                )
            )
        }

        // 优先级 2: sessionID 无匹配时，回退到 shouldRestoreCurrentWindow 逻辑
        // 复用 hotkey 路径的匹配机制（windowID / PID+title+position）
        log(
            "[ClaudeHookServer] UserPromptSubmit no sessionID match, trying shouldRestoreCurrentWindow fallback",
            level: .info,
            fields: [
                "sessionID": payload.sessionID,
                "savedStatesCount": String(WindowManager.shared.savedWindowStates.count)
            ]
        )

        if WindowManager.shared.shouldRestoreCurrentWindow() {
            log(
                "[ClaudeHookServer] UserPromptSubmit fallback: shouldRestoreCurrentWindow matched",
                fields: [
                    "sessionID": payload.sessionID
                ]
            )

            WindowManager.shared.restore(
                operationID: makeOperationID(prefix: "hook-restore-fallback"),
                triggerSource: "user_prompt_submit_fallback"
            )

            SessionWindowRegistry.shared.reactivate(sessionID: payload.sessionID)

            handledRequestCount += 1
            SessionWindowRegistry.shared.setLastEventDescription(
                "UserPromptSubmit 回退恢复窗口"
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "window_restored_fallback",
                    message: "Window restored via fallback matching",
                    sessionID: payload.sessionID, handled: true
                )
            )
        }

        // 无匹配
        log(
            "[ClaudeHookServer] UserPromptSubmit no matching saved state",
            level: .warn,
            fields: [
                "sessionID": payload.sessionID,
                "savedStatesCount": String(WindowManager.shared.savedWindowStates.count)
            ]
        )
        return (
            404,
            ClaudeHookResponse(
                ok: false, code: "no_saved_state",
                message: "No saved window state found for session",
                sessionID: payload.sessionID, handled: false
            )
        )
    }
```

- [ ] **Step 3: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/ClaudeHookServer.swift && git commit -m "fix(hooks): restrict cwd fallback to terminal apps and add UserPromptSubmit restore fallback"`

---

### Task 3: Build, Deploy, and Verify

**Depends on:** Task 1, Task 2
**Files:**
- Modify: `Sources/AppVersion.swift` (version bump)

- [ ] **Step 1: Bump version to 0.0.13**

文件: `Sources/AppVersion.swift`

将版本号从 `"0.0.12"` 改为 `"0.0.13"`。

- [ ] **Step 2: Build release**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -3`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: Package and deploy**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && bash package_release.sh && cp dist/VibeFocus.app/Contents/MacOS/VibeFocusHotkeys ~/Applications/VibeFocus.app/Contents/MacOS/VibeFocusHotkeys`
Expected:
  - Exit code: 0
  - Binary updated in ~/Applications/

- [ ] **Step 4: Restart VibeFocus and verify**

Run: `pkill -f VibeFocusHotkeys; sleep 1; open ~/Applications/VibeFocus.app`
Expected:
  - New process starts
  - Menu bar icon appears

- [ ] **Step 5: 验证 PPID TTY 解析是否工作**

Run: `sleep 3 && grep -i "resolved TTY\|findWindowByTerminalContext" /tmp/vibefocus.log | tail -5`
Expected:
  - 如果有 Stop hook 触发，日志中应出现 "resolved TTY from PPID" 或成功匹配
  - 不再出现 "terminal context match failed" 后直接跳到 cwd fallback

- [ ] **Step 6: 验证 Hook 链路端到端**

在副屏终端中启动 Claude Code → 等待 Stop hook 触发 → 检查终端窗口是否移动到主屏 → 提交新 prompt → 检查窗口是否恢复到副屏

Run: `grep -i "Stop window moved\|UserPromptSubmit.*restored\|hook-restore" /tmp/vibefocus.log | tail -10`
Expected:
  - Stop 事件后出现 "window moved successfully"（非 "skipped"）
  - UserPromptSubmit 后出现 "restored" 或 "fallback"

- [ ] **Step 7: Commit version bump**
Run: `git add Sources/AppVersion.swift && git commit -m "release: v0.0.13"`
