# Bug Fix: Window Restore Lands on Wrong Space When yabai SA Fails

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Symptom:** 从主屏幕 restore 回副屏时，窗口没有回到原始工作区，而是停留在副屏当前可见的工作区。对于 2x3 等多工作区布局，这导致覆盖其他窗口。

**Root Cause:** yabai scripting-addition 不稳定时，`yabai -m window --space N` 返回 exitCode=0 但窗口实际未移动。`yabai -m space --focus N` 失败报 "scripting-addition" 错误或 "mission-control is active"。CGEvent fallback 虽然执行了但 Mission Control 处于活跃状态时键盘事件被吞掉。

**Impact:** 所有跨显示器 restore 操作，当 SA 不可靠或 Mission Control 活跃时触发。

**Scope:** Small (3 files)
**Risk:** Medium (修改核心 restore 路径)

**Risks:**
- Task 1 修改了共享的 switchDisplayToSpace — 可能影响手动 space 切换 → 缓解：只在检测到 SA/MC 错误时触发 dismiss
- Task 2 修改了 performCrossDisplayRestore — 可能延长 restore 时间 → 缓解：最多增加 ~1s 等待

**Autonomy Level:** Full

---

### Task 1: Add Mission Control dismissal before space operations

**Depends on:** None
**Files:**
- Modify: `Sources/Space/SpaceController+Switch.swift:7-89` (switchDisplayToSpace function)
- Modify: `Sources/Space/NativeSpaceBridge.swift` (add dismissMissionControl)

- [ ] **Step 1: Add dismissMissionControl to NativeSpaceBridge — 发送 Escape 键关闭 Mission Control**

在 `Sources/Space/NativeSpaceBridge.swift` 的 `focusSpace(steps:)` 函数后面添加：

文件: `Sources/Space/NativeSpaceBridge.swift:148`（在 `focusSpace` 函数的 `}` 之后插入）

```swift
    /// 发送 Escape 键关闭 Mission Control
    /// 当 yabai 报 "mission-control is active" 错误时，Mission Control 正在显示中
    /// 此时所有 space 切换命令（yabai + CGEvent Ctrl+Arrow）都会失败
    /// 需要先关闭 Mission Control 才能继续操作
    static func dismissMissionControl(operationID: String? = nil) {
        let op = operationID ?? "none"
        log("[NativeSpaceBridge] dismissing Mission Control via Escape key", fields: ["op": op])
        let escapeDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: true)
        escapeDown?.post(tap: .cghidEventTap)
        let escapeUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: false)
        escapeUp?.post(tap: .cghidEventTap)
        usleep(150_000) // 等待 Mission Control 动画结束
    }
```

- [ ] **Step 2: 修改 switchDisplayToSpace — 检测 SA/MC 错误并自动恢复**

替换 `Sources/Space/SpaceController+Switch.swift:7-89` 的 `switchDisplayToSpace` 函数：

