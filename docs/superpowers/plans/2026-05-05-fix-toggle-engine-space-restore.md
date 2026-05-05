# Fix ToggleEngine Space Restore — yabai fallback + correct sourceDisplay

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 ToggleEngine.restore 的空间切换失败问题。当前 NativeSpaceBridge.moveWindow 100% 失败率（13/13），但 ToggleEngine 使用的是 `moveWindowToSpace()`（无 yabai fallback），而不是 `moveWindow()`（有完整 yabai → NativeSpaceBridge 三策略链）。同时修复 sourceDisplay 始终为 0 的问题，以及移除错误路径上的 clear() 调用。

**Architecture:** ToggleEngine.restore → switchToOriginalSpace → 应调用 SpaceController.moveWindow()（含 yabai fallback）而非 moveWindowToSpace()（仅 NativeSpaceBridge）。sourceDisplay 改用 yabai display index（sourceYabaiDisp）替代 AX displayContext（不可靠）。

**Tech Stack:** Swift 5.9, macOS 13+, yabai (space management), CGS private API (NativeSpaceBridge)

**Risks:**
- Task 1: `moveWindow(toSpaceIndex:focus:operationID:)` 有 `canControlSpaces` 守卫，需确保 yabai 可用
- Task 2: sourceDisplay 值变化可能影响依赖它的其他逻辑（已检查：无其他读取方）

---

### Task 1: 修复 switchToOriginalSpace 使用 yabai fallback

**Depends on:** None
**Files:**
- Modify: `Sources/ToggleEngine.swift:155-207`（`switchToOriginalSpace` 方法）

- [ ] **Step 1: 修改 switchToOriginalSpace 方法 — 改用 SpaceController.moveWindow() 实现完整的 yabai fallback链**

文件: `Sources/ToggleEngine.swift:155-207`（替换整个 `switchToOriginalSpace` 方法）

```swift
    /// 切换到窗口的原始 space
    private func switchToOriginalSpace(record: ToggleRecord, windowAX: AXUIElement, triggerSource: String) {
        let spaceController = SpaceController.shared

        // 用 captureSpaceContext 获取窗口当前 space
        let currentContext = spaceController.captureSpaceContext(windowID: record.windowID, operationID: "toggle_engine_space_check")
        guard let currentSpace = currentContext.sourceSpaceIndex else {
            log("ToggleEngine.switchToOriginalSpace: cannot query current space", level: .debug)
            return
        }

        let targetSpace = record.sourceSpace
        guard currentSpace != targetSpace else {
            log("ToggleEngine.switchToOriginalSpace: already on target space", level: .debug, fields: [
                "space": String(targetSpace)
            ])
            return
        }

        log("ToggleEngine.switchToOriginalSpace: switching", fields: [
            "from": String(currentSpace),
            "to": String(targetSpace),
            "sourceYabaiDisp": String(record.sourceYabaiDisp),
            "sourceDispSpace": String(record.sourceDispSpace)
        ])

        // 使用 SpaceController.moveWindow — 包含完整 fallback 链：
        // 1. NativeSpaceBridge (CGS private API)
        // 2. yabai -m window --space (scripting-addition)
        // 3. NativeSpaceBridge fallback
        let moved = spaceController.moveWindow(
            record.windowID,
            toSpaceIndex: targetSpace,
            focus: triggerSource == "carbon_hotkey",
            operationID: "toggle_engine_space_switch"
        )

        if !moved {
            log("ToggleEngine.switchToOriginalSpace: all strategies failed", level: .error, fields: [
                "windowID": String(record.windowID),
                "targetSpace": String(targetSpace)
            ])
            return
        }

        // 等待 space 切换动画完成
        usleep(200_000)

        // 如果是 hotkey 触发且 moveWindow 未 focus（fallback 路径），手动切换用户视角
        if triggerSource == "carbon_hotkey" {
            let steps = targetSpace - currentSpace
            if steps != 0 {
                _ = NativeSpaceBridge.focusSpace(steps: steps)
                usleep(400_000)
            }
        }
    }
```

