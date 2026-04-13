# Fix: Hook 自动操作跳过冗余窗口移动

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 为 Stop 和 UserPromptSubmit 两个 hook 事件添加窗口位置预检：Stop 事件仅当窗口不在主屏幕时才移动到主屏；UserPromptSubmit 事件仅当窗口不在原始位置（副屏）时才恢复。防止与用户手动快捷键操作冲突导致窗口状态混乱。

**Architecture:** Stop hook → ClaudeHookServer.handleWindowMoveTrigger → moveBindingToMainScreen → [NEW: isWindowOnMainScreen 预检] → 跳过或执行 moveWindowToMainScreen。UserPromptSubmit hook → handleUserPromptSubmit → restore → [NEW: restore 内部 framesMatch(currentFrame, originalFrame) 预检] → 跳过或执行恢复。两个检查在调用实际窗口操作之前拦截，避免无意义的移动和错误的状态保存。

**Tech Stack:** Swift 5.9, AppKit, CGWindowList API, AXUIElement

**Risks:**
- Task 1 的 CGWindowList 查询在窗口最小化时可能返回空 bounds → 缓解：无 bounds 时返回 false（视为不在主屏），走正常移动路径，安全降级
- Task 2 的 framesMatch 容差（10px）可能在轻微位置偏移时仍触发恢复 → 缓解：复用现有已验证的容差值和 framesMatch 逻辑

---

### Root Cause Analysis

**Bug 1: Stop 事件在窗口已在主屏时仍然"成功"完成会话**

`Sources/WindowManagerSupport.swift:628-644` — `moveWindowToMainScreen` 内部已有 "already on main screen" 检查，跳过时返回 `true`（不保存状态）。但 `Sources/ClaudeHookServer.swift:607-631` 的 `moveBindingToMainScreen` 将 `moved = true` 视为"成功移动"，调用 `markCompleted` 标记会话完成并返回 `handled: true`。结果：没有保存 SavedWindowState，但会话被标记为已完成，后续 UserPromptSubmit 找不到状态。

**Bug 2: UserPromptSubmit 事件在窗口已在副屏时仍然执行恢复**

`Sources/WindowManager.swift:276-496` — `restore` 方法在找到窗口后直接执行 frame 应用，不检查窗口是否已在目标位置。当用户手动用快捷键恢复了窗口，或 Stop 从未移动窗口（Bug 1 场景），UserPromptSubmit 的恢复操作会把窗口从副屏错误地"恢复"（实际可能移到主屏或产生无意义操作）。

---

### Task 1: Add isWindowOnMainScreen Guard for Stop Hook

**Depends on:** None
**Files:**
- Modify: `Sources/WindowManagerSupport.swift` (在 `findWindowByTTY` 方法之后添加 `isWindowOnMainScreen` 方法，约 line 318)
- Modify: `Sources/ClaudeHookServer.swift:579-594` (在 `moveBindingToMainScreen` 的 `isCompleted` 检查之后添加预检)

- [ ] **Step 1: 添加 isWindowOnMainScreen 方法 — 通过 CGWindowList 检查窗口是否在主屏幕上**

文件: `Sources/WindowManagerSupport.swift:318` (在 `findWindowByTTY` 的 `}` 之后插入)

```swift
    /// 通过 CGWindowList 检查指定窗口是否当前在主屏幕上
    /// 用于 hook 路径在执行窗口移动前的预检，避免对已在主屏的窗口执行无意义的移动
    func isWindowOnMainScreen(windowID: UInt32) -> Bool {
        let options = CGWindowListOption(arrayLiteral: .optionAll)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        guard let mainScreen = getMainScreen() else { return false }
        let mainScreenFrame = mainScreen.frame

        for info in windowList {
            guard let id = info[kCGWindowNumber as String] as? UInt32,
                  id == windowID else { continue }
            let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
            guard let bounds else { return false }
            let windowFrame = CGRect(
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0
            )
            let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
            return mainScreenFrame.contains(center)
        }
        return false
    }
```

- [ ] **Step 2: 修改 moveBindingToMainScreen — 在 isCompleted 检查后添加主屏预检**

文件: `Sources/ClaudeHookServer.swift:579-594` (在 `isCompleted` 检查的 `}` 之后、"moving window" 日志之前插入)

在 `if binding.isCompleted { ... }` 代码块结束后，`log("[ClaudeHookServer] \(triggerName) moving window"` 之前，插入：

