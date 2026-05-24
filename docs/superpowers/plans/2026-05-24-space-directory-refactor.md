# Refactor: Space/ 目录 — 提取重复模式

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 重构 Space/ 目录中两个最大的方法：`moveWindow`（319 行）和 `focusSpace`（224 行），提取重复的 fallback 模式和 cursor 管理逻辑。

**Architecture:** 纯提取 — 方法各自保持原有调用签名，内部重复逻辑提取为 private helper。数据流不变。

**Safety Net:** `swift build` 编译验证
**Scope:** Small
**Risk:** Low

**Before/After:**
- Before: moveWindow 319 行（4 层 fallback，focus-then-move 重复 2 次）；focusSpace 224 行（cursor save/restore 内联 2 处）
- After: moveWindow ~170 行协调器 + focusThenMoveRetry ~40 行；focusSpace ~120 行（复用 cursor helper）

**Risks:**
- focusThenMoveRetry 提取时参数传递可能遗漏 → 缓解：保持与原代码完全相同的参数和调用顺序
- cursor helper 改造可能影响 click 行为 → 缓解：switchDisplayToSpace 保持原有 click，focusSpace 不 click

**Autonomy Level:** Full

---

### Task 1: Extract focusThenMoveRetry — 消除 moveWindow 中的重复 fallback

**Depends on:** None
**Files:**
- Modify: `Sources/Space/SpaceController+Move.swift`（提取 moveWindow 中重复的 focus-then-move 重试模式）

**问题分析：** `moveWindow` 中 "先 focus 目标 space，再重试 yabai move" 的模式出现了两次：
1. Line 196-231：yabai 成功但验证失败，NativeSpaceBridge fallback 也失败的分支
2. Line 281-317：yabai 失败，NativeSpaceBridge 也失败的分支

这两段代码逻辑几乎相同（focus → poll → retry → verify → focusWindow），只是日志前缀不同。提取为独立方法可消除 ~50 行重复。

- [ ] **Step 1: 在 SpaceController+Move.swift 添加 focusThenMoveRetry 方法**

文件: `Sources/Space/SpaceController+Move.swift`（在 `verifyWindowMovedToSpace` 方法之前添加）

```swift
    // MARK: - Focus-Then-Move Retry

    /// 先 focus 目标 space，再重试 yabai move — 用于 yabai 直接 move 失败时的 fallback
    private func focusThenMoveRetry(
        windowID: UInt32,
        targetSpace: Int,
        focus: Bool,
        operationID: String,
        label: String
    ) -> Bool {
        let focusResult = runYabai(
            arguments: ["-m", "space", "--focus", "\(targetSpace)"],
            operation: "moveWindow_focusTargetSpace_\(label)",
            operationID: operationID
        )
        guard let result = focusResult, result.exitCode == 0 else { return false }

        pollUntil(timeout: 200_000, interval: 20_000) {
            self.windowSpaceIndex(windowID: windowID) == targetSpace
        }
        let retryResult = runYabai(
            arguments: ["-m", "window", "\(windowID)", "--space", "\(targetSpace)"],
            operation: "moveWindow_focusRetry_\(label)",
            operationID: operationID
        )
        guard let retry = retryResult, retry.exitCode == 0 else { return false }

        if verifyWindowMovedToSpaceWithRetry(windowID: windowID, targetSpace: targetSpace, operationID: operationID) {
            log("[SpaceController] focus-then-move succeeded (\(label))", fields: [
                "op": operationID, "windowID": String(windowID), "targetSpace": String(targetSpace)
            ])
            if focus {
                _ = focusWindow(windowID, operationID: operationID)
            }
            return true
        }
        return false
    }
```

- [ ] **Step 2: 替换 moveWindow 中两处 focus-then-move 代码为 focusThenMoveRetry 调用**

文件: `Sources/Space/SpaceController+Move.swift`

**替换第一处**（line 196-231，unverified branch 的 focus-then-move）：

