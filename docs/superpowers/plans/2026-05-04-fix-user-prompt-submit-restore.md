# Fix: UserPromptSubmit Auto-Restore Not Working

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** Fix UserPromptSubmit auto-restore so pressing Enter in Claude Code reliably restores the window to the secondary screen.

**Architecture:** Root cause analysis shows 3 issues: (1) stale saved states referencing non-existent windows, (2) handler only matches by exact windowID with no fallback for window recreation, (3) running old binary. Fix adds stale state cleanup on startup and a robust app-level fallback when windowID match fails.

**Tech Stack:** Swift 5, macOS Accessibility API, GCDWebServer

**Risks:**
- Modifying restore fallback logic could affect hotkey toggle behavior → 缓解: fallback 仅在 hook handler 中使用，不影响 hotkey 路径
- Stale state cleanup 可能在边缘情况误删有效 state → 缓解: 仅删除 CGWindowList 中确认不存在的窗口

---

### Task 1: Clean up stale saved states on startup

**Depends on:** None
**Files:**
- Modify: `Sources/WindowManager.swift:95-98`（init 中加载 saved states 之后）

- [ ] **Step 1: 添加 stale state 清理函数 — 删除引用不存在窗口的 saved states**

文件: `Sources/WindowManager.swift`（在 `loadSavedWindowStates()` 调用之后添加清理逻辑）

```swift
// 在 init() 中 savedWindowStates = loadSavedWindowStates() 之后添加:
        cleanupStaleSavedStates()
```

- [ ] **Step 2: 实现 cleanupStaleSavedStates 函数**

文件: `Sources/WindowManager.swift`（在 `cleanupExpiredSavedStates()` 函数附近添加）

```swift
    /// 清理引用已不存在窗口的 saved states
    /// 窗口 ID 在 app 重启、Terminal 重启等场景下会变化
    /// 这些 stale states 会导致 restore 匹配失败
    private func cleanupStaleSavedStates() {
        let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        let existingWindowIDs = Set(windowList.compactMap { $0["kCGWindowNumber"] as? UInt32 })

        let before = savedWindowStates.count
        savedWindowStates.removeAll { state in
            guard let wid = state.windowID else { return false }
            let isStale = !existingWindowIDs.contains(wid)
            if isStale {
                log(
                    "[WindowManager] cleaning stale saved state: windowID \(wid) no longer exists",
                    level: .debug,
                    fields: [
                        "stateID": state.id,
                        "app": state.appName ?? "unknown"
                    ]
                )
            }
            return isStale
        }
        let removed = before - savedWindowStates.count
        if removed > 0 {
            persistSavedWindowStates()
            log(
                "[WindowManager] cleaned up \(removed) stale saved state(s), \(savedWindowStates.count) remaining"
            )
        }
    }
```

- [ ] **Step 3: 验证编译**
Run: `swift build -c release 2>&1 | grep -E "error:|Build complete"`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/WindowManager.swift && git commit -m "fix(state): clean up stale saved states referencing non-existent windows on startup"`

---

### Task 2: Add app-level window restore fallback in UserPromptSubmit handler

**Depends on:** None
**Files:**
- Modify: `Sources/ClaudeHookServer.swift:535-560`（handleUserPromptSubmit 的 binding fallback 区域）

- [ ] **Step 1: 添加 isWindowOnMainScreen 检查和 app-level restore fallback**

当 binding 精确匹配和 windowID-only 匹配都失败后，如果 bound window 在主屏上，查找同 app 的任何 saved state（含 stale），或直接构造 restore 操作移到副屏。

文件: `Sources/ClaudeHookServer.swift`（替换 handleUserPromptSubmit 中的 shouldRestoreCurrentWindow fallback 区域，约 line 535-560）

将现有的 `shouldRestoreCurrentWindow()` fallback 替换为更智能的逻辑：

```swift
            // 优先级 3: 检查窗口是否在主屏，尝试用同 app 的任意 saved state 恢复
            let isOnMain = wm.isWindowOnMainScreen(windowID: targetWindowID)
            log(
                "[ClaudeHookServer] UserPromptSubmit exact/windowID match failed, trying app-level fallback",
                fields: [
                    "sessionID": payload.sessionID,
                    "bindingWindowID": String(targetWindowID),
                    "windowOnMain": String(isOnMain),
                    "savedStatesCount": String(wm.savedWindowStates.count)
                ]
            )

            if isOnMain {
                // 窗口在主屏 → 尝试 any saved state for same app
                if let appState = wm.savedWindowStates.reversed().first(where: { state in
                    state.appName == binding.windowIdentity.appName
                        && !wm.isSavedStateCorrupted(state)
                }) {
                    log(
                        "[ClaudeHookServer] UserPromptSubmit app-level fallback: using saved state from same app",
                        fields: [
                            "sessionID": payload.sessionID,
                            "stateApp": appState.appName ?? "unknown",
                            "stateWindowID": String(describing: appState.windowID),
                            "bindingWindowID": String(targetWindowID)
                        ]
                    )
                    return performRestore(
                        payload: payload, matchedState: appState,
                        matchLevel: "app_level_fallback"
                    )
                }

                // 没有 saved state 但窗口在主屏 → 构造一个即时 restore
                // 将窗口移到副屏的默认位置
                log(
                    "[ClaudeHookServer] UserPromptSubmit constructing immediate restore to secondary screen",
                    fields: [
                        "sessionID": payload.sessionID,
                        "bindingWindowID": String(targetWindowID)
                    ]
                )
                return performDirectSecondaryRestore(
                    payload: payload,
                    binding: binding
                )
            }

            // 最后尝试通用 shouldRestoreCurrentWindow
            if wm.shouldRestoreCurrentWindow() {
                wm.restore(
                    operationID: makeOperationID(prefix: "hook-restore-generic"),
                    triggerSource: "user_prompt_submit_generic"
                )
                handledRequestCount += 1
                return (
                    200,
                    ClaudeHookResponse(
                        ok: true, code: "window_restored_generic",
                        message: "Window restored via generic path",
                        sessionID: payload.sessionID, handled: true
                    )
                )
            }
