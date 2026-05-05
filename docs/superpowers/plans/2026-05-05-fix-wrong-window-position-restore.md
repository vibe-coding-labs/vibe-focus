# Fix: Windows 表保存错误数据导致窗口错位

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复多个代码路径中窗口身份验证不足导致错误窗口被移动到不属于自己位置的问题。核心缺陷是 `findStateByWindowID` 不验证 PID、`updateToggleState` tty=nil 时选错行、以及 restore 路径缺少窗口位置一致性校验。

**Architecture:** 三层防御：数据层（findStateByWindowID 加 PID 验证）→ 匹配层（updateToggleState 加 windowID 精确匹配）→ 恢复层（restore 前验证窗口当前位置 vs targetFrame 一致性）。每层独立生效，即使某层被绕过，下一层仍能拦截。

**Tech Stack:** Swift 5.9, macOS 13+, SQLite (via Csqlite3), AX API, CGWindowList API

**Risks:**
- Task 1 修改 findStateByWindowID 加 PID 参数，所有调用点需要传 PID → 缓解：逐一检查调用点，补充 PID 参数
- Task 2 修改 updateToggleState 匹配逻辑，可能影响热键 toggle 流程 → 缓解：保留现有 first-where 逻辑作为 fallback
- Task 3 添加 restore 前位置校验，可能误拒合法恢复 → 缓解：使用 100px 容差，只检查窗口是否在 targetFrame 附近

---

### Task 1: 修复 findStateByWindowID 缺少 PID 验证

**Depends on:** None
**Files:**
- Modify: `Sources/SessionWindowRegistry.swift:232-244` (findStateByWindowID)
- Modify: `Sources/WindowManager.swift:858` (shouldRestoreCurrentWindow 调用点)
- Modify: `Sources/HookEventHandler.swift:237` (handleUserPromptSubmit 调用点)

`findStateByWindowID` 只按 windowID 查找，不验证 PID。macOS 的 CGWindowNumber 可跨进程复用，导致返回错误进程的 WindowState，把窗口 A 移动到窗口 B 的坐标。

- [ ] **Step 1: 修改 findStateByWindowID 添加可选 PID 验证参数**

文件: `Sources/SessionWindowRegistry.swift:232-244`（替换整个 findStateByWindowID 函数）

```swift
    /// 按 windowID 查找窗口状态，可选 PID 验证防止跨进程误匹配
    func findStateByWindowID(_ windowID: UInt32, expectedPID: Int32? = nil) -> WindowState? {
        let candidates = windowStates.values.filter { $0.windowID == windowID }
        if let pid = expectedPID {
            if let state = candidates.first(where: { $0.pid == pid }) {
                return state
            }
            if let state = WindowStateStore.shared.findWindowStateByWindowID(windowID), state.pid == pid {
                let key = cacheKey(pid: state.pid, tty: state.tty)
                windowStates[key] = state
                return state
            }
        } else {
            if let state = candidates.first {
                return state
            }
            if let state = WindowStateStore.shared.findWindowStateByWindowID(windowID) {
                let key = cacheKey(pid: state.pid, tty: state.tty)
                windowStates[key] = state
                return state
            }
        }
        return nil
    }
```

- [ ] **Step 2: 修改 shouldRestoreCurrentWindow 传递当前窗口 PID**

文件: `Sources/WindowManager.swift:858`（替换 findStateByWindowID 调用）

```swift
        if let wsState = SessionWindowRegistry.shared.findStateByWindowID(currentWindowID, expectedPID: frontApp.processIdentifier) {
```

- [ ] **Step 3: 修改 handleUserPromptSubmit 传递 identity PID**

文件: `Sources/HookEventHandler.swift:237`（替换 findStateByWindowID 调用）

```swift
        if let windowState = SessionWindowRegistry.shared.findStateByWindowID(identity.windowID, expectedPID: identity.pid) {
```

- [ ] **Step 4: 验证编译**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 5: 提交**
Run: `git add Sources/SessionWindowRegistry.swift Sources/WindowManager.swift Sources/HookEventHandler.swift && git commit -m "fix(restore): add PID validation to findStateByWindowID to prevent cross-process window mismatch"`

---

### Task 2: 修复 updateToggleState tty=nil 时选错行的 bug