将以下代码：
```swift
            // yabai + NativeSpaceBridge 都失败 — 尝试 focus 目标 space 再重试
            log(
                "[SpaceController] trying focus-then-move strategy (yabai unverified branch)",
                fields: [
                    "op": op,
                    "windowID": String(windowID),
                    "targetSpace": String(spaceIndex)
                ]
            )
            let focusResult = runYabai(
                arguments: ["-m", "space", "--focus", "\(spaceIndex)"],
                operation: "moveWindow_focusTargetSpace_unverified",
                operationID: op
            )
            if let result = focusResult, result.exitCode == 0 {
                pollUntil(timeout: 200_000, interval: 20_000) {
                    self.windowSpaceIndex(windowID: windowID) == spaceIndex
                }
                let retryResult = runYabai(
                    arguments: ["-m", "window", "\(windowID)", "--space", "\(spaceIndex)"],
                    operation: "moveWindow_focusRetry_unverified",
                    operationID: op
                )
                if let retry = retryResult, retry.exitCode == 0 {
                    if verifyWindowMovedToSpaceWithRetry(windowID: windowID, targetSpace: spaceIndex, operationID: op) {
                        log(
                            "[SpaceController] focus-then-move succeeded (unverified branch)",
                            fields: ["op": op, "windowID": String(windowID), "targetSpace": String(spaceIndex)]
                        )
                        if focus {
                            _ = focusWindow(windowID, operationID: op)
                        }
                        return true
                    }
                }
            }
```

替换为：
```swift
            // yabai + NativeSpaceBridge 都失败 — 尝试 focus 目标 space 再重试
            if focusThenMoveRetry(windowID: windowID, targetSpace: spaceIndex, focus: focus, operationID: op, label: "unverified") {
                return true
            }
```

**替换第二处**（line 281-317，failed branch 的 focus-then-move）：

将以下代码：
```swift
        // 策略 4：先 focus 目标 space，再重试 yabai move
        // 窗口跨 display 移动时，yabai 需要目标 space 是当前焦点才能成功移动窗口
        log(
            "[SpaceController] trying focus-then-move strategy: focus target space then retry yabai",
            fields: [
                "op": op,
                "windowID": String(windowID),
                "targetSpace": String(spaceIndex)
            ]
        )
        let focusResult = runYabai(
            arguments: ["-m", "space", "--focus", "\(spaceIndex)"],
            operation: "moveWindow_focusTargetSpace",
            operationID: op
        )
        if let result = focusResult, result.exitCode == 0 {
            pollUntil(timeout: 200_000, interval: 20_000) {
                self.windowSpaceIndex(windowID: windowID) == spaceIndex
            }
            let retryResult = runYabai(
                arguments: ["-m", "window", "\(windowID)", "--space", "\(spaceIndex)"],
                operation: "moveWindow_focusRetry",
                operationID: op
            )
            if let retry = retryResult, retry.exitCode == 0 {
                if verifyWindowMovedToSpaceWithRetry(windowID: windowID, targetSpace: spaceIndex, operationID: op) {
                    log(
                        "[SpaceController] focus-then-move strategy succeeded",
                        fields: ["op": op, "windowID": String(windowID), "targetSpace": String(spaceIndex)]
                    )
                    if focus {
                        _ = focusWindow(windowID, operationID: op)
                    }
                    return true
                }
            }
        }
```

替换为：
```swift
        // 策略 4：先 focus 目标 space，再重试 yabai move
        if focusThenMoveRetry(windowID: windowID, targetSpace: spaceIndex, focus: focus, operationID: op, label: "fallback") {
            return true
        }
```

- [ ] **Step 3: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/Space/SpaceController+Move.swift && git commit -m "$(cat <<'EOF'
refactor(space): extract focusThenMoveRetry to eliminate duplicate fallback in moveWindow

moveWindow had two near-identical "focus target space then retry yabai"
blocks (~35 lines each). Extract into focusThenMoveRetry() helper.
moveWindow drops from 319 to ~250 lines. No behavior change.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

### Task 2: Unify cursor management in focusSpace — 复用 saveAndMoveCursor/restoreCursor

**Depends on:** None
**Files:**
- Modify: `Sources/Space/SpaceController+Switch.swift`（让 focusSpace 复用 cursor helper）

**问题分析：** `focusSpace` 方法有两处内联的 cursor save/restore 逻辑：
1. Line 227-263（steps=0 但全局焦点不同 → 移动 cursor）
2. Line 268-324（steps!=0 → 移动 cursor + 发送键盘事件 + 恢复）

