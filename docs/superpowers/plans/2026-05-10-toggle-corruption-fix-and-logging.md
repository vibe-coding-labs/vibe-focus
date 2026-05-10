# Toggle Record Corruption Bug Fix + Logging Enhancement Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 toggle record 被 session_end 事件覆盖导致快捷键无法恢复窗口的 bug，同时增强关键路径的日志密度。

**Architecture:** 1) 在 moveWindowToMainScreen 中添加 windowID 一致性验证，AX resolve 后检查 CGWindowID 是否匹配请求的 identity.windowID，不匹配则中止。2) 在 ToggleEngine.save 中添加 origFrame 验证，拒绝保存 origFrame 在主屏上的无效记录。3) 在 toggle/restore/hook 关键决策点增加更详细的日志。

**Tech Stack:** Swift 5.9, macOS 14+, SQLite3

**Risks:**
- Bug A 的修复可能在某些边缘情况下阻止合法的 toggle 操作 → 缓解：不匹配时 log warn 但仍继续，只是用正确的 windowID
- Bug B 的 origFrame 验证可能过于严格 → 缓解：仅阻止 origFrame 在主屏的保存，这是明显的无效数据

---

### Task 1: 修复 moveWindowToMainScreen 的 windowID 不一致 bug

**Depends on:** None
**Files:**
- Modify: `Sources/WindowManager+MoveWindow.swift:199-235`

**Root Cause:** `resolveWindow(identity:)` 通过 PID+title 匹配窗口，但同一 PID 下可能有多个窗口。当 windowID=1976 被请求时，可能匹配到 windowID=110。随后 `windowHandle(for: windowAX)` 返回 110，但代码继续用 110 的 frame 和 space context 保存 toggle record，覆盖了 110 原有的有效 toggle record。

- [ ] **Step 1: 在 windowHandle 获取后添加一致性检查 — 使用原始 identity.windowID 而非 AX 返回的 windowID**

文件: `Sources/WindowManager+MoveWindow.swift:199-239`（替换 "window not on main screen, getting window handle" 区块到 space capture 之前）

```swift
        log(
            "[moveWindowToMainScreen] window not on main screen, getting window handle",
            level: .debug,
            fields: ["op": op]
        )

        guard let axWindowID = windowHandle(for: windowAX) else {
            log(
                "moveWindowToMainScreen failed: missing stable window handle",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            return false
        }

        // 验证 AX resolve 的窗口 ID 与请求的窗口 ID 一致
        // 如果不一致，说明 resolveWindow 匹配到了错误的窗口
        let effectiveWindowID: UInt32
        if axWindowID != identity.windowID {
            log(
                "[moveWindowToMainScreen] windowID mismatch: AX resolved \(axWindowID) but requested \(identity.windowID), using identity.windowID",
                level: .warn,
                fields: [
                    "op": op,
                    "requestedWindowID": String(identity.windowID),
                    "resolvedWindowID": String(axWindowID),
                    "pid": String(identity.pid)
                ]
            )
            effectiveWindowID = identity.windowID
        } else {
            effectiveWindowID = identity.windowID
        }

        guard isAttributeSettable(windowAX, attribute: kAXPositionAttribute),
              isAttributeSettable(windowAX, attribute: kAXSizeAttribute) else {
            log(
                "moveWindowToMainScreen failed: window attributes not settable",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            return false
        }

        log(
            "[moveWindowToMainScreen] got window handle, checking settable attributes",
            level: .debug,
            fields: [
                "op": op,
                "effectiveWindowID": String(effectiveWindowID),
                "requestedWindowID": String(identity.windowID),
                "axWindowID": String(axWindowID)
            ]
        )

        let sourceContext = displayContext(for: currentFrame)
        let spaceCaptureStartAt = Date()
        let spaceContext = spaceController.captureSpaceContext(windowID: effectiveWindowID, operationID: op)
```

- [ ] **Step 2: 修改后续代码中所有使用 currentWindowID 的地方改为 effectiveWindowID**

在同一个函数中，将 `currentWindowID` 的后续引用全部改为 `effectiveWindowID`。需要检查 `saveToggleRecord` 和 `ToggleEngine.save` 调用处的 windowID 参数。

读取文件 `Sources/WindowManager+MoveWindow.swift:239-310`，将所有 `currentWindowID` 替换为 `effectiveWindowID`。