```

- [ ] **Step 2: 实现 performDirectSecondaryRestore — 无 saved state 时直接移回副屏**

文件: `Sources/ClaudeHookServer.swift`（在 `performRestore` 函数之后添加）

```swift
    /// 无 saved state 时，直接将 binding 的窗口移到副屏
    private func performDirectSecondaryRestore(
        payload: ClaudeHookPayload,
        binding: SessionWindowBinding
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        let wm = WindowManager.shared

        // 找到副屏
        guard let secondaryScreen = NSScreen.screens.first(where: { !$0.isMainScreen }) else {
            log(
                "[ClaudeHookServer] no secondary screen found for direct restore",
                level: .warn,
                fields: ["sessionID": payload.sessionID]
            )
            return (
                404,
                ClaudeHookResponse(
                    ok: false, code: "no_secondary_screen",
                    message: "No secondary screen available",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        let targetFrame = secondaryScreen.visibleFrame
        let identity = binding.windowIdentity

        log(
            "[ClaudeHookServer] performing direct secondary restore",
            fields: [
                "sessionID": payload.sessionID,
                "windowID": String(identity.windowID),
                "app": identity.appName ?? "unknown",
                "targetFrame": String(describing: targetFrame)
            ]
        )

        // 构造一个 saved state 用于 hydrateMemory + restore
        let currentFrame = wm.getCurrentWindowFrame(windowID: identity.windowID) ?? targetFrame
        let syntheticState = WindowManager.SavedWindowState(
            id: UUID().uuidString,
            pid: identity.pid,
            bundleIdentifier: identity.bundleIdentifier,
            appName: identity.appName,
            windowID: identity.windowID,
            windowNumber: identity.windowNumber,
            title: identity.title,
            originalFrame: WindowManager.RectPayload(targetFrame),
            targetFrame: WindowManager.RectPayload(currentFrame),
            sourceSpaceIndex: nil,
            targetSpaceIndex: nil,
            sourceYabaiDisplayIndex: nil,
            sourceDisplaySpaceIndex: nil,
            sourceDisplayIndex: nil,
            sourceDisplayID: nil,
            targetDisplayIndex: nil,
            restoreReason: "direct_secondary_restore",
            sessionID: payload.sessionID,
            savedAt: Date()
        )

        wm.hydrateMemory(from: syntheticState, window: nil)
        wm.restore(
            operationID: makeOperationID(prefix: "hook-direct-restore"),
            triggerSource: "user_prompt_submit_direct"
        )

        SessionWindowRegistry.shared.reactivate(sessionID: payload.sessionID)
        handledRequestCount += 1
        SessionWindowRegistry.shared.setLastEventDescription(
            "UserPromptSubmit 直接恢复：\(identity.appName ?? "Unknown") → 副屏"
        )
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "window_restored_direct",
                message: "Window restored directly to secondary screen",
                sessionID: payload.sessionID, handled: true
            )
        )
    }
```

- [ ] **Step 3: 验证编译**
Run: `swift build -c release 2>&1 | grep -E "error:|Build complete"`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/ClaudeHookServer.swift && git commit -m "fix(hook): add app-level and direct secondary restore fallback for UserPromptSubmit"`

---

### Task 3: Add getCurrentWindowFrame helper and deploy

**Depends on:** Task 2
**Files:**
- Modify: `Sources/WindowManager.swift` or `Sources/WindowManagerSupport.swift`（添加 helper）
- Modify: `Sources/WindowManagerSupport.swift`（RectPayload init 和 SavedWindowState 可能需要调整）

- [ ] **Step 1: 检查是否已有 getCurrentWindowFrame 或类似函数**

Run: `grep -rn "getCurrentWindowFrame\|func.*windowFrame\|func.*frame.*windowID" /Users/cc11001100/github/vibe-coding-labs/vibe-focus/Sources/ | head -10`

如果没有，需要在 WindowManager 中添加：

```swift
    /// 通过 CGWindowList 获取指定 windowID 的当前 frame
    func getCurrentWindowFrame(windowID: UInt32) -> CGRect? {
        let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {
            if let wid = w["kCGWindowNumber"] as? UInt32, wid == windowID {
                if let bounds = w["kCGWindowBounds"] as? [String: Double] {
                    return CGRect(
                        x: bounds["X"] ?? 0,
                        y: bounds["Y"] ?? 0,
                        width: bounds["Width"] ?? 0,
                        height: bounds["Height"] ?? 0
                    )
                }
            }
        }
        return nil
    }
```

- [ ] **Step 2: 检查 SavedWindowState init 是否允许 nil sourceDisplayIndex 等可选字段**

Run: `grep -n "let sourceDisplayIndex" /Users/cc11001100/github/vibe-coding-labs/vibe-focus/Sources/WindowManager.swift | head -3`

如果这些字段不是 Optional，需要改为 Optional 或提供默认值。

- [ ] **Step 3: 构建并部署**

Run: `bash scripts/dev-build.sh 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "构建成功"

- [ ] **Step 4: 端到端验证 — 模拟完整 UserPromptSubmit 流程**

Run: `sleep 3 && pgrep -lf VibeFocus`
Expected:
  - New PID running from `/Applications/VibeFocus.app`

- [ ] **Step 5: 提交**
Run: `git add -A && git commit -m "feat(wm): add getCurrentWindowFrame helper for direct window position query"`