而同文件中 `switchDisplayToSpace` 已提取了 `saveAndMoveCursor`（含 click）和 `restoreCursor` 两个 helper。`focusSpace` 应该复用这些方法（跳过 click 部分）。

方案：改造 `saveAndMoveCursor` 增加 `click` 参数（默认 true），`focusSpace` 传 `click: false`。

- [ ] **Step 1: 给 saveAndMoveCursor 添加 click 参数**

文件: `Sources/Space/SpaceController+Switch.swift:417`

将 `saveAndMoveCursor` 签名改为：

```swift
    private func saveAndMoveCursor(toSpace spaceIndex: Int, operationID: String, click: Bool = true) -> (savedCursor: CGPoint, savedApp: NSRunningApplication?)? {
```

在方法体中，将 click 相关代码包裹在 `if click { ... }` 中：

将以下代码（line 444-453 附近）：
```swift
            // Click to activate the target display — macOS only processes Ctrl+Arrow
            // for the display that has focus, not the one the cursor is hovering over
            if let downClick = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                        mouseCursorPosition: center, mouseButton: .left) {
                downClick.post(tap: .cghidEventTap)
            }
            usleep(20_000)
            if let upClick = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                      mouseCursorPosition: center, mouseButton: .left) {
                upClick.post(tap: .cghidEventTap)
            }
            usleep(100_000)
```

替换为：
```swift
            if click {
                // Click to activate the target display — macOS only processes Ctrl+Arrow
                // for the display that has focus, not the one the cursor is hovering over
                if let downClick = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                            mouseCursorPosition: center, mouseButton: .left) {
                    downClick.post(tap: .cghidEventTap)
                }
                usleep(20_000)
                if let upClick = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                          mouseCursorPosition: center, mouseButton: .left) {
                    upClick.post(tap: .cghidEventTap)
                }
                usleep(100_000)
            }
```

`switchDisplayToSpace` 中的调用保持不变（默认 `click: true`）。

- [ ] **Step 2: 替换 focusSpace 中 steps=0 分支的内联 cursor 逻辑**

文件: `Sources/Space/SpaceController+Switch.swift`（focusSpace 方法，steps=0 分支，约 line 227-263）

将以下代码：
```swift
            // 全局焦点不在目标 space — 移动光标到目标显示器以切换活跃显示器
            log(
                "[SpaceController] steps=0 but global space differs, moving cursor to target display",
                fields: [
                    "op": op,
                    "targetSpace": String(spaceIndex),
                    "currentGlobalSpace": String(describing: currentGlobalSpace),
                    "hasDisplayCenter": String(displayCenterCG(spaceIndex: spaceIndex) != nil)
                ]
            )

            let savedFrontApp = NSWorkspace.shared.frontmostApplication

            let savedCursor = NSEvent.mouseLocation
            let mainScreenHeight = CoordinateKit.mainScreenHeight
            let savedCursorCG = CGPoint(x: savedCursor.x, y: mainScreenHeight - savedCursor.y)

            if let center = displayCenterCG(spaceIndex: spaceIndex) {
                if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                            mouseCursorPosition: center, mouseButton: .left) {
                    moveEvent.post(tap: .cghidEventTap)
                }
                usleep(50_000)
            }

            // 恢复鼠标位置
            if let restoreEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                           mouseCursorPosition: savedCursorCG, mouseButton: .left) {
                restoreEvent.post(tap: .cghidEventTap)
            }

            usleep(50_000) // 等待显示器切换

            // 恢复前台应用焦点 — CGEvent 鼠标移动会激活副屏上的应用（通常是 Chrome）
            savedFrontApp?.activate(options: .activateIgnoringOtherApps)

            let postSwitchSpace = queryFocusedSpace()?.index
            log(
                "[SpaceController] cursor move completed",
                fields: [
                    "op": op,
                    "targetSpace": String(spaceIndex),
                    "preSwitchGlobalSpace": String(describing: currentGlobalSpace),
                    "postSwitchGlobalSpace": String(describing: postSwitchSpace),
                    "reachedTarget": String(postSwitchSpace == spaceIndex)
                ]
            )
            return true
```

