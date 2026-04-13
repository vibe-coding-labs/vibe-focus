# Fix: Terminal Context 匹配失败导致 Stop Hook 不触发窗口移动

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 terminal context 匹配始终失败的问题，使 Stop hook 在无 SessionStart 绑定时也能通过 PPID 进程树找到正确的终端窗口。同时修复 SessionStart 绑定到非终端窗口（如 Chrome）的问题。

**Architecture:** Stop hook 数据流：Claude Code → hook-forwarder.sh（捕获 PPID/TTY/termSessionID）→ ClaudeHookServer.handleWindowMoveTrigger → SessionWindowRegistry 查找绑定 → [无绑定] → findWindowByTerminalContext → Strategy 1.5 当前只检查直接 PPID 的 TTY → 失败。修复：Strategy 1.7 向上遍历 PPID 树，每层都尝试 TTY 解析。SessionStart 数据流：handleSessionStart → captureFocusedWindowIdentity（捕获当前焦点窗口）→ 可能是 Chrome。修复：优先使用 terminalContext 匹配终端窗口。

**Tech Stack:** Swift 5.9, AppKit, CGWindowList API, JXA, `/bin/ps`

**Risks:**
- Task 1 的 PPID 树遍历增加了 `ps` 调用次数（最多 10 次），可能增加 Stop hook 响应延迟 → 缓解：每次 `ps` 调用约 5ms，最多增加 50ms，在可接受范围内
- Task 2 的 SessionStart terminal context 匹配可能因为 terminalContext 字段缺失而回退到焦点窗口 → 缓解：保持 captureFocusedWindowIdentity 作为 fallback

---

### Root Cause Analysis

**日志证据（v0.0.13, PID 73014）：**

```
16:08:22 Stop no binding, trying terminal context ppid=48254 tty="not a tty"
16:08:23 Stop terminal context match failed
16:08:23 Stop cwd fallback matched non-terminal app (Feishu), skipping → 404
```

日志中有 **~20 次 "terminal context match failed"，0 次成功**。成功的 Stop 事件全部依赖 SessionStart 绑定。

**根因 1：PPID TTY 解析只检查直接父进程**

`Sources/WindowManagerSupport.swift:248-263` — `resolveTTY(forPID:)` 只对直接 PPID 调用 `ps -o tty=`。进程链：hook-forwarder → node (hook runner) → node (Claude Code) → bash/zsh → Terminal.app。直接 PPID（hook runner）的 TTY 为 "??"，但 bash/zsh 的 TTY 为 "ttys001"。当前代码不会向上遍历。

**根因 2：SessionStart 绑定到焦点窗口而非终端窗口**

`Sources/ClaudeHookServer.swift:184-196` — `handleSessionStart` 只调用 `captureFocusedWindowIdentity()`，不考虑 payload 中的 terminalContext。当用户在 Chrome 上操作时启动新会话，绑定到 Chrome 而非 Terminal。

**根因 3：moveBindingToMainScreen 不验证绑定应用类型**

`Sources/ClaudeHookServer.swift:575-653` — 即使 SessionStart 绑定了 Chrome 窗口，Stop 也会尝试移动它。`fallbackToCWDMatching` 有终端应用验证，但 `moveBindingToMainScreen` 没有。

---

### Task 1: Enhance PPID TTY Resolution to Walk Up Process Tree

**Depends on:** None
**Files:**
- Modify: `Sources/WindowManagerSupport.swift:248-263` (Strategy 1.5 in `findWindowByTerminalContext`)

- [ ] **Step 1: 修改 findWindowByTerminalContext — 将 Strategy 1.5 扩展为遍历整个 PPID 树**

文件: `Sources/WindowManagerSupport.swift:248-263`（替换 Strategy 1.5 区块）

将当前的直接 PPID TTY 解析：
```swift
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
```

替换为向上遍历 PPID 树的版本：