- [ ] **Step 2: 验证编译**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Output contains: "Build complete!"

---

### Task 2: 修复 sourceDisplay 始终为 0 — 改用 yabai display index

**Depends on:** None
**Files:**
- Modify: `Sources/WindowManager+MoveWindow.swift:420-427`（ToggleEngine.save 调用处）

- [ ] **Step 1: 修改 ToggleEngine.save 调用 — sourceDisplay 使用 yabai display index 而非不可靠的 AX displayContext**

文件: `Sources/WindowManager+MoveWindow.swift:414-427`（替换 ToggleEngine.shared.save 调用块）

当前代码使用 `sourceContext.index ?? 0` 作为 sourceDisplay，但 `displayContext(for:)` 对非活跃工作区的窗口返回 nil（AX 坐标不可靠），导致 sourceDisplay 始终为 0。应使用 yabai 的 `spaceContext.sourceDisplayIndex`。

```swift
        // 新路径：ToggleEngine 保存完整恢复数据到 SQLite（单一事实来源）
        ToggleEngine.shared.save(
            windowID: currentWindowID,
            pid: identity.pid,
            bundleIdentifier: identity.bundleIdentifier,
            appName: identity.appName,
            origFrame: currentFrame,
            sourceSpace: spaceContext.sourceSpaceIndex ?? 0,
            sourceDisplay: spaceContext.sourceDisplayIndex ?? sourceContext.index ?? 0,
            sourceYabaiDisp: spaceContext.sourceDisplayIndex ?? 0,
            sourceDispSpace: spaceContext.sourceDisplaySpaceIndex ?? 0,
            targetFrame: actualTargetFrame,
            targetDisplay: targetDisplayIndex ?? 0,
            sessionID: sessionID
        )
```

- [ ] **Step 2: 验证编译**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Output contains: "Build complete!"

---

### Task 3: 移除 restore 错误路径上的 clear() 调用 + 部署测试

**Depends on:** Task 1, Task 2
**Files:**
- Modify: `Sources/ToggleEngine.swift:104-131`（restore 方法中 clear 调用）

- [ ] **Step 1: 移除 restore 方法中错误路径的 clear() 调用 — 用户明确要求保留数据**

文件: `Sources/ToggleEngine.swift:104-131`（restore 方法中 3 处 clear 调用）

当前 restore 方法在以下错误路径调用 clear()：
- 第 110 行：窗口 AX element 未找到 → clear
- 第 117 行：无法获取当前 frame → clear
- 第 130 行：窗口不在 target 位置附近 → clear

这些都不应该清除数据。改为只记录日志。

```swift
        // 1. 找到窗口 AX element
        guard let windowAX = wm.findWindowByPID(record.pid, windowID: record.windowID) else {
            log("ToggleEngine.restore: window AX element not found", level: .warn, fields: [
                "windowID": String(windowID),
                "pid": String(record.pid)
            ])
            return false
        }

        // 2. 获取当前 frame（验证用）
        guard let currentFrame = wm.frame(of: windowAX) else {
            log("ToggleEngine.restore: cannot get current frame", level: .warn)
            return false
        }

        // 3. 验证窗口确实在 target 位置附近
        if !record.isNearTarget(currentFrame: currentFrame) {
            log("ToggleEngine.restore: window moved from target, skipping restore", level: .warn, fields: [
                "windowID": String(windowID),
                "currentX": String(Int(currentFrame.origin.x)),
                "currentY": String(Int(currentFrame.origin.y)),
                "targetX": String(Int(record.targetFrame.origin.x)),
                "targetY": String(Int(record.targetFrame.origin.y))
            ])
            return false
        }
```

- [ ] **Step 2: 构建并部署**
Run: `bash scripts/dev-build.sh 2>&1 | tail -5`
Expected:
  - Output contains: "构建成功！"

- [ ] **Step 3: 提交**
Run: `git add Sources/ToggleEngine.swift Sources/WindowManager+MoveWindow.swift && git commit -m "fix(restore): use yabai fallback for space switching, fix sourceDisplay=0, preserve toggle data"`
