# Bug Fix: EXC_BAD_ACCESS Crash & Hook Restore Failure

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复两个 bug：(1) 窗口恢复操作中操作已销毁窗口导致的 SIGSEGV 崩溃；(2) Hook 触发的窗口恢复（UserPromptSubmit）失败，因为 hydrateMemory 传入 window=nil 导致 AX 元素为 stale 引用。同时确保 Hook 路径和 Hotkey 路径共享同一份窗口状态数据。

**Architecture:** 两个 bug 的根因相关。崩溃发生在 SpaceController 对已不存在的 windowID 执行 yabai 操作时，后续 AX API 调用使用了 dangling pointer。Hook 恢复失败是因为 `hydrateMemory(window: nil)` 无法获取有效的 AXUIElement，导致 `restoreWindow(using:)` 的三级匹配全部失败。修复策略：(1) 在所有窗口操作前验证窗口存在性，操作失败时立即中止而非继续；(2) 在 hook 恢复路径中，hydrateMemory 后主动重新查找窗口 AX 元素，确保与 hotkey 路径行为一致。

**Tech Stack:** Swift 5.9, SwiftUI, AppKit, ApplicationServices (AXUIElement), yabai (SpaceManager)

**Risks:**
- Task 1 修改了 `restoreWindow(using:)` 的匹配逻辑，可能影响 hotkey 路径 → 缓解：保留原有三级匹配逻辑不变，仅新增主动查找步骤
- Task 2 修改了 `applySpaceStrategyForRestore`，窗口不存在时提前返回而非继续操作 → 缓解：返回 true（表示"不需要 space 操作"）让后续 frame restore 仍可尝试
- Task 3 修改了 `handleUserPromptSubmit`，需要在 hydrateMemory 后增加窗口查找 → 缓解：复用 `restoreWindow(using:)` 的查找逻辑

---

## Root Cause Analysis

### Bug #1: EXC_BAD_ACCESS Crash

**Crash Report** (2026-04-10): `EXC_BAD_ACCESS (SIGSEGV), KERN_INVALID_ADDRESS at 0x0000000000000020`
**Call Stack**: `objc_release → AutoreleasePoolPage::releaseUntil → objc_autoreleasePoolPop → CFRunLoopRun`

**Root Cause**: 当目标窗口已被关闭/销毁时（yabai 报告 "could not locate window"），代码继续对该 windowID 执行 `moveWindow`、`focusWindow` 等操作。这些操作调用 AXUIElement API 访问已释放的 Objective-C 对象，导致 use-after-free。RunLoop drain autorelease pool 时访问 dangling pointer，触发 SIGSEGV。

**触发路径**:
```
UserPromptSubmit hook → hydrateMemory(window:nil) → restore()
→ applySpaceStrategyForRestore(windowID:101)
  → focusSpace(3) → failed "scripting-addition error"
  → moveWindow(101, toSpace:3) → failed "could not locate window"
  → 后续 AX 操作使用 stale windowID → CRASH
```

### Bug #2: Hook Restore Not Working

**Root Cause**: `handleUserPromptSubmit` 调用 `hydrateMemory(from: savedState, window: nil)`。`hydrateMemory` 中 `lastWindowElement = window ?? windowElementsByStateID[state.id]`，对于 hook 路径，window 为 nil，`windowElementsByStateID` 中的缓存 AX 元素可能已过期（窗口被关闭重开、App 重启等）。后续 `restoreWindow(using:)` 的三级匹配都依赖 stale 引用，全部失败。

**对比 Hotkey 路径**（正常工作）:
```
toggle() → shouldRestoreCurrentWindow() 
→ 从 savedWindowStates 匹配当前聚焦窗口
→ hydrateMemory(from: matchedState, window: currentWindowAX)  // ✅ 有 fresh AX 元素
→ restoreWindow(using: token) → 第一级匹配成功
```

---

### Task 1: Add Window Existence Check Before Space Operations

**Depends on:** None
**Files:**
- Modify: `Sources/WindowManager.swift:767-830` (applySpaceStrategyForRestore 函数)
- Modify: `Sources/WindowManager.swift:711-747` (restoreWindow 函数)

- [ ] **Step 1: Add window validation helper — 验证 windowID 对应的窗口是否仍然存在**

在 `Sources/WindowManager.swift` 的 `restoreWindow(using:)` 函数之前添加一个新的验证方法。

文件: `Sources/WindowManager.swift:710` (在 `restoreWindow(using:)` 函数前插入)

```swift
    /// 验证 windowID 对应的窗口是否仍然存在于系统中
    /// 通过 CGWindowList 查询，避免对已销毁窗口的 AX 操作导致 crash
    func validateWindowExists(windowID: UInt32?) -> Bool {
        guard let windowID else { return false }
        let options = CGWindowListOption(arrayLiteral: .optionAll)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return windowList.contains { window in
            (window[kCGWindowNumber as String] as? UInt32) == windowID
        }
    }
```

