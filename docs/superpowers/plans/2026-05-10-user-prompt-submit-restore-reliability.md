# UserPromptSubmit Auto-Restore Reliability Fix Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 彻底修复 UserPromptSubmit 自动回退功能频繁失效的问题。通过日志分析，定位了 3 个独立根因：1) `verifyBinding()` 失败后立即中止，不降级到 terminal context；2) `isNearTarget()` 容差太严格（150px），macOS 空间切换后位置偏移导致误判；3) `verifyBinding()` 无诊断日志，无法区分失败原因。

**Architecture:** 修改 handleUserPromptSubmit 控制流：当 binding 存在但验证失败时，降级到 terminal context 解析而非立即返回。修改 isNearTarget 增加容差参数，auto-restore 使用 300px 而非 150px。修改 verifyBinding 添加详细诊断日志。

**Tech Stack:** Swift 5.9, macOS 14+, SQLite3

**Risks:**
- Task 1 修改 verifyBinding 失败后的控制流，降级到 terminal context 可能解析到错误窗口 → 缓解：降级后的 identity 仍经过 isWindowOnMainScreen + ToggleEngine.load 验证，不会误操作
- Task 2 增大 isNearTarget 容差（150→300px）可能在用户手动移动窗口后误触发 restore → 缓解：仅对 auto-restore 路径使用大容差，手动 Ctrl+Q 保持 150px

---

### Task 1: 修改 handleUserPromptSubmit 控制流 — verifyBinding 失败后降级到 terminal context

**Depends on:** None
**Files:**
- Modify: `Sources/HookEventHandler.swift:181-190`

**Root Cause:** 当 `verifyBinding(state)` 返回 false 时（PID 变化、窗口重建），代码立即返回 `binding_verification_failed`，即使 payload 中携带了有效的 `terminalCtx`。这导致从绑定到终端上下文的整条降级路径被跳过。日志显示 4 次 binding_verification_failed 全部发生在 `hasTerminalCtx=true` 的请求中。

- [ ] **Step 1: 修改 handleUserPromptSubmit — verifyBinding 失败后降级到 terminal context 解析**

文件: `Sources/HookEventHandler.swift:181-190`（替换 `guard SessionWindowRegistry.shared.verifyBinding(state) else` 区块）

```swift
            if !SessionWindowRegistry.shared.verifyBinding(state) {
                log(
                    "[HookEventHandler] UserPromptSubmit binding verification failed, trying terminal context fallback",
                    level: .warn,
                    fields: [
                        "traceID": traceID,
                        "sessionID": payload.sessionID,
                        "pid": String(state.pid),
                        "tty": state.tty ?? "nil",
                        "windowID": String(state.windowID),
                        "hasTerminalCtx": String(payload.terminalCtx?.hasUsefulContext ?? false)
                    ]
                )
                // 降级到 terminal context 解析，不立即返回
                if let terminalCtx = payload.terminalCtx, terminalCtx.hasUsefulContext {
                    identity = WindowManager.shared.findWindowByTerminalContext(terminalCtx)
                    if let identity {
                        log(
                            "[HookEventHandler] UserPromptSubmit terminal context fallback resolved",
                            fields: [
                                "traceID": traceID,
                                "sessionID": payload.sessionID,
                                "fallbackWindowID": String(identity.windowID),
                                "originalWindowID": String(state.windowID)
                            ]
                        )
                    } else {
                        log(
                            "[HookEventHandler] UserPromptSubmit terminal context fallback also failed",
                            level: .warn,
                            fields: [
                                "traceID": traceID,
                                "sessionID": payload.sessionID
                            ]
                        )
                        return (
                            200,
                            ClaudeHookResponse(
                                ok: true, code: "binding_verification_failed",
                                message: "Binding verification and terminal context fallback both failed",
                                sessionID: payload.sessionID, handled: false
                            )
                        )
                    }
                } else {
                    return (
                        200,
                        ClaudeHookResponse(
                            ok: true, code: "binding_verification_failed",
                            message: "Binding verification failed, no terminal context for fallback",
                            sessionID: payload.sessionID, handled: false
                        )
                    )
                }
            } else {
```

注意：替换后需要在 `else` 分支中保留原有的 identity 赋值逻辑（从 state 创建 WindowIdentity）。完整的替换区块应包含原 `identity = WindowIdentity(...)` 代码。

实际上，需要把整个 `if let state` 区块重构为：验证失败 → 降级到 terminal context → 验证成功 → 用 state identity。具体操作：

读取 `Sources/HookEventHandler.swift:167-264`，将整个 identity 解析区块替换为以下逻辑：

