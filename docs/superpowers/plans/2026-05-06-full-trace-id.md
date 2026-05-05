# 全链路 Trace ID 日志完善 Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 给 VibeFocus 的 restore/toggle 完整链路添加唯一 trace ID（`tid`），使一次用户操作（快捷键 toggle / 提交 prompt restore）的所有日志可以通过一个 ID 在 `vibefocus-events.jsonl` 中一次性过滤出来。同时为 HookEventHandler 的 restore 路径添加耗时打点，诊断"提交后卡顿"的根因。

**Architecture:** 触发源（HotKeyManager / HookEventHandler）→ 生成 traceID → 传递给 WindowManager.toggle / ToggleEngine.restore → 内部所有 log 调用携带 `traceID` 字段 → 结构化 JSON 日志中可通过 `jq 'select(.fields.traceID=="xxx")'` 一次性检索。关键改动：1) HookEventHandler 在调用 restore 前生成 traceID 并传递；2) ToggleEngine.restore 和 WindowManager.restore 接受 traceID 参数，所有内部 log 携带此字段；3) ToggleEngine.switchToOriginalSpace 接受并传递 traceID。

**Tech Stack:** Swift 5.9, macOS Accessibility API, SQLite, NSJSONSerialization

**Risks:**
- Task 2 修改 ToggleEngine 核心方法签名，影响所有调用方 → 缓解：`traceID` 参数默认值为 `nil`，不破坏现有调用
- Task 3 修改 HookEventHandler，这是 HTTP handler，需要确保 traceID 在最早时机生成 → 缓解：在方法入口第一行生成

---

### Task 1: HookEventHandler 添加 traceID 和耗时打点日志

**Depends on:** None
**Files:**
- Modify: `Sources/HookEventHandler.swift:96-260`（handleUserPromptSubmit 方法）

- [ ] **Step 1: 修改 handleUserPromptSubmit 添加 traceID 生成和耗时打点**

文件: `Sources/HookEventHandler.swift:96-260`（替换整个 handleUserPromptSubmit 方法体中 restore 分支）

在 `handleUserPromptSubmit` 方法开头（line 96 之后），添加 traceID 生成：

```swift
    func handleUserPromptSubmit(payload: ClaudeHookPayload) -> (Int, ClaudeHookResponse) {
        let traceID = makeOperationID(prefix: "ups")
        let handleStartedAt = Date()
        lastActivityBySession[payload.sessionID] = Date()

        log(
            "[HookEventHandler] UserPromptSubmit triggered",
            fields: [
                "traceID": traceID,
                "sessionID": payload.sessionID,
                "autoRestoreEnabled": String(ClaudeHookPreferences.autoRestoreOnPromptSubmit),
                "cwd": payload.cwd ?? "nil"
            ]
        )
```

然后替换 line 127-260 的窗口查找 + restore 分支，在所有关键节点添加 traceID 和耗时打点：