```swift
    func switchDisplayToSpace(targetSpace: Int, operationID: String?) -> Bool {
        let op = operationID ?? "none"
        refreshAvailabilityIfNeeded()
        guard isEnabled else {
            log("[SpaceController] switchDisplayToSpace: not enabled", level: .warn, fields: ["op": op])
            return false
        }

        // Strategy 1: yabai -m space --focus (需要 SA)
        let yabaiResult = runYabai(
            arguments: ["-m", "space", "--focus", String(targetSpace)],
            operation: "switchDisplayToSpace_yabai",
            operationID: op
        )
        if let result = yabaiResult, result.exitCode == 0 {
            return true
        }

        // 检测 Mission Control 阻塞 — 如果 MC 活跃则先关闭再重试
        let stderr = yabaiResult?.stderr ?? ""
        let isMCBlocking = stderr.contains("mission-control")
        if isMCBlocking {
            log("[SpaceController] switchDisplayToSpace: Mission Control blocking, dismissing", level: .info, fields: ["op": op])
            NativeSpaceBridge.dismissMissionControl(operationID: op)
            // 重试 yabai
            let retryResult = runYabai(
                arguments: ["-m", "space", "--focus", String(targetSpace)],
                operation: "switchDisplayToSpace_yabai_after_mc_dismiss",
                operationID: op
            )
            if let result = retryResult, result.exitCode == 0 {
                return true
            }
        }

        log("[SpaceController] switchDisplayToSpace: yabai failed, trying CGEvent fallback", level: .info, fields: [
            "op": op, "targetSpace": String(targetSpace)
        ])

        // Strategy 2: CGEvent — 先用 yabai 激活目标 display，再 Ctrl+Left/Right
        let steps = calculateFocusSteps(targetSpaceIndex: targetSpace)

        // 先用 yabai display --focus 激活目标 display（不需要 SA）
        if let targetDisplayIdx = querySpaces()?.first(where: { $0.index == targetSpace })?.display {
            let focusResult = runYabai(
                arguments: ["-m", "display", "--focus", String(targetDisplayIdx)],
                operation: "switchDisplayToSpace_display_focus",
                operationID: op
            )
            if let result = focusResult, result.exitCode == 0 {
                usleep(30_000)
            } else {
                log("[SpaceController] switchDisplayToSpace: yabai display focus failed, relying on cursor move", level: .info, fields: [
                    "op": op, "targetDisplay": String(targetDisplayIdx)
                ])
            }
        }

        guard steps != 0 else {
            if let (savedCursor, savedApp) = saveAndMoveCursor(toSpace: targetSpace, operationID: op) {
                restoreCursor(savedCursor, savedApp: savedApp)
            }
            return true
        }

        // 移鼠标到目标 display，发送 Ctrl+Left/Right，恢复鼠标
        let saved = saveAndMoveCursor(toSpace: targetSpace, operationID: op)

        let success = NativeSpaceBridge.focusSpace(steps: steps, operationID: op)

        if let (savedCursor, savedApp) = saved {
            restoreCursor(savedCursor, savedApp: savedApp)
        }

        if success {
            usleep(80_000)
            let postSwitchSpace = displayVisibleSpace(displayIndex: querySpaces()?.first(where: { $0.index == targetSpace })?.display)
            let reachedTarget = postSwitchSpace == targetSpace
            log("[SpaceController] switchDisplayToSpace: CGEvent result", fields: [
                "op": op,
                "targetSpace": String(targetSpace),
                "steps": String(steps),
                "postSwitchSpace": String(describing: postSwitchSpace),
                "reachedTarget": String(reachedTarget)
            ])
            if reachedTarget {
                return true
            }
            log("[SpaceController] switchDisplayToSpace: CGEvent sent but space didn't change", level: .warn, fields: [
                "op": op,
                "targetSpace": String(targetSpace),
                "postSwitchSpace": String(describing: postSwitchSpace)
            ])
        }

        log("[SpaceController] switchDisplayToSpace: all strategies failed", level: .error, fields: [
            "op": op, "targetSpace": String(targetSpace)
        ])
        return false
    }
```

- [ ] **Step 3: 验证编译**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 4: 提交**
Run: `git add Sources/Space/ && git commit -m "fix(space): dismiss Mission Control when it blocks space switching"`

---