- [ ] **Step 2: Guard applySpaceStrategyForRestore with window existence check — 防止对已销毁窗口执行 space 操作**

文件: `Sources/WindowManager.swift:767-791` (applySpaceStrategyForRestore 函数开头，在 `guard let windowID` 之后)

在 `guard let windowID else { return true }` 之后添加窗口存在性检查：

```swift
    func applySpaceStrategyForRestore(windowID: UInt32?, operationID: String? = nil) -> Bool {
        guard let windowID else { return true }
        let op = operationID ?? makeOperationID(prefix: "restore-space")

        // 关键安全检查：验证窗口是否仍然存在
        // 如果窗口已被关闭，跳过所有 space 操作以避免 EXC_BAD_ACCESS
        if !validateWindowExists(windowID: windowID) {
            log(
                "[WindowManager] space strategy aborted: window no longer exists",
                level: .warn,
                fields: [
                    "op": op,
                    "windowID": String(windowID)
                ]
            )
            return true  // 返回 true 表示"不需要 space 操作"，让调用方继续尝试 frame restore
        }

        spaceController.refreshAvailabilityIfNeeded()
        guard spaceController.isEnabled else {
```

- [ ] **Step 3: Validate**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: Commit**
Run: `git add Sources/WindowManager.swift && git commit -m "fix(restore): validate window existence before space operations to prevent EXC_BAD_ACCESS"`

---

### Task 2: Fix Hook Restore — Resolve Fresh AX Element After hydrateMemory

**Depends on:** Task 1
**Files:**
- Modify: `Sources/WindowManager.swift:711-747` (restoreWindow 函数)
- Modify: `Sources/WindowManager.swift:1307-1324` (hydrateMemory 函数)

- [ ] **Step 1: Improve restoreWindow to actively re-resolve window by PID — 确保即使缓存 AX 元素过期也能找到窗口**

文件: `Sources/WindowManager.swift:711-747` (替换整个 `restoreWindow(using:)` 函数)

```swift
    func restoreWindow(using token: WindowToken) -> AXUIElement? {
        // 第一级匹配：通过 windowID 匹配当前聚焦窗口
        if let focused = focusedWindow(for: token.pid),
           let currentWindowID = windowHandle(for: focused),
           currentWindowID == token.windowID {
            log("Restoring using focused window handle match")
            return focused
        }

        // 第二级匹配：通过 windowID 匹配缓存的窗口引用
        if let lastWindowElement,
           let currentWindowID = windowHandle(for: lastWindowElement),
           currentWindowID == token.windowID {
            log("Restoring using saved AX handle match")
            return lastWindowElement
        }

        // 第二级-B：主动按 PID 遍历所有窗口查找匹配 windowID
        // 这解决了 hook 路径中 hydrateMemory(window:nil) 导致缓存元素过期的问题
        if let resolvedByPID = findWindowByPID(token.pid, windowID: token.windowID) {
            log("Restoring using PID-based window enumeration")
            return resolvedByPID
        }

        // 第三级匹配：备用匹配（PID + 标题 + 大致位置）
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           let focused = focusedWindow(for: frontApp.processIdentifier),
           let currentTitle = title(of: focused),
           let currentFrame = frame(of: focused),
           let lastTarget = lastTargetFrame {
            let pidMatches = frontApp.processIdentifier == token.pid
            let titleMatches = (token.title ?? "") == currentTitle
            let positionMatches = abs(currentFrame.origin.x - lastTarget.origin.x) <= 50 &&
                                 abs(currentFrame.origin.y - lastTarget.origin.y) <= 50

            if pidMatches && titleMatches && positionMatches {
                log("Restoring using fallback matching (PID+title+position)")
                return focused
            }
        }

        return nil
    }
```

- [ ] **Step 2: Add findWindowByPID helper — 按 PID 遍历应用的所有窗口查找匹配 windowID**

文件: `Sources/WindowManager.swift:747` (在 `restoreWindow(using:)` 之后插入)

```swift
    /// 按 PID 遍历应用的所有窗口，查找匹配 windowID 的窗口
    /// 用于 hook 路径中缓存 AX 元素过期时的主动查找
    private func findWindowByPID(_ pid: pid_t, windowID: UInt32?) -> AXUIElement? {
        guard let windowID else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard status == .success, let windows = windowsRef as? [AXUIElement] else {
            return nil
        }
        return windows.first { window in
            windowHandle(for: window) == windowID
        }
    }
```

- [ ] **Step 3: Update hydrateMemory to attempt stale cache recovery — 在缓存 AX 元素过期时尝试主动查找**

文件: `Sources/WindowManager.swift:1307-1324` (替换整个 `hydrateMemory` 函数)