```swift
        // 预检：如果窗口已在主屏幕上，跳过移动
        // 防止对已在主屏的窗口执行无意义移动，避免保存错误状态
        if WindowManager.shared.isWindowOnMainScreen(windowID: binding.windowIdentity.windowID) {
            handledRequestCount += 1
            SessionWindowRegistry.shared.setLastEventDescription(
                "\(triggerName) 窗口已在主屏幕，跳过移动"
            )
            log(
                "[ClaudeHookServer] \(triggerName) window already on main screen, skipping move",
                fields: [
                    "sessionID": payload.sessionID,
                    "windowID": String(binding.windowIdentity.windowID),
                    "app": binding.windowIdentity.appName ?? "unknown"
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
```

- [ ] **Step 3: 验证编译**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**

Run: `git add Sources/WindowManagerSupport.swift Sources/ClaudeHookServer.swift && git commit -m "fix(hooks): skip Stop hook when window already on main screen"`

---

### Task 2: Add "Already at Original Position" Guard in Restore

**Depends on:** Task 1
**Files:**
- Modify: `Sources/WindowManager.swift:366-393` (在 `restoreWindow` 调用后添加位置预检)

- [ ] **Step 1: 修改 restore 方法 — 在找到窗口后添加原始位置预检**

文件: `Sources/WindowManager.swift:366-393` (在 `guard let window = restoreWindow(using: token) else { ... }` 之后，诊断日志之前插入)

将 `Sources/WindowManager.swift:366` 到 line 393 的代码替换为：

```swift
        guard let window = restoreWindow(using: token) else {
            log(
                "[WindowManager] restore failed: window not found",
                level: .error,
                fields: [
                    "op": op,
                    "tokenWindowID": String(describing: token.windowID)
                ]
            )
            CrashContextRecorder.shared.record("restore_failed_window_not_found op=\(op)")
            return
        }

        // 预检：如果窗口已在目标（原始）位置，跳过恢复
        // 防止对已恢复的窗口执行无意义操作，避免与手动快捷键操作冲突
        if let currentFrame = self.frame(of: window),
           let targetFrame = lastWindowFrame,
           framesMatch(currentFrame, targetFrame) {
            log(
                "[WindowManager] restore skipped: window already at original position",
                fields: [
                    "op": op,
                    "currentFrame": String(describing: currentFrame),
                    "targetFrame": String(describing: targetFrame)
                ]
            )
            resetActiveWindowContext(removeState: true)
            CrashContextRecorder.shared.record("restore_skipped_already_at_original op=\(op)")
            return
        }

        // 诊断日志：记录找到的窗口的当前状态
        let restoredWindowFrame = self.frame(of: window)
        let restoredWindowID = windowHandle(for: window)
        let restoredWindowSpace = restoredWindowID.flatMap { spaceController.windowSpaceIndex(windowID: $0) }
        log(
            "[WindowManager] restore_found_window",
            fields: [
                "op": op,
                "windowID": String(describing: restoredWindowID),
                "currentFrame": String(describing: restoredWindowFrame),
                "windowActualSpace": String(describing: restoredWindowSpace),
                "spacePrepared": String(spacePrepared)
            ]
        )
```

- [ ] **Step 2: 验证编译**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**

Run: `git add Sources/WindowManager.swift && git commit -m "fix(hooks): skip UserPromptSubmit restore when window already at original position"`

---

### Task 3: Build, Deploy, and Verify

**Depends on:** Task 1, Task 2
**Files:**
- Modify: `Sources/AppVersion.swift` (version bump)

- [ ] **Step 1: Bump version to 0.0.14**

文件: `Sources/AppVersion.swift`

将版本号从 `"0.0.13"` 改为 `"0.0.14"`。

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

- [ ] **Step 5: 验证 Stop 预检日志**

Run: `sleep 3 && grep -i "already on main screen" /tmp/vibefocus.log | tail -5`
Expected:
  - 当 Stop hook 触发且窗口已在主屏时，日志中出现 "already on main screen, skipping move"

- [ ] **Step 6: 验证 Restore 预检日志**

Run: `grep -i "already at original position" /tmp/vibefocus.log | tail -5`
Expected:
  - 当 UserPromptSubmit 触发且窗口已在副屏时，日志中出现 "restore skipped: window already at original position"

- [ ] **Step 7: Commit version bump**

Run: `git add Sources/AppVersion.swift && git commit -m "release: v0.0.14"`