```swift
        // 通过 sessionID 找到窗口状态
        let state = SessionWindowRegistry.shared.binding(for: payload.sessionID)
        let identity: WindowIdentity?

        if let state {
            guard SessionWindowRegistry.shared.verifyBinding(state) else {
                log(
                    "[HookEventHandler] UserPromptSubmit binding verification failed",
                    level: .warn,
                    fields: [
                        "traceID": traceID,
                        "sessionID": payload.sessionID,
                        "pid": String(state.pid),
                        "tty": state.tty ?? "nil"
                    ]
                )
                return (
                    200,
                    ClaudeHookResponse(
                        ok: true, code: "binding_verification_failed",
                        message: "Binding verification failed, skipping restore",
                        sessionID: payload.sessionID, handled: false
                    )
                )
            }
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

        guard let identity else {
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "no_binding_skip",
                    message: "Could not resolve window identity",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        let wm = WindowManager.shared
        let isOnMain = wm.isWindowOnMainScreen(windowID: identity.windowID)

        guard isOnMain else {
            log(
                "[HookEventHandler] UserPromptSubmit window not on main screen",
                fields: [
                    "traceID": traceID,
                    "sessionID": payload.sessionID,
                    "windowID": String(identity.windowID)
                ]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "no_action_needed",
                    message: "Window not on main screen",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 新路径：ToggleEngine 直接查 SQLite，不走内存缓存
        let engine = ToggleEngine.shared
        if let record = engine.load(windowID: identity.windowID) {
            guard let mainScreen = wm.getMainScreen() else {
                return (200, ClaudeHookResponse(ok: true, code: "no_main_screen", message: "No main screen", sessionID: payload.sessionID, handled: false))
            }

            if record.isValid(mainScreenFrame: mainScreen.frame) {
                let restoreStart = Date()
                log(
                    "[HookEventHandler] UserPromptSubmit calling ToggleEngine.restore",
                    level: .info,
                    fields: [
                        "traceID": traceID,
                        "windowID": String(identity.windowID),
                        "preRestoreMs": String(elapsedMilliseconds(since: handleStartedAt))
                    ]
                )
                let success = engine.restore(
                    windowID: identity.windowID,
                    triggerSource: "user_prompt_submit",
                    traceID: traceID
                )
                let restoreMs = elapsedMilliseconds(since: restoreStart)
                log(
                    "[HookEventHandler] UserPromptSubmit restore completed",
                    level: success ? .info : .warn,
                    fields: [
                        "traceID": traceID,
                        "success": String(success),
                        "restoreMs": String(restoreMs),
                        "totalMs": String(elapsedMilliseconds(since: handleStartedAt))
                    ]
                )
                if success {
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
                } else {
                    return (
                        200,
                        ClaudeHookResponse(
                            ok: true,
                            code: "restore_failed",
                            message: "Restore attempt failed",
                            sessionID: payload.sessionID,
                            handled: false
                        )
                    )
                }
            } else {
                // corrupted state（两个 frame 都在主屏），清除
                engine.clear(windowID: identity.windowID)
                log(
                    "[HookEventHandler] UserPromptSubmit toggle record corrupted, cleared",
                    level: .warn,
                    fields: [
                        "traceID": traceID,
                        "windowID": String(identity.windowID)
                    ]
                )
            }
        }
```

接下来是 fallback 到 WindowManager.restore 的部分（line 260 之后），也需要传递 traceID：

```swift
        // Fallback: 没有有效 toggle record，走 WindowManager.restore
        log(
            "[HookEventHandler] UserPromptSubmit no toggle record, falling back to WindowManager.restore",
            fields: [
                "traceID": traceID,
                "sessionID": payload.sessionID,
                "windowID": String(identity.windowID)
            ]
        )
        let fallbackStart = Date()
        wm.restore(operationID: traceID, triggerSource: "user_prompt_submit")
        let fallbackMs = elapsedMilliseconds(since: fallbackStart)
        logOperationDuration(
            "[HookEventHandler] UserPromptSubmit WindowManager.restore fallback",
            startedAt: handleStartedAt,
            operationID: traceID,
            warnThresholdMs: 500,
            fields: [
                "fallbackRestoreMs": String(fallbackMs),
                "totalMs": String(elapsedMilliseconds(since: handleStartedAt))
            ]
        )
        return (
            200,
            ClaudeHookResponse(
                ok: true,
                code: "restore_fallback",
                message: "Restore attempted via WindowManager fallback",
                sessionID: payload.sessionID,
                handled: true
            )
        )
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -10`
Expected:
  - Exit code: 0 或编译错误（因为 ToggleEngine.restore 签名还未更新）
  - 如果报错 "extra argument 'traceID'"，说明 Task 2 需要先完成

- [ ] **Step 3: 提交**
Run: `git add Sources/HookEventHandler.swift && git commit -m "feat(log): add traceID and duration markers to handleUserPromptSubmit"`

---

### Task 2: ToggleEngine 添加 traceID 参数

**Depends on:** Task 1
**Files:**
- Modify: `Sources/ToggleEngine.swift:85-148`（restore 方法）
- Modify: `Sources/ToggleEngine.swift:154-232`（switchToOriginalSpace 方法）

- [ ] **Step 1: 修改 ToggleEngine.restore 添加 traceID 参数**

文件: `Sources/ToggleEngine.swift:85-148`（替换 restore 方法签名和内部 log 调用）