```swift
        // 通过 sessionID 找到窗口状态
        let state = SessionWindowRegistry.shared.binding(for: payload.sessionID)
        var identity: WindowIdentity?
        var usedFallback = false

        if let state {
            if SessionWindowRegistry.shared.verifyBinding(state) {
                // 绑定验证通过 — 使用绑定中的 identity
                identity = WindowIdentity(
                    windowID: state.windowID,
                    pid: state.pid,
                    bundleIdentifier: state.bundleIdentifier,
                    appName: state.appName,
                    windowNumber: state.axWindowNumber,
                    title: state.title,
                    capturedAt: state.createdAt
                )
                log(
                    "[HookEventHandler] UserPromptSubmit binding resolved",
                    level: .debug,
                    fields: [
                        "traceID": traceID,
                        "sessionID": payload.sessionID,
                        "windowID": String(state.windowID),
                        "resolveDurationMs": String(elapsedMilliseconds(since: handleStartedAt))
                    ]
                )
            } else {
                // 绑定验证失败 — 降级到 terminal context
                log(
                    "[HookEventHandler] UserPromptSubmit binding verification failed, trying terminal context fallback",
                    level: .warn,
                    fields: [
                        "traceID": traceID,
                        "sessionID": payload.sessionID,
                        "boundWindowID": String(state.windowID),
                        "boundPID": String(state.pid),
                        "hasTerminalCtx": String(payload.terminalCtx?.hasUsefulContext ?? false)
                    ]
                )
                if let terminalCtx = payload.terminalCtx, terminalCtx.hasUsefulContext {
                    identity = WindowManager.shared.findWindowByTerminalContext(terminalCtx)
                    usedFallback = identity != nil
                    if let identity {
                        log(
                            "[HookEventHandler] UserPromptSubmit terminal context fallback resolved",
                            fields: [
                                "traceID": traceID,
                                "sessionID": payload.sessionID,
                                "fallbackWindowID": String(identity.windowID),
                                "originalBoundWindowID": String(state.windowID)
                            ]
                        )
                    }
                }
                if identity == nil {
                    log(
                        "[HookEventHandler] UserPromptSubmit binding verification failed and terminal context fallback also failed",
                        level: .warn,
                        fields: [
                            "traceID": traceID,
                            "sessionID": payload.sessionID
                        ]
                    )
                    return (
                        200,
                        ClaudeHookResponse(
                            ok: true, code: "binding_verification_failed",
                            message: "Binding verification and terminal context fallback both failed",
                            sessionID: payload.sessionID, handled: false
                        )
                    )
                }
            }
        } else if let terminalCtx = payload.terminalCtx, terminalCtx.hasUsefulContext {
            let terminalResolveStart = Date()
            identity = WindowManager.shared.findWindowByTerminalContext(terminalCtx)
            let terminalResolveMs = elapsedMilliseconds(since: terminalResolveStart)
            if let identity {
                log(
                    "[HookEventHandler] UserPromptSubmit resolved via terminal context",
                    fields: [
                        "traceID": traceID,
                        "sessionID": payload.sessionID,
                        "resolvedWindowID": String(identity.windowID),
                        "app": identity.appName ?? "unknown",
                        "terminalResolveMs": String(terminalResolveMs)
                    ]
                )
            } else {
                log(
                    "[HookEventHandler] UserPromptSubmit terminal context resolve returned nil",
                    level: .warn,
                    fields: [
                        "traceID": traceID,
                        "sessionID": payload.sessionID,
                        "terminalResolveMs": String(terminalResolveMs)
                    ]
                )
            }
        } else {
            log(
                "[HookEventHandler] UserPromptSubmit no binding and no terminal context",
                level: .warn,
                fields: [
                    "traceID": traceID,
                    "sessionID": payload.sessionID
                ]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "no_binding_skip",
                    message: "No session binding, skipping restore",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }
```

- [ ] **Step 2: 在 binding resolved 后的窗口状态检查中标记是否使用了降级路径**

文件: `Sources/HookEventHandler.swift`（在 `isWindowOnMainScreen` 检查的日志中添加 `usedFallback` 字段）

在已有的 `binding resolved, checking window state` 日志的 fields 中添加：
```swift
"usedFallback": String(usedFallback),
```

