# Fix: Restore Applies Wrong-Screen Coordinates When Space Move Fails

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复窗口从主屏幕还原时，若 Space 移动失败（yabai + NativeSpaceBridge 均失败），系统仍然应用副屏坐标（如 Y=-530），导致窗口出现在主屏幕底部而非副屏幕上的 bug。修复方式：在应用 origFrame 之前验证窗口是否真正到达目标 Space，若未到达则中止还原。

**Architecture:** 还原流程：load record → 找 AX element → 验证当前位置 → **切换到原始 Space** → **验证 Space 切换成功** → apply origFrame。当前 bug 在于加粗的两步之间缺少验证：`switchToOriginalSpace` 返回 Void（不传递失败），`restore` 无条件执行 `apply(frame: origFrame)`。修复方式：(1) `switchToOriginalSpace` 改为返回 Bool；(2) `restore` 检查返回值，失败时中止；(3) WindowManager+Restore 的同一路径同样增加验证。

**Tech Stack:** Swift 5.9+, macOS 14+, CoreGraphics AX API

**Risks:**
- 窗口在错误 Space 时中止还原意味着用户需要重试，但比还原到主屏底部（完全不可用）要好 → 缓解：失败日志包含完整上下文，便于排查 Space 移动失败的原因
- NativeSpaceBridge 300 秒冷却期导致同一窗口在 5 分钟内无法移动 → 这是已有行为，本修复不改变它，只是让还原流程感知到这个失败

---

### Task 1: 修复 ToggleEngine.restore — switchToOriginalSpace 返回结果并在失败时中止还原

**Depends on:** None
**Files:**
- Modify: `Sources/Toggle/ToggleEngine.swift:162-175`（switchToOriginalSpace 调用处 + 函数签名）
- Modify: `Sources/Toggle/ToggleEngine.swift:194`（函数签名改为返回 Bool）
- Modify: `Sources/Toggle/ToggleEngine.swift:216-284`（两个 moveWindow 调用点返回结果）

- [ ] **Step 1: 修改 switchToOriginalSpace 函数签名 — 返回 Bool 表示 Space 切换是否成功**
文件: `Sources/Toggle/ToggleEngine.swift:194`

```swift
    private func switchToOriginalSpace(record: ToggleRecord, windowAX: AXUIElement, triggerSource: String, traceID: String) -> Bool {
```

- [ ] **Step 2: 修改 switchToOriginalSpace 内部逻辑 — 在关键路径返回 Bool**
文件: `Sources/Toggle/ToggleEngine.swift:210-284`

替换整个 `switchToOriginalSpace` 函数体（从 `let spaceController` 开始到函数结束）：

```swift
        let spaceController = SpaceController.shared
        let targetSpace = record.sourceSpace
        let targetDisplay = record.sourceYabaiDisp

        // 查询目标 display 当前显示的 space（不是窗口所在的 space）
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
            // display 已经在正确 space，只需移动窗口到该 space
            let moved = spaceController.moveWindow(
                record.windowID,
                toSpaceIndex: targetSpace,
                focus: false,
                operationID: traceID
            )
            if !moved {
                log("ToggleEngine.switchToOriginalSpace: moveWindow failed (display already on correct space)", level: .warn, fields: [
                    "traceID": traceID,
                    "windowID": String(record.windowID),
                    "targetSpace": String(targetSpace)
                ])
                return false
            }
            return true
        }

        log("ToggleEngine.switchToOriginalSpace: need space switch", fields: [
            "traceID": traceID,
            "displayCurrentSpace": String(describing: displayCurrentSpace),
            "targetSpace": String(targetSpace),
            "targetDisplay": String(describing: targetDisplay),
            "sourceYabaiDisp": String(record.sourceYabaiDisp)
        ])

        // 目标 display 不在正确 space — 需要先切换 display 的 space 再移动窗口
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
                // 轮询等待 display 到达目标 space（替代固定 400ms sleep）
                let td = targetDisplay
                let started = Date()
                while Date().timeIntervalSince(started) < 0.4 {
                    if spaceController.displayVisibleSpace(displayIndex: td) == targetSpace { break }
                    usleep(30_000)
                }
            } else {
                log("ToggleEngine.switchToOriginalSpace: switchDisplayToSpace failed", level: .warn, fields: [
                    "traceID": traceID,
                    "targetSpace": String(targetSpace)
                ])
                return false
            }
        }

        // 移动窗口到目标 space
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
            // 快速验证窗口已在目标 space（替代固定 200ms）
            let started = Date()
            while Date().timeIntervalSince(started) < 0.2 {
                if let s = spaceController.windowSpaceIndex(windowID: record.windowID), s == targetSpace { break }
                usleep(20_000)
            }
            return true
        } else {
            log("ToggleEngine.switchToOriginalSpace: moveWindow failed, aborting restore", level: .warn, fields: [
                "traceID": traceID,
                "windowID": String(record.windowID),
                "targetSpace": String(targetSpace)
            ])
            return false
        }
    }
```

- [ ] **Step 3: 修改 restore 方法 — 检查 switchToOriginalSpace 返回值，失败时中止**
文件: `Sources/Toggle/ToggleEngine.swift:161-175`

替换第 161-175 行（步骤 4 和 5 + 步骤 6 的开头）：