- [ ] **Step 3: 验证编译通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/WindowManager+MoveWindow.swift && git commit -m "fix(toggle): validate windowID consistency in moveWindowToMainScreen to prevent cross-window toggle record corruption"`

---

### Task 2: 在 ToggleEngine.save 添加 origFrame 验证

**Depends on:** None
**Files:**
- Modify: `Sources/ToggleEngine.swift:23-65`（save 函数）

**Root Cause:** ToggleEngine.save 无条件接受任何 origFrame/targetFrame 组合。当 origFrame 在主屏时（由于 Bug A 或其他原因），保存的记录会在 restore 时被标记为 corrupted 并清除，导致该窗口永远无法恢复。

- [ ] **Step 1: 在 save 函数开头添加 origFrame 验证**

文件: `Sources/ToggleEngine.swift`，在 `save` 函数的 `func save(` 开始后、实际保存逻辑之前添加验证：

读取 `Sources/ToggleEngine.swift` 中 save 函数（约 line 23-65），在函数开头的 log 之前插入验证逻辑：

```swift
        // 验证 origFrame 不在主屏上 — 如果 origFrame 在主屏，说明数据异常
        let mainScreen = NSScreen.screens.first { $0.frame.origin == .zero }
        if let mainScreenFrame = mainScreen?.frame {
            let origCenter = CGPoint(x: origFrame.midX, y: origFrame.midY)
            if mainScreenFrame.contains(origCenter) {
                log(
                    "[ToggleEngine] save rejected: origFrame is on main screen (corrupted data)",
                    level: .warn,
                    fields: [
                        "windowID": String(windowID),
                        "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y)) \(Int(origFrame.size.width))x\(Int(origFrame.size.height))",
                        "targetFrame": "\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y)) \(Int(targetFrame.size.width))x\(Int(targetFrame.size.height))",
                        "sourceSpace": String(describing: sourceSpace),
                        "sourceYabaiDisp": String(describing: sourceYabaiDisp)
                    ]
                )
                return
            }
        }
```

- [ ] **Step 2: 验证编译通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/ToggleEngine.swift && git commit -m "fix(toggle): reject toggle record save when origFrame is on main screen"`

---

### Task 3: 增强关键决策点的日志密度

**Depends on:** Task 1
**Files:**
- Modify: `Sources/WindowManager+Toggle.swift`（toggle 决策分支）
- Modify: `Sources/HookEventHandler.swift`（UserPromptSubmit 决策分支）
- Modify: `Sources/WindowManager+Restore.swift`（restore 各步骤）

- [ ] **Step 1: 增强 toggle() 决策日志 — 在 restore vs moveToMain 决策后补充详细字段**

文件: `Sources/WindowManager+Toggle.swift`，在 toggle 函数的决策点（`shouldRestoreCurrentWindow` 调用后），将现有的 INFO 日志补充更多字段：当前窗口的 frame、屏幕位置、toggle record 状态（是否存在、是否 valid、origFrame/targetFrame 值）。

找到 `"[WindowManager] toggle decision"` 日志行，在其 fields 中补充：
```swift
"windowFrame": String(describing: currentFrame),
"isOnMainScreen": String(focusedOnMain),
"toggleRecordExists": String(ToggleEngine.shared.load(windowID: currentWindowID) != nil)
```

注意：变量名需读取实际函数确认。

- [ ] **Step 2: 增强 handleUserPromptSubmit() 解析日志 — 补充 binding 查找过程的完整上下文**

文件: `Sources/HookEventHandler.swift`，在 `handleUserPromptSubmit` 函数的 binding 查找后（无论成功失败），补充一条 INFO 级别日志包含：binding 查找结果、terminal context 可用字段、最终窗口所在屏幕、restore 决策原因。

- [ ] **Step 3: 增强 restore() 步骤日志 — 补充 frame 和 space 变化**

文件: `Sources/WindowManager+Restore.swift`，在 `restore` 函数的以下关键点补充 DEBUG 日志：
- space 切换结果：成功/失败、实际 space index
- frame 应用结果：应用前 frame vs 应用后 frame vs 目标 frame
- 清除 toggle record 前记录原始数据

- [ ] **Step 4: 验证编译通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 5: 提交**
Run: `git add Sources/WindowManager+Toggle.swift Sources/HookEventHandler.swift Sources/WindowManager+Restore.swift && git commit -m "feat(logging): enhance log density at toggle, restore, and hook decision points"`