### Task 2: Improve performCrossDisplayRestore space correction

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Toggle/ToggleEngine+Restore.swift:400-434` (post-AX space correction in performCrossDisplayRestore)

- [ ] **Step 1: 增强 performCrossDisplayRestore 的 post-AX space 修正逻辑**

当 AX apply 后窗口在错误 space 时，当前逻辑只调 `moveWindow` 一次然后放弃。改为多轮重试，先 dismiss Mission Control 再重试 yabai move + CGEvent fallback。

替换 `Sources/Toggle/ToggleEngine+Restore.swift:402-434`（从 `if let actualSpace` 到该 if block 的 `}`）:

```swift
        if let actualSpace = spaceController.windowSpaceIndex(windowID: postMoveWindowID),
           actualSpace != record.sourceSpace {
            log("[ToggleEngine] restore: window on wrong space after AX apply, starting space correction", level: .warn, fields: [
                "traceID": traceID,
                "effectiveWindowID": String(postMoveWindowID),
                "actualSpace": String(actualSpace),
                "targetSpace": String(record.sourceSpace)
            ])

            // 尝试 1: 直接 moveWindow (yabai + NativeSpaceBridge)
            if spaceController.moveWindow(postMoveWindowID, toSpaceIndex: record.sourceSpace, focus: false, operationID: traceID) {
                if spaceController.windowSpaceIndex(windowID: postMoveWindowID) == record.sourceSpace {
                    log("[ToggleEngine] restore: moveWindow correction succeeded", fields: [
                        "traceID": traceID, "windowID": String(postMoveWindowID), "targetSpace": String(record.sourceSpace)
                    ])
                } else {
                    log("[ToggleEngine] restore: moveWindow reported success but window still on wrong space", level: .warn, fields: [
                        "traceID": traceID, "windowID": String(postMoveWindowID)
                    ])
                }
            }

            // 验证是否修正成功
            let correctedSpace = spaceController.windowSpaceIndex(windowID: postMoveWindowID)
            if correctedSpace == record.sourceSpace {
                // 成功
            } else {
                // 尝试 2: 切换到目标 space 再移动
                log("[ToggleEngine] restore: trying switchDisplayToSpace + moveWindow combo", level: .warn, fields: [
                    "traceID": traceID,
                    "targetSpace": String(record.sourceSpace),
                    "currentSpace": String(describing: correctedSpace)
                ])
                _ = spaceController.switchDisplayToSpace(targetSpace: record.sourceSpace, operationID: traceID)
                usleep(100_000)
                _ = spaceController.moveWindow(postMoveWindowID, toSpaceIndex: record.sourceSpace, focus: false, operationID: traceID)
            }

            // 最终验证
            let finalSpace = spaceController.windowSpaceIndex(windowID: postMoveWindowID)
            if let final = finalSpace, final != record.sourceSpace {
                log("[ToggleEngine] restore: all space corrections failed, switching display to actual space for visibility", level: .warn, fields: [
                    "traceID": traceID,
                    "effectiveWindowID": String(postMoveWindowID),
                    "actualSpace": String(final),
                    "targetSpace": String(record.sourceSpace)
                ])
                let switched = spaceController.switchDisplayToSpace(targetSpace: final, operationID: traceID)
                log("[ToggleEngine] restore: display switch to actual space result", fields: [
                    "traceID": traceID,
                    "switched": String(switched),
                    "actualSpace": String(final)
                ])
            }
        }
```

- [ ] **Step 2: 验证编译**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 3: 提交**
Run: `git add Sources/Toggle/ && git commit -m "fix(restore): multi-round space correction after AX apply"`

---

### Task 3: Add SA degradation detection at restore start

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Toggle/ToggleEngine+Restore.swift:125-145` (pre-restore phase)

- [ ] **Step 1: 在 restore 开始前检测 SA 状态并在需要时刷新**

在 `ToggleEngine+Restore.swift` 的 pre-restore phase（record frame check 之后，setWindowFloat 之前），添加 SA 健康检查。当检测到 SA 问题时强制刷新 availability。

在 `Sources/Toggle/ToggleEngine+Restore.swift:115`（`// 3. 先将窗口设为浮动状态` 注释之前）插入：

```swift
        // 2.5 检测 SA 可用性 — 如果上次操作遇到 SA 错误，刷新状态
        // 避免 restore 过程中反复尝试已经失败的 yabai SA 命令
        if !spaceController.canControlSpaces {
            log("[ToggleEngine] restore: SA not available, forcing refresh before restore", level: .warn, fields: [
                "traceID": trace, "windowID": String(windowID)
            ])
            spaceController.refreshAvailability(force: true)
        }
```

- [ ] **Step 2: 验证编译**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 3: 提交**
Run: `git add Sources/Toggle/ && git commit -m "fix(restore): refresh SA availability before restore when degraded"`

---

### Task 4: Quality gate — full build + grep verification

**Depends on:** Task 1, Task 2, Task 3
**Files:** None (verification only)

- [ ] **Step 1: Full build verification**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 2: Verify dismissMissionControl exists**
Run: `grep -n "dismissMissionControl" Sources/Space/NativeSpaceBridge.swift`
Expected:
  - Output contains at least 2 lines (definition + call site)

- [ ] **Step 3: Verify mission-control handling in switchDisplayToSpace**
Run: `grep -n "mission-control\|isMCBlocking" Sources/Space/SpaceController+Switch.swift`
Expected:
  - Output contains at least 3 lines (stderr check + dismiss call + log)