```swift
    @discardableResult
    func restore(windowID: UInt32, triggerSource: String, traceID: String? = nil) -> Bool {
        let trace = traceID ?? makeOperationID(prefix: "te")
        guard let record = load(windowID: windowID) else {
            log("ToggleEngine.restore: no toggle record found", level: .warn, fields: [
                "traceID": trace,
                "windowID": String(windowID)
            ])
            return false
        }

        log("ToggleEngine.restore: starting", level: .info, fields: [
            "traceID": trace,
            "windowID": String(windowID),
            "sourceSpace": String(record.sourceSpace),
            "sourceDisplay": String(record.sourceDisplay),
            "sourceYabaiDisp": String(record.sourceYabaiDisp),
            "sourceDispSpace": String(record.sourceDispSpace),
            "triggerSource": triggerSource
        ])

        let wm = WindowManager.shared

        // 1. 找到窗口 AX element
        guard let windowAX = wm.findWindowByPID(record.pid, windowID: record.windowID) else {
            log("ToggleEngine.restore: window AX element not found", level: .warn, fields: [
                "traceID": trace,
                "windowID": String(windowID),
                "pid": String(record.pid)
            ])
            return false
        }

        // 2. 获取当前 frame（验证用）
        guard let currentFrame = wm.frame(of: windowAX) else {
            log("ToggleEngine.restore: cannot get current frame", level: .warn, fields: [
                "traceID": trace
            ])
            return false
        }

        // 3. 验证窗口确实在 target 位置附近
        if !record.isNearTarget(currentFrame: currentFrame) {
            log("ToggleEngine.restore: window moved from target, skipping restore", level: .warn, fields: [
                "traceID": trace,
                "windowID": String(windowID),
                "currentX": String(Int(currentFrame.origin.x)),
                "currentY": String(Int(currentFrame.origin.y)),
                "targetX": String(Int(record.targetFrame.origin.x)),
                "targetY": String(Int(record.targetFrame.origin.y))
            ])
            return false
        }

        // 4. 先切换到原始 space
        switchToOriginalSpace(record: record, windowAX: windowAX, triggerSource: triggerSource, traceID: trace)

        // 5. 切换完成后重新获取 AX element
        let restoreAX = wm.findWindowByPID(record.pid, windowID: record.windowID) ?? windowAX

        // 6. 设置恢复 frame
        let restored = wm.apply(frame: record.origFrame, to: restoreAX, operationID: trace, stage: "restore_orig")
        if !restored {
            log("ToggleEngine.restore: frame apply failed", level: .error, fields: [
                "traceID": trace
            ])
        }

        log("ToggleEngine.restore: success", level: .info, fields: [
            "traceID": trace,
            "windowID": String(windowID),
            "restoredTo": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y))"
        ])
        return true
    }
```

- [ ] **Step 2: 修改 switchToOriginalSpace 添加 traceID 参数**

文件: `Sources/ToggleEngine.swift:154-232`（替换 switchToOriginalSpace 方法）