**Depends on:** Task 1
**Files:**
- Modify: `Sources/SessionWindowRegistry.swift:167-211` (updateToggleState)

当 tty=nil 时（Ctrl+Q 热键触发），`updateToggleState` 通过 `first(where:)` 查找同 PID 的行。如果同 PID 有多个行（不同 tty），优先选有 sessionID 的行，但可能选到错误 session 的行。应该在 sessionID 优先的基础上，额外匹配 windowID。

- [ ] **Step 1: 修改 updateToggleState 的 tty=nil 匹配逻辑 — 增加 windowID 精确匹配**

文件: `Sources/SessionWindowRegistry.swift:169-181`（替换 key 解析逻辑块）

```swift
        let key: String
        if let tty, !tty.isEmpty {
            key = cacheKey(pid: pid, tty: tty)
        } else {
            // tty 为空 — 多级匹配：windowID 精确匹配 > 有 session 的行 > 任意行
            let windowIDToMatch = WindowManager.shared.focusedWindow(for: pid).flatMap { WindowManager.shared.windowHandle(for: $0) }
            let existingKey: String? = nil
            // 优先按 windowID 精确匹配
            let windowIDMatch = windowStates.keys.first(where: { k in
                k.hasPrefix("\(pid)_") && windowStates[k]?.windowID == windowIDToMatch
            })
            // 其次按有 sessionID 的行
            let sessionMatch = windowStates.keys.first(where: { k in
                k.hasPrefix("\(pid)_") && windowStates[k]?.sessionID != nil
            })
            // 最后任意行
            let anyMatch = windowStates.keys.first(where: { k in
                k.hasPrefix("\(pid)_")
            })
            key = windowIDMatch ?? sessionMatch ?? anyMatch ?? cacheKey(pid: pid, tty: nil)
        }
```

- [ ] **Step 2: 验证编译**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 3: 提交**
Run: `git add Sources/SessionWindowRegistry.swift && git commit -m "fix(toggle): add windowID-based matching in updateToggleState when tty is nil"`

---

### Task 3: 恢复路径添加窗口位置合理性校验

**Depends on:** Task 1
**Files:**
- Modify: `Sources/ClaudeHookModels.swift:106-112` (isCorrupted)
- Modify: `Sources/WindowManager.swift:800-907` (shouldRestoreCurrentWindow)
- Modify: `Sources/HookEventHandler.swift:274-343` (performRestoreFromState)

恢复路径缺少一个关键检查：restore 应该只恢复当前在 targetFrame 附近的窗口。如果窗口已被用户手动移动到其他位置，不应该被自动 restore。同时在 performRestoreFromState 中添加 AX 元素验证，确保恢复的是正确的窗口。

- [ ] **Step 1: 在 WindowState 添加 isNearTarget 验证方法**

文件: `Sources/ClaudeHookModels.swift:112`（在 isCorrupted 方法后添加）

```swift

    /// 窗口当前位置是否在 targetFrame 附近（容差 150px）
    /// 用于验证被恢复的窗口确实在之前被 toggle 到的位置
    func isNearTarget(currentFrame: CGRect, tolerance: CGFloat = 150) -> Bool {
        guard let tgt = targetFrame else { return true }
        return abs(currentFrame.origin.x - tgt.origin.x) <= tolerance &&
               abs(currentFrame.origin.y - tgt.origin.y) <= tolerance
    }
```

- [ ] **Step 2: 修改 shouldRestoreCurrentWindow 添加窗口位置验证**

文件: `Sources/WindowManager.swift:858-897`（替换 findStateByWindowID 块，添加位置校验）