```swift
        // 策略 1.5: 通过 PPID 进程树向上遍历，每层尝试 TTY 解析
        // hook-forwarder 的 tty 返回 "not a tty"，直接 PPID 可能也没有 TTY
        // 但进程链上层的 bash/zsh 一定有关联 TTY
        // 进程链: hook-forwarder → node (hook runner) → node (Claude Code) → bash/zsh → Terminal.app
        if let ppidStr = ctx.ppid, let startPID = Int32(ppidStr), startPID > 1 {
            var currentPID = startPID
            var depth = 0
            while depth < 10 {
                if let resolvedTTY = resolveTTY(forPID: currentPID) {
                    if let identity = findWindowByTTY(resolvedTTY) {
                        log(
                            "[WindowManager] findWindowByTerminalContext matched by resolved TTY from PPID tree",
                            fields: [
                                "startPID": ppidStr,
                                "resolvedPID": String(currentPID),
                                "depth": String(depth),
                                "resolvedTTY": resolvedTTY,
                                "app": identity.appName ?? "unknown"
                            ]
                        )
                        return identity
                    }
                }
                // 向上移动到父进程
                let ppidOutput = runShellCommand("/bin/ps", args: ["-o", "ppid=", "-p", String(currentPID)])
                guard let nextPIDStr = ppidOutput?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let nextPID = Int32(nextPIDStr), nextPID > 1, nextPID != currentPID else {
                    break
                }
                currentPID = nextPID
                depth += 1
            }
        }
```

- [ ] **Step 2: 验证编译**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**

Run: `git add Sources/WindowManagerSupport.swift && git commit -m "fix(hooks): walk up PPID tree for TTY resolution in terminal context matching"`

---

### Task 2: Add Terminal Context to SessionStart + Validate Binding App Type

**Depends on:** Task 1
**Files:**
- Modify: `Sources/ClaudeHookServer.swift:182-216` (handleSessionStart 函数)
- Modify: `Sources/ClaudeHookServer.swift:595-620` (moveBindingToMainScreen 新增 isWindowOnMainScreen 之后添加终端应用验证)

- [ ] **Step 1: 修改 handleSessionStart — 优先使用 terminal context 查找终端窗口**

文件: `Sources/ClaudeHookServer.swift:182-216`（替换整个 `handleSessionStart` 函数）

```swift
    private func handleSessionStart(
        payload: ClaudeHookPayload
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        // 优先使用 terminal context 精确匹配终端窗口
        var identity: WindowIdentity?
        if let terminalCtx = payload.terminalCtx, terminalCtx.hasUsefulContext {
            identity = WindowManager.shared.findWindowByTerminalContext(terminalCtx)
            if let identity {
                log(
                    "[ClaudeHookServer] SessionStart matched via terminal context",
                    fields: [
                        "sessionID": payload.sessionID,
                        "app": identity.appName ?? "unknown",
                        "title": identity.title ?? "untitled",
                        "windowID": String(identity.windowID)
                    ]
                )
            }
        }

        // 回退：捕获当前焦点窗口
        if identity == nil {
            identity = WindowManager.shared.captureFocusedWindowIdentity()
        }

        guard let identity else {
            SessionWindowRegistry.shared.setLastEventDescription("SessionStart 失败：当前无可绑定窗口")
            return (
                409,
                ClaudeHookResponse(
                    ok: false, code: "window_not_found",
                    message: "No focused window available for session binding",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }
        SessionWindowRegistry.shared.bind(sessionID: payload.sessionID, windowIdentity: identity)
        handledRequestCount += 1
        log(
            "[ClaudeHookServer] SessionStart bound",
            fields: [
                "sessionID": payload.sessionID,
                "app": identity.appName ?? "unknown",
                "title": identity.title ?? "untitled",
                "windowID": String(identity.windowID),
                "cwd": payload.cwd ?? "nil",
                "model": payload.model ?? "nil"
            ]
        )
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "session_bound",
                message: "Session bound to focused window",
                sessionID: payload.sessionID, handled: true
            )
        )
    }
```