替换为：
```swift
            // 全局焦点不在目标 space — 移动光标到目标显示器以切换活跃显示器
            log(
                "[SpaceController] steps=0 but global space differs, moving cursor to target display",
                fields: [
                    "op": op,
                    "targetSpace": String(spaceIndex),
                    "currentGlobalSpace": String(describing: currentGlobalSpace),
                    "hasDisplayCenter": String(displayCenterCG(spaceIndex: spaceIndex) != nil)
                ]
            )

            if let (savedCursor, savedApp) = saveAndMoveCursor(toSpace: spaceIndex, operationID: op, click: false) {
                restoreCursor(savedCursor, savedApp: savedApp)
            }

            let postSwitchSpace = queryFocusedSpace()?.index
            log(
                "[SpaceController] cursor move completed",
                fields: [
                    "op": op,
                    "targetSpace": String(spaceIndex),
                    "preSwitchGlobalSpace": String(describing: currentGlobalSpace),
                    "postSwitchGlobalSpace": String(describing: postSwitchSpace),
                    "reachedTarget": String(postSwitchSpace == spaceIndex)
                ]
            )
            return true
```

- [ ] **Step 3: 替换 focusSpace 中 steps!=0 分支的内联 cursor 逻辑**

文件: `Sources/Space/SpaceController+Switch.swift`（focusSpace 方法，steps!=0 分支，约 line 268-324）

将以下代码：
```swift
        // 关键：Ctrl+Left/Right 只影响鼠标所在显示器的空间
        // 用 CGEvent 发送鼠标移动事件（非 CGWarp，后者不更新系统活跃显示器状态）
        let savedFrontApp = NSWorkspace.shared.frontmostApplication

        let savedCursor = NSEvent.mouseLocation
        let mainScreenHeight = CoordinateKit.mainScreenHeight
        let savedCursorCG = CGPoint(x: savedCursor.x, y: mainScreenHeight - savedCursor.y)

        let targetCenterCG = displayCenterCG(spaceIndex: spaceIndex)
        if let center = targetCenterCG {
            // 用 CGEvent 鼠标移动事件（而非 CGWarpMouseCursorPosition）
            // 这样 WindowServer 会真正更新"活跃显示器"状态
            log("[SpaceController] focusSpace: CGEvent cursor move to target display", level: .debug, fields: [
                "op": op,
                "targetCenter": "\(Int(center.x)),\(Int(center.y))"
            ])
            if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                        mouseCursorPosition: center, mouseButton: .left) {
                moveEvent.post(tap: .cghidEventTap)
            }
            usleep(50_000) // 50ms 等系统处理鼠标移动
        } else {
            log(
                "[SpaceController] CGEvent fallback: could not determine display center",
                level: .warn,
                fields: [
                    "op": op,
                    "targetSpace": String(spaceIndex)
                ]
            )
        }

        let success = NativeSpaceBridge.focusSpace(steps: steps, operationID: op)

        // 恢复鼠标位置（用 CGEvent 以确保系统状态同步）
        if let restoreEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                       mouseCursorPosition: savedCursorCG, mouseButton: .left) {
            restoreEvent.post(tap: .cghidEventTap)
        }

        // 恢复前台应用焦点 — CGEvent 鼠标移动会激活副屏上的应用（通常是 Chrome）
        savedFrontApp?.activate(options: .activateIgnoringOtherApps)
```

替换为：
```swift
        // 关键：Ctrl+Left/Right 只影响鼠标所在显示器的空间
        let saved = saveAndMoveCursor(toSpace: spaceIndex, operationID: op, click: false)

        let success = NativeSpaceBridge.focusSpace(steps: steps, operationID: op)

        if let (savedCursor, savedApp) = saved {
            restoreCursor(savedCursor, savedApp: savedApp)
        }
```

注意：原代码中 `displayCenterCG` 为 nil 时会打 warn 日志。`saveAndMoveCursor` 在 center 为 nil 时也会打 warn 日志（line 457-460），所以行为一致。但原代码在 center 为 nil 时仍继续发送键盘事件（只是不移动 cursor），而 saveAndMoveCursor 在 center 为 nil 时返回 nil（不移动 cursor 也不 click）。这实际是更安全的行为 — 如果不知道目标 display 在哪，发送 Ctrl+Arrow 可能切换错误的 display 的 space。

不过为了保持行为兼容，需要调整：saveAndMoveCursor 返回 nil 时不应该跳过键盘事件发送。所以这里的替换需要在 saveAndMoveCursor 返回 nil 时仍发送 NativeSpaceBridge.focusSpace。