```swift
        if let wsState = SessionWindowRegistry.shared.findStateByWindowID(currentWindowID, expectedPID: frontApp.processIdentifier) {
            if wsState.hasToggleState {
                guard let mainScreen = getMainScreen() else { return false }
                if wsState.isCorrupted(mainScreenFrame: mainScreen.frame) {
                    SessionWindowRegistry.shared.clearToggleState(pid: wsState.pid, tty: wsState.tty)
                    return false
                }
                if let origFrame = wsState.originalFrame, let tgtFrame = wsState.targetFrame {
                    // 验证窗口确实在 targetFrame 附近（被 toggle 到的位置）
                    let currentFrame = self.frame(of: focusedWindow)
                    if let curFrame = currentFrame, !wsState.isNearTarget(currentFrame: curFrame) {
                        log(
                            "[WindowManager] shouldRestoreCurrentWindow: window not at target position, skipping restore",
                            level: .warn,
                            fields: [
                                "windowID": String(currentWindowID),
                                "currentX": String(curFrame.origin.x),
                                "currentY": String(curFrame.origin.y),
                                "targetX": String(tgtFrame.origin.x),
                                "targetY": String(tgtFrame.origin.y)
                            ]
                        )
                        return false
                    }
                    let savedState = SavedWindowState(
                        id: "\(wsState.pid)_\(wsState.tty ?? "none")",
                        pid: wsState.pid,
                        bundleIdentifier: wsState.bundleIdentifier,
                        appName: wsState.appName,
                        windowID: wsState.windowID,
                        windowNumber: wsState.axWindowNumber,
                        title: wsState.title,
                        originalFrame: RectPayload(origFrame),
                        targetFrame: RectPayload(tgtFrame),
                        sourceSpaceIndex: wsState.sourceSpace,
                        targetSpaceIndex: nil,
                        sourceYabaiDisplayIndex: wsState.sourceYabaiDisp,
                        sourceDisplaySpaceIndex: wsState.sourceDispSpace,
                        sourceDisplayIndex: wsState.sourceDisplay,
                        sourceDisplayID: nil,
                        targetDisplayIndex: wsState.targetDisplay,
                        restoreReason: wsState.toggleReason,
                        sessionID: wsState.sessionID,
                        savedAt: wsState.toggledAt ?? Date()
                    )
                    hydrateMemory(from: savedState, window: focusedWindow)
                    log(
                        "[WindowManager] shouldRestoreCurrentWindow: focused window on main, has toggle state → restore",
                        fields: [
                            "windowID": String(currentWindowID),
                            "pid": String(wsState.pid),
                            "tty": wsState.tty ?? "nil"
                        ]
                    )
                    return true
                }
            }
        }
```

- [ ] **Step 3: 修改 performRestoreFromState 添加 AX 窗口验证**

文件: `Sources/HookEventHandler.swift:307-327`（替换 hydrateMemory 和 restore 调用块）

```swift
        wm.hydrateMemory(from: savedState, window: nil)

        // 验证找到的窗口确实在 targetFrame 附近
        if let resolvedWindow = wm.lastWindowElement,
           let resolvedFrame = wm.frame(of: resolvedWindow) {
            if !toggleState.isNearTarget(currentFrame: resolvedFrame) {
                log(
                    "[HookEventHandler] UserPromptSubmit restore aborted: resolved window not at target position",
                    level: .warn,
                    fields: [
                        "sessionID": payload.sessionID,
                        "resolvedX": String(resolvedFrame.origin.x),
                        "resolvedY": String(resolvedFrame.origin.y),
                        "targetX": String(describing: toggleState.targetX),
                        "targetY": String(describing: toggleState.targetY)
                    ]
                )
                SessionWindowRegistry.shared.clearToggleState(pid: toggleState.pid, tty: toggleState.tty)
                return (
                    200,
                    ClaudeHookResponse(
                        ok: true, code: "window_moved_skip",
                        message: "Window position changed, skipping stale restore",
                        sessionID: payload.sessionID, handled: false
                    )
                )
            }
        }

        log(
            "[HookEventHandler] UserPromptSubmit restoring window",
            fields: [
                "sessionID": payload.sessionID,
                "matchLevel": matchLevel,
                "pid": String(toggleState.pid),
                "tty": toggleState.tty ?? "nil",
                "app": toggleState.appName ?? "unknown",
                "windowID": String(describing: toggleState.windowID),
                "originalFrame": String(describing: origFrame),
                "targetFrame": String(describing: tgtFrame)
            ]
        )

        wm.restore(
            operationID: makeOperationID(prefix: "hook-restore"),
            triggerSource: "user_prompt_submit"
        )
```

- [ ] **Step 4: 验证编译**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 5: 部署验证**
Run: `bash scripts/dev-build.sh 2>&1 | tail -3`
Expected:
  - Output contains: "构建成功"

- [ ] **Step 6: 提交**
Run: `git add Sources/ClaudeHookModels.swift Sources/WindowManager.swift Sources/HookEventHandler.swift && git commit -m "fix(restore): add window position validation before restore to prevent wrong-window movement"`