- [ ] **Step 2: 修改 moveBindingToMainScreen — 在 isWindowOnMainScreen 检查后添加终端应用验证**

文件: `Sources/ClaudeHookServer.swift` (在 `isWindowOnMainScreen` 检查之后、`log("[ClaudeHookServer] \(triggerName) moving window"` 之前添加)

在已有的 `if WindowManager.shared.isWindowOnMainScreen(windowID:)` 代码块之后插入：

```swift
        // 安全检查：确保绑定的是终端/IDE 窗口
        // SessionStart 可能绑定到非终端窗口（Chrome、飞书等），这类窗口不应被自动移动
        let terminalAppNames: Set<String> = [
            "Terminal", "iTerm2", "Warp", "Ghostty", "Alacritty", "kitty",
            "Cursor", "Code", "Visual Studio Code",
            "com.apple.Terminal", "com.googlecode.iterm2",
            "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"
        ]
        let isTerminalBinding: Bool = {
            if let appName = binding.windowIdentity.appName, terminalAppNames.contains(appName) {
                return true
            }
            if let bundleID = binding.windowIdentity.bundleIdentifier, terminalAppNames.contains(bundleID) {
                return true
            }
            return false
        }()

        if !isTerminalBinding {
            handledRequestCount += 1
            SessionWindowRegistry.shared.setLastEventDescription(
                "\(triggerName) 绑定窗口非终端应用：\(binding.windowIdentity.appName ?? "Unknown")"
            )
            log(
                "[ClaudeHookServer] \(triggerName) bound window is non-terminal app, skipping",
                level: .warn,
                fields: [
                    "sessionID": payload.sessionID,
                    "app": binding.windowIdentity.appName ?? "unknown",
                    "bundleID": binding.windowIdentity.bundleIdentifier ?? "nil",
                    "windowID": String(binding.windowIdentity.windowID)
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
```

- [ ] **Step 3: 验证编译**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**

Run: `git add Sources/ClaudeHookServer.swift && git commit -m "fix(hooks): prefer terminal context in SessionStart and validate binding app type"`

---

### Task 3: Build, Deploy, and Verify

**Depends on:** Task 1, Task 2
**Files:**
- Modify: `Sources/AppVersion.swift` (version bump)

- [ ] **Step 1: Bump version to 0.0.15**

文件: `Sources/AppVersion.swift`

将版本号从 `"0.0.14"` 改为 `"0.0.15"`。

- [ ] **Step 2: Build release**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -3`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: Package and deploy**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && bash scripts/package_release.sh && cp dist/VibeFocus.app/Contents/MacOS/VibeFocusHotkeys ~/Applications/VibeFocus.app/Contents/MacOS/VibeFocusHotkeys`
Expected:
  - Exit code: 0
  - Binary updated in ~/Applications/

- [ ] **Step 4: Restart VibeFocus and verify**

Run: `pkill -f VibeFocusHotkeys; sleep 1; open ~/Applications/VibeFocus.app`
Expected:
  - New process starts
  - Menu bar icon appears

- [ ] **Step 5: 验证 PPID 树 TTY 解析**

Run: `sleep 3 && grep -i "resolved TTY from PPID tree\|findWindowByTerminalContext matched" /tmp/vibefocus.log | tail -10`
Expected:
  - 当 Stop hook 触发且无 SessionStart 绑定时，日志中出现 "resolved TTY from PPID tree"
  - terminal context 匹配成功率显著提高

- [ ] **Step 6: 验证 SessionStart 终端优先绑定**

Run: `grep "SessionStart matched via terminal context\|SessionStart bound" /tmp/vibefocus.log | tail -5`
Expected:
  - 新的 SessionStart 日志中优先出现 "matched via terminal context"
  - 绑定的 app 应为 Terminal/Cursor 等，而非 Chrome/Feishu

- [ ] **Step 7: Commit version bump**

Run: `git add Sources/AppVersion.swift && git commit -m "release: v0.0.15"`