```swift
    private func switchToOriginalSpace(record: ToggleRecord, windowAX: AXUIElement, triggerSource: String, traceID: String) {
        let spaceController = SpaceController.shared
        let targetSpace = record.sourceSpace
        let targetDisplay = record.sourceYabaiDisp

        let displayCurrentSpace = spaceController.displayVisibleSpace(displayIndex: targetDisplay)

        log("ToggleEngine.switchToOriginalSpace: space check", fields: [
            "traceID": traceID,
            "targetSpace": String(targetSpace),
            "targetDisplay": String(describing: targetDisplay),
            "displayCurrentSpace": String(describing: displayCurrentSpace),
            "triggerSource": triggerSource
        ])

        if let current = displayCurrentSpace, current == targetSpace {
            log("ToggleEngine.switchToOriginalSpace: target display already on correct space, skipping switch", fields: [
                "traceID": traceID,
                "space": String(targetSpace)
            ])
            _ = spaceController.moveWindow(
                record.windowID,
                toSpaceIndex: targetSpace,
                focus: false,
                operationID: traceID
            )
            return
        }

        log("ToggleEngine.switchToOriginalSpace: need space switch", fields: [
            "traceID": traceID,
            "displayCurrentSpace": String(describing: displayCurrentSpace),
            "targetSpace": String(targetSpace),
            "targetDisplay": String(describing: targetDisplay),
            "sourceYabaiDisp": String(record.sourceYabaiDisp)
        ])

        if let current = displayCurrentSpace, current != targetSpace {
            let switchStart = Date()
            let switched = spaceController.switchDisplayToSpace(
                targetSpace: targetSpace,
                operationID: traceID
            )
            log("ToggleEngine.switchToOriginalSpace: switchDisplayToSpace result", fields: [
                "traceID": traceID,
                "switched": String(switched),
                "targetSpace": String(targetSpace),
                "switchDisplayMs": String(elapsedMilliseconds(since: switchStart))
            ])
            if switched {
                let td = targetDisplay
                let started = Date()
                while Date().timeIntervalSince(started) < 0.4 {
                    if spaceController.displayVisibleSpace(displayIndex: td) == targetSpace { break }
                    usleep(30_000)
                }
            }
        }

        let moveStart = Date()
        let moved = spaceController.moveWindow(
            record.windowID,
            toSpaceIndex: targetSpace,
            focus: triggerSource == "carbon_hotkey",
            operationID: traceID
        )
        log("ToggleEngine.switchToOriginalSpace: moveWindow result", fields: [
            "traceID": traceID,
            "moved": String(moved),
            "moveWindowMs": String(elapsedMilliseconds(since: moveStart))
        ])

        if moved {
            let started = Date()
            while Date().timeIntervalSince(started) < 0.2 {
                if let s = spaceController.windowSpaceIndex(windowID: record.windowID), s == targetSpace { break }
                usleep(20_000)
            }
        } else {
            log("ToggleEngine.switchToOriginalSpace: moveWindow also failed after display switch", level: .warn, fields: [
                "traceID": traceID,
                "windowID": String(record.windowID),
                "targetSpace": String(targetSpace)
            ])
        }
    }
```

- [ ] **Step 3: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/ToggleEngine.swift && git commit -m "feat(log): add traceID parameter to ToggleEngine.restore and switchToOriginalSpace"`

---

### Task 3: WindowManager.restore 添加 traceID 传递

**Depends on:** Task 2
**Files:**
- Modify: `Sources/WindowManager.swift:340-560`（restore 方法，添加 traceID 到所有内部 log）

- [ ] **Step 1: 修改 WindowManager.restore 的入口日志添加 traceID 说明**

WindowManager.restore 已经通过 `operationID` 参数传递了操作 ID（格式 `restore-00000042`），并且所有内部 log 都携带 `"op"` 字段。这个 `op` 已经等同于 traceID 的功能。

需要做的唯一修改是：确保 HookEventHandler 调用 `wm.restore(operationID: traceID)` 时，traceID 格式为 `ups-XXXXXXXX`，这样所有 WindowManager.restore 内部的 log 都自然带有这个 traceID。

这一步**不需要额外代码修改**，因为 Task 1 的 Step 1 已经在 fallback 路径中使用了 `wm.restore(operationID: traceID)`。

- [ ] **Step 2: 验证 — 确认 HookEventHandler 的 traceID 能流经完整路径**

确认以下调用链的 traceID 流通：

```
HookEventHandler.handleUserPromptSubmit
  → traceID = makeOperationID(prefix: "ups")   // ups-00000042
  → engine.restore(traceID: traceID)           // ToggleEngine 传递
    → switchToOriginalSpace(traceID: traceID)  // 内部传递
    → wm.apply(operationID: traceID)           // AX apply
  → wm.restore(operationID: traceID)           // fallback 路径
```

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 部署并验证日志**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && bash scripts/dev-build.sh 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "构建成功"

Run: `pkill -x VibeFocus; sleep 0.3; open /Applications/VibeFocus.app`
Expected:
  - VibeFocus app 启动

验证日志中 traceID 字段：
Run: `sleep 3; tail -5 ~/Library/Logs/VibeFocus/vibefocus-events.jsonl | python3 -m json.tool 2>/dev/null | grep -c "traceID" || echo "waiting for trace logs"`
Expected:
  - 数字 > 0 或 "waiting for trace logs"（如果还没有触发 restore 操作）

- [ ] **Step 4: 提交**
Run: `git add -A && git commit -m "feat(log): full traceID propagation through restore pipeline"`