```swift
    func hydrateMemory(from state: SavedWindowState, window: AXUIElement?) {
        let cachedElement = windowElementsByStateID[state.id]
        let resolvedWindow = window ?? cachedElement

        // 验证缓存的 AX 元素是否仍然有效
        var effectiveWindow: AXUIElement? = resolvedWindow
        if let resolvedWindow {
            let handle = windowHandle(for: resolvedWindow)
            if handle == nil && state.windowID != nil {
                // AX 元素已失效（返回 nil windowID），清除缓存
                log(
                    "hydrateMemory: cached AX element is stale, clearing",
                    fields: [
                        "stateID": state.id,
                        "expectedWindowID": String(describing: state.windowID)
                    ]
                )
                windowElementsByStateID.removeValue(forKey: state.id)
                effectiveWindow = nil
            }
        }

        // 如果没有有效 AX 元素，尝试按 PID + windowID 主动查找
        if effectiveWindow == nil, let windowID = state.windowID {
            effectiveWindow = findWindowByPID(state.pid, windowID: windowID)
            if let found = effectiveWindow {
                log(
                    "hydrateMemory: re-resolved window by PID enumeration",
                    fields: [
                        "stateID": state.id,
                        "windowID": String(windowID)
                    ]
                )
                windowElementsByStateID[state.id] = found
            }
        }

        lastWindowElement = effectiveWindow
        lastWindowToken = WindowToken(
            stateID: state.id,
            pid: state.pid,
            bundleIdentifier: state.bundleIdentifier,
            appName: state.appName,
            windowID: state.windowID,
            windowNumber: state.windowNumber,
            title: state.title
        )
        lastWindowFrame = state.originalFrame.cgRect
        lastTargetFrame = state.targetFrame.cgRect
        lastSourceSpaceIndex = state.sourceSpaceIndex
        lastTargetSpaceIndex = state.targetSpaceIndex
        lastSourceYabaiDisplayIndex = state.sourceYabaiDisplayIndex
        lastSourceDisplaySpaceIndex = state.sourceDisplaySpaceIndex
    }
```

- [ ] **Step 4: Validate**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 5: Commit**
Run: `git add Sources/WindowManager.swift && git commit -m "fix(restore): resolve fresh AX element after hydrateMemory for hook-triggered restores"`

---

### Task 3: Guard SpaceController.moveWindow Against Non-existent Windows

**Depends on:** Task 1
**Files:**
- Modify: `Sources/SpaceController.swift:250-290` (moveWindow 函数)

- [ ] **Step 1: Add early return in moveWindow when window doesn't exist — 防止 yabai 操作已销毁窗口**

文件: `Sources/SpaceController.swift:250-290` (moveWindow 函数，在 `refreshAvailabilityIfNeeded()` 之后，`guard canControlSpaces` 之前插入窗口验证)

在 `moveWindow` 函数中，`guard isEnabled else { return false }` 之后添加窗口存在性检查：

```swift
    @discardableResult
    func moveWindow(_ windowID: UInt32, toSpaceIndex spaceIndex: Int, focus: Bool, operationID: String? = nil) -> Bool {
        let op = operationID ?? "none"
        refreshAvailabilityIfNeeded()
        guard isEnabled else {
            return false
        }

        // 安全检查：先验证窗口是否存在
        let windowCheck = queryWindow(windowID: windowID)
        if windowCheck == nil {
            log(
                "[SpaceController] moveWindow aborted: window does not exist",
                level: .warn,
                fields: [
                    "op": op,
                    "windowID": String(windowID),
                    "targetSpace": String(spaceIndex)
                ]
            )
            return false
        }

        guard canControlSpaces else {
```

- [ ] **Step 2: Add early return in focusWindow when window doesn't exist**

文件: `Sources/SpaceController.swift` (在 focusWindow 函数中添加类似的窗口存在性检查)

找到 `focusWindow` 函数（约 line 340-380），在函数开头的 `refreshAvailabilityIfNeeded()` 和 `guard isEnabled` 之后添加：

```swift
        // 安全检查：验证窗口存在
        let windowCheck = queryWindow(windowID: windowID)
        if windowCheck == nil {
            log(
                "[SpaceController] focusWindow aborted: window does not exist",
                level: .warn,
                fields: [
                    "op": operationID ?? "none",
                    "windowID": String(windowID)
                ]
            )
            return false
        }
```

- [ ] **Step 3: Validate**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: Commit**
Run: `git add Sources/SpaceController.swift && git commit -m "fix(space): guard moveWindow and focusWindow against non-existent windows"`

---

### Task 4: Build, Deploy, and Verify

**Depends on:** Task 2, Task 3
**Files:**
- Modify: `Sources/AppVersion.swift` (version bump)

- [ ] **Step 1: Bump version to 0.0.12**

文件: `Sources/AppVersion.swift`

将版本号从 `"0.0.11"` 改为 `"0.0.12"`。

- [ ] **Step 2: Build release**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -3`
Expected:
  - Exit code: 0

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

- [ ] **Step 5: Verify logs show no errors on startup**

Run: `sleep 3 && tail -20 /tmp/vibefocus.log`
Expected:
  - Log shows new PID
  - No crash or error messages
  - "bootstrap complete" in CRASH_CONTEXT

- [ ] **Step 6: Commit version bump**
Run: `git add Sources/AppVersion.swift && git commit -m "release: v0.0.12"`