```swift
        // 4. 先切换到原始 space（必须在 apply frame 之前，因为坐标是相对于目标屏幕的）
        let spaceSwitched = switchToOriginalSpace(record: record, windowAX: windowAX, triggerSource: triggerSource, traceID: trace)
        if !spaceSwitched {
            log("ToggleEngine.restore: space switch failed, aborting restore to avoid applying wrong-screen coordinates", level: .error, fields: [
                "traceID": trace,
                "windowID": String(windowID),
                "targetSpace": String(record.sourceSpace),
                "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y)) \(Int(record.origFrame.size.width))x\(Int(record.origFrame.size.height))"
            ])
            return false
        }

        // 5. 切换完成后重新获取 AX element（space 切换可能使旧引用失效）
        guard let restoreAX = wm.findWindowByPID(record.pid, windowID: record.windowID) else {
            log("ToggleEngine.restore: AX element lost after space switch, cannot continue", level: .error, fields: [
                "traceID": trace,
                "windowID": String(windowID),
                "pid": String(record.pid)
            ])
            return false
        }

        // 6. 设置恢复 frame（此时窗口已在正确的屏幕/工作区上，坐标系统匹配）
```

- [ ] **Step 4: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 5: 提交**
Run: `git add Sources/Toggle/ToggleEngine.swift && git commit -m "fix(toggle): abort restore when space move fails, preventing wrong-screen frame application"`

---

### Task 2: 修复 WindowManager.restore — Space 切换后验证窗口是否真正到达目标 Space

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowManager+Restore.swift:163-212`（Space 切换 + moveWindow 部分）

- [ ] **Step 1: 在 WindowManager.restore 的 Space 切换后添加 moveWindow 调用和验证**
文件: `Sources/Window/WindowManager+Restore.swift:163-202`

当前代码在 Space 切换后（第 194 行）直接跳到"重新获取 AX element"，完全没有调用 moveWindow 将窗口移到目标 Space。替换第 163-202 行：

```swift
        // 8. Space 预切换（在 apply frame 之前，因为坐标相对于 Display）
        let displayCurrentSpace = spaceController.displayVisibleSpace(displayIndex: targetDisplay)
        log("[WindowManager] restore: pre-apply space check", fields: [
            "op": op,
            "targetSpace": String(targetSpace),
            "targetDisplay": String(targetDisplay),
            "displayCurrentSpace": String(describing: displayCurrentSpace)
        ])

        var spaceReady = false

        if let current = displayCurrentSpace, current == targetSpace {
            // Display 已经在目标 Space，只需移动窗口
            log("[WindowManager] restore: display already on target space, moving window", fields: [
                "op": op, "targetSpace": String(targetSpace)
            ])
            let moved = spaceController.moveWindow(currentWindowID, toSpaceIndex: targetSpace, focus: false, operationID: op)
            if moved {
                // 快速验证窗口已到达目标 Space
                let started = Date()
                while Date().timeIntervalSince(started) < 0.2 {
                    if let s = spaceController.windowSpaceIndex(windowID: currentWindowID), s == targetSpace { break }
                    usleep(20_000)
                }
                spaceReady = true
            } else {
                log("[WindowManager] restore: moveWindow failed (display on target space)", level: .warn, fields: [
                    "op": op, "windowID": String(currentWindowID), "targetSpace": String(targetSpace)
                ])
            }
        } else if let current = displayCurrentSpace, current != targetSpace {
            log("[WindowManager] restore: switching display from space \(current) to \(targetSpace)", level: .info, fields: [
                "op": op, "targetDisplay": String(targetDisplay)
            ])
            let switched = spaceController.switchDisplayToSpace(targetSpace: targetSpace, operationID: op)
            if switched {
                // 轮询等待 display 到达目标 space（替代固定 400ms sleep）
                let td = targetDisplay
                let started = Date()
                while Date().timeIntervalSince(started) < 0.4 {
                    if spaceController.displayVisibleSpace(displayIndex: td) == targetSpace { break }
                    usleep(30_000)
                }

                // 移动窗口到目标 Space
                let moved = spaceController.moveWindow(currentWindowID, toSpaceIndex: targetSpace, focus: triggerSource == "carbon_hotkey", operationID: op)
                if moved {
                    let started = Date()
                    while Date().timeIntervalSince(started) < 0.2 {
                        if let s = spaceController.windowSpaceIndex(windowID: currentWindowID), s == targetSpace { break }
                        usleep(20_000)
                    }
                    spaceReady = true
                } else {
                    log("[WindowManager] restore: moveWindow failed after display switch", level: .warn, fields: [
                        "op": op, "windowID": String(currentWindowID), "targetSpace": String(targetSpace)
                    ])
                }
            } else {
                log("[WindowManager] restore: switchDisplayToSpace failed", level: .warn, fields: [
                    "op": op, "targetSpace": String(targetSpace)
                ])
            }
        } else {
            log("[WindowManager] restore: could not determine display current space", level: .warn, fields: [
                "op": op, "targetDisplay": String(targetDisplay)
            ])
        }

        if !spaceReady {
            log("[WindowManager] restore: window not on target space, aborting to avoid wrong-screen coordinates", level: .error, fields: [
                "op": op,
                "windowID": String(currentWindowID),
                "targetSpace": String(targetSpace),
                "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y)) \(Int(origFrame.size.width))x\(Int(origFrame.size.height))"
            ])
            return
        }

        // 9. Space 切换后重新获取 AX element（引用可能失效）
        guard let restoreAX = findWindowByPID(record.pid, windowID: currentWindowID) else {
            log("[WindowManager] restore failed: AX element lost after space switch", level: .error, fields: [
                "op": op, "windowID": String(currentWindowID), "pid": String(record.pid)
            ])
            CrashContextRecorder.shared.record("restore_failed_ax_lost_after_space_switch op=\(op)")
            return
        }
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 3: 提交**
Run: `git add Sources/Window/WindowManager+Restore.swift && git commit -m "fix(window): add moveWindow + space verification in restore, abort if window not on target space"`