将替换后的代码进一步调整为：
```swift
        // 关键：Ctrl+Left/Right 只影响鼠标所在显示器的空间
        let saved = saveAndMoveCursor(toSpace: spaceIndex, operationID: op, click: false)

        let success = NativeSpaceBridge.focusSpace(steps: steps, operationID: op)

        if let (savedCursor, savedApp) = saved {
            restoreCursor(savedCursor, savedApp: savedApp)
        }
```

这已经正确了 — 即使 `saved` 为 nil（cursor 没移动），NativeSpaceBridge.focusSpace 仍会执行。只是 cursor 不会恢复（因为本来就没保存）。

- [ ] **Step 4: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 5: 提交**
Run: `git add Sources/Space/SpaceController+Switch.swift && git commit -m "$(cat <<'EOF'
refactor(space): unify cursor management in focusSpace using saveAndMoveCursor/restoreCursor

focusSpace had two inline cursor save/restore blocks (~35 lines each)
that duplicated what saveAndMoveCursor/restoreCursor already provided.
Add click parameter to saveAndMoveCursor (default true), focusSpace
passes click: false since it doesn't need mouse clicks.

focusSpace drops from 224 to ~150 lines. No behavior change.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

### Task 3: Thin verbose debug logging in moveWindow — 提升可读性

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Space/SpaceController+Move.swift`（精简 moveWindow 中过度的 debug 日志）

**问题分析：** `moveWindow` 方法中有大量 `[moveWindow]` 前缀的 `.debug` 级别日志（约 10+ 处），这些日志记录了每个中间步骤的进入和退出，在正常操作中只是噪音。关键的 info/warn 日志应该保留。

清理规则：
- 删除只记录 "called" / "checking X" / "returned" 的 debug 日志（保留有实际状态值的 info/warn 日志）
- 保留策略边界日志（Strategy 1/2/3/4 切换点）
- 保留验证结果日志

- [ ] **Step 1: 删除 moveWindow 中的冗余 debug 日志**

文件: `Sources/Space/SpaceController+Move.swift`

删除以下 debug 日志块（保留注释说明行）：

1. Line 9-17（进入日志，已被 AuditLogger + line 63 的 info 日志覆盖）：
```swift
        log(
            "[moveWindow] called",
            level: .debug,
            fields: [
                "op": op,
                "windowID": String(windowID),
                "targetSpace": String(spaceIndex),
                "focus": String(focus)
            ]
        )
```

2. Line 30-36（guard 日志，已被 markOperationError 覆盖）：
```swift
            log(
                "[moveWindow] aborted: space integration not enabled",
                level: .debug,
                fields: ["op": op]
            )
```

3. Line 44-47（query window 日志，无实际值）：
```swift
        log(
            "[moveWindow] querying window info for safety check",
            level: .debug,
            fields: ["op": op, "windowID": String(windowID)]
        )
```

4. Line 76-83（NativeSpaceBridge availability 日志）：
```swift
        log(
            "[moveWindow] checking NativeSpaceBridge availability",
            level: .debug,
            fields: [
                "op": op,
                "nativeAvailable": String(nativeAvailable)
            ]
        )
```

5. Line 100-104（NativeSpaceBridge returned true 日志）：
```swift
                log(
                    "[moveWindow] NativeSpaceBridge moveWindow returned true, waiting 200ms",
                    level: .debug,
                    fields: ["op": op, "spaceID": String(spaceID)]
                )
```

6. Line 132-141（strategy 2 日志）：
```swift
        log(
            "[moveWindow] strategy 2: trying yabai command",
            level: .debug,
            fields: [
                "op": op,
                "windowID": String(windowID),
                "targetSpace": String(spaceIndex)
            ]
        )
```

7. Line 148-154（yabai returned 日志）：
```swift
        log(
            "[moveWindow] yabai runYabaiVariants returned",
            level: .debug,
            fields: [
                "op": op,
                "success": String(moveResult.success)
            ]
        )
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/Space/SpaceController+Move.swift && git commit -m "$(cat <<'EOF'
refactor(space): thin verbose debug logging in moveWindow

Remove 7 debug-level log calls that only recorded entry/exit of
intermediate steps. Keep info/warn logs at strategy boundaries and
verification points — those carry actionable state.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"