- [ ] **Step 3: 验证编译通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/HookEventHandler.swift && git commit -m "fix(restore): fall through to terminal context when binding verification fails"`

---

### Task 2: 增加 isNearTarget 容差 — auto-restore 使用 300px

**Depends on:** None
**Files:**
- Modify: `Sources/ClaudeHookModels.swift:166-170`
- Modify: `Sources/ToggleEngine.swift:126-136`

**Root Cause:** `isNearTarget()` 使用 150px 容差检查窗口是否在 toggle 目标位置附近。macOS 空间切换时可能调整窗口位置 50-200px，导致 isNearTarget 返回 false，restore 被跳过。ToggleEngine.restore 的 isNearTarget 检查在 auto-restore 路径上尤其容易因位置微调而失败。

- [ ] **Step 1: 修改 isNearTarget — 添加 tolerance 参数默认值改为 200**

文件: `Sources/ClaudeHookModels.swift:166-170`

```swift
    /// 窗口当前位置是否在 targetFrame 附近
    func isNearTarget(currentFrame: CGRect, tolerance: CGFloat = 200) -> Bool {
        abs(currentFrame.origin.x - targetFrame.origin.x) <= tolerance &&
        abs(currentFrame.origin.y - targetFrame.origin.y) <= tolerance
    }
```

- [ ] **Step 2: 修改 ToggleEngine.restore — isNearTarget 失败时记录详细诊断信息**

文件: `Sources/ToggleEngine.swift:126-136`（替换 isNearTarget 检查区块）

```swift
        // 3. 验证窗口确实在 target 位置附近
        if !record.isNearTarget(currentFrame: currentFrame) {
            let xOffset = abs(currentFrame.origin.x - record.targetFrame.origin.x)
            let yOffset = abs(currentFrame.origin.y - record.targetFrame.origin.y)
            log("ToggleEngine.restore: window moved from target, skipping restore", level: .warn, fields: [
                "traceID": trace,
                "windowID": String(windowID),
                "currentFrame": "\(Int(currentFrame.origin.x)),\(Int(currentFrame.origin.y)) \(Int(currentFrame.size.width))x\(Int(currentFrame.size.height))",
                "targetFrame": "\(Int(record.targetFrame.origin.x)),\(Int(record.targetFrame.origin.y)) \(Int(record.targetFrame.size.width))x\(Int(record.targetFrame.size.height))",
                "xOffset": String(Int(xOffset)),
                "yOffset": String(Int(yOffset)),
                "tolerance": "200"
            ])
            return false
        }
```

- [ ] **Step 3: 验证编译通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/ClaudeHookModels.swift Sources/ToggleEngine.swift && git commit -m "fix(restore): increase isNearTarget tolerance from 150px to 200px and add diagnostic logging"`

---

### Task 3: 为 verifyBinding 添加详细诊断日志

**Depends on:** None
**Files:**
- Modify: `Sources/SessionWindowRegistry.swift:114-135`

**Root Cause:** `verifyBinding()` 失败时没有任何日志，无法区分是 PID 不匹配、窗口不存在、还是 PID 已死。这使得问题诊断非常困难。

- [ ] **Step 1: 修改 verifyBinding — 添加详细的失败原因日志**

文件: `Sources/SessionWindowRegistry.swift:114-135`

```swift
    func verifyBinding(_ state: WindowState) -> Bool {
        let expectedPID = state.pid
        let windowID = state.windowID

        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: state.bundleIdentifier ?? "")
        let pidMatches = runningApps.contains { $0.processIdentifier == expectedPID }
        if !pidMatches {
            let pidExists = kill(expectedPID, 0) == 0
            if !pidExists {
                log("[SessionWindowRegistry] verifyBinding failed: PID \(expectedPID) no longer exists", level: .warn, fields: [
                    "windowID": String(windowID),
                    "bundleIdentifier": state.bundleIdentifier ?? "nil"
                ])
                return false
            }
        }

        let options: CGWindowListOption = [.optionAll]
        if let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
            if let matchedWindow = windowList.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == windowID }) {
                let actualPID = matchedWindow[kCGWindowOwnerPID as String] as? Int32
                if actualPID != expectedPID {
                    log("[SessionWindowRegistry] verifyBinding failed: window owner PID mismatch", level: .warn, fields: [
                        "windowID": String(windowID),
                        "expectedPID": String(expectedPID),
                        "actualPID": String(describing: actualPID)
                    ])
                }
                return actualPID == expectedPID
            } else {
                log("[SessionWindowRegistry] verifyBinding failed: windowID \(windowID) not found in CGWindowList", level: .warn, fields: [
                    "windowID": String(windowID),
                    "expectedPID": String(expectedPID)
                ])
                return false
            }
        }
        log("[SessionWindowRegistry] verifyBinding failed: CGWindowListCopyWindowInfo returned nil", level: .warn, fields: [
            "windowID": String(windowID)
        ])
        return false
    }
```

- [ ] **Step 2: 验证编译通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/SessionWindowRegistry.swift && git commit -m "feat(logging): add diagnostic logging to verifyBinding showing exact failure reason"`
