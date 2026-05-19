# Refactor: Toggle/Restore 管线冗余逻辑清理

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 删除 toggle/restore 管线中的死代码和冗余逻辑，精简 ~570 行代码，消除多次 bug 的根源——过度复杂的 fallback 链路和重复验证。

**Architecture:** 
- 数据流不变：热键/Hook → ToggleEngine.save/restore → SpaceController.switchDisplayToSpace → AX apply → RestoreWatchdog
- 清理方式：先删除确认无调用的死代码（零风险），再简化冗余逻辑（低风险）
- 不改变任何外部行为，只删减内部冗余

**Tech Stack:** Swift 5.9

**Scope:** Medium
**Risk:** Low — 只删除死代码和注释掉未使用的 fallback 链路

**Safety Net:** `swift build` 编译检查（无测试套件）+ 手动热键验证

**Before/After:**
- Before: ToggleEngine.restore() ~470 行，SpaceController+Move.swift ~441 行，3 套验证逻辑
- After: 每个模块减少 30-40%，单一验证路径

**Risks:**
- Task 2 注释 CGEvent drag fallback 可能影响极端边缘 case（AX apply 完全失效时） → 缓解：注释而不是删除，验证后可恢复
- Task 5 简化 moveWindow() 策略可能影响 yabai 无 SA 权限时 → 缓解：保留 yabai + NativeSpaceBridge 双策略，只删重复的策略

**Autonomy Level:** Full

---

### Task 1: 删除 SpaceController 模块死代码（零风险）

**Depends on:** None
**Files:**
- Modify: `Sources/Space/SpaceController+Move.swift:327-441` — 删除 `moveWindowToSpace()` (115 行)
- Modify: `Sources/Space/SpaceController+Context.swift:111-146` — 删除 `globalSpaceIndex()` (36 行)
- Modify: `Sources/Space/SpaceIndexResolver.swift:32-51` — 删除 `resolveStableIndex()` (20 行)

**Symptom:** 三个函数在整个代码库中零调用（grep 确认），是历史遗留的死代码。

**Root Cause:** `moveWindowToSpace()` 被 `moveWindow()` 替代但未删除；`globalSpaceIndex()` 被 CoordinateKit 替代；`resolveStableIndex()` 是未完成的功能。

- [ ] **Step 1: 删除 `moveWindowToSpace()` — 115 行从未被调用的死代码**

文件: `Sources/Space/SpaceController+Move.swift:327-441`

找到这个函数（以 `func moveWindowToSpace(windowID:Int` 开头），删除整个函数体（从 `///` 文档注释开始到函数的结束大括号）。

确认无调用：
```bash
grep -rn "moveWindowToSpace" Sources/ --include="*.swift"
```
Expected: 只在 SpaceController+Move.swift 的定义处出现，无其他调用。

- [ ] **Step 2: 删除 `globalSpaceIndex()` — 36 行从未被调用的死代码**

文件: `Sources/Space/SpaceController+Context.swift:111-146`

找到 `func globalSpaceIndex(displayIndex: Int, localSpaceIndex: Int) -> Int?` 函数，删除整个函数体。

确认无调用：
```bash
grep -rn "globalSpaceIndex" Sources/ --include="*.swift"
```
Expected: 只在定义处出现，无其他调用。

- [ ] **Step 3: 删除 `resolveStableIndex()` — 20 行从未被调用的死代码**

文件: `Sources/Space/SpaceIndexResolver.swift:32-51`

找到 `func resolveStableIndex` 函数，删除整个函数体。

确认无调用：
```bash
grep -rn "resolveStableIndex" Sources/ --include="*.swift"
```
Expected: 只在定义处出现，无其他调用。

- [ ] **Step 4: 验证编译通过**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 5: 提交**
Run: `git add Sources/Space/SpaceController+Move.swift Sources/Space/SpaceController+Context.swift Sources/Space/SpaceIndexResolver.swift && git commit -m "$(cat <<'EOF'
refactor(space): delete 171 lines of dead code — moveWindowToSpace, globalSpaceIndex, resolveStableIndex

Three functions with zero callers removed:
- moveWindowToSpace() (115 lines): superseded by moveWindow()
- globalSpaceIndex() (36 lines): superseded by CoordinateKit
- resolveStableIndex() (20 lines): incomplete feature never used

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

### Task 2: 注释 ToggleEngine.restore() 中的 CGEvent drag fallback

**Depends on:** None
**Files:**
- Modify: `Sources/Toggle/ToggleEngine.swift:313-360` — 注释 CGEvent drag fallback 块

**Symptom:** ToggleEngine.restore() 有 3 层 fallback（AX → CGEvent drag → AX retry），其中 CGEvent drag 是 AX apply "clamped" 到主屏时才触发的备用路径。但 AX clamping 检测本身就会先标记 restore 为 failed，导致 CGEvent drag 几乎从不执行。这段 47 行代码增加了复杂度但不提供实际价值。

**Root Cause:** 早期开发时担心 AX apply 不可靠而添加的防护，但实际运行中 AX apply 几乎总是成功。

- [ ] **Step 1: 找到 CGEvent drag fallback 代码块**

文件: `Sources/Toggle/ToggleEngine.swift`

找到大约在第 313-360 行的 CGEvent drag fallback 代码块。它通常以注释 `// Fallback: CGEvent drag` 或类似文字开始，包含 `CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged` 的代码。

将整个块用 `/* ... */` 包裹注释掉，在注释开头加一行说明：
```swift
// DISABLED: CGEvent drag fallback — AX apply 几乎总是成功，
// 此路径在实践中很少触发，增加了不必要的复杂度。
// 如果 AX restore 开始失败，可以重新启用。
```

**注意：** 不要误注释 AX apply 主路径（第 285 行 `restored = wm.apply(...)` 附近），只注释后面的 CGEvent fallback 块。

- [ ] **Step 2: 验证编译通过**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/Toggle/ToggleEngine.swift && git commit -m "$(cat <<'EOF'
refactor(restore): disable CGEvent drag fallback — rarely triggered, adds complexity

The CGEvent drag fallback (47 lines) was a safety net for when AX apply
clamps windows to main screen. In practice, AX apply almost always
succeeds and the clamping detection marks restore as failed before
this fallback can execute. Commented out (not deleted) so it can be
re-enabled if AX reliability regresses.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

### Task 3: 删除 Hook 模块死代码和冗余 Overlay 逻辑

**Depends on:** None
**Files:**
- Modify: `Sources/Hook/ClaudeHookModels.swift` — 删除 `isNearTarget()` 方法
- Modify: `Sources/Overlay/ScreenOverlayManager+SpaceIndex.swift` — 删除 `getSpaceIndex()` 方法
- Modify: `Sources/Hook/HookEventHandler.swift` — 清理 `usedFallback` 变量

**Symptom:** `isNearTarget()` 已从 restore 路径移除但函数定义仍在；`getSpaceIndex()` 从未被调用；`usedFallback` 被设置但从不影响后续逻辑。

- [ ] **Step 1: 删除 `ToggleRecord.isNearTarget()` 和 `WindowState.isNearTarget()` 死代码**

文件: `Sources/Hook/ClaudeHookModels.swift`

找到两个 `isNearTarget()` 方法：
1. `ToggleRecord` struct 内的 `func isNearTarget(...)` 
2. `WindowState` struct 内的 `func isNearTarget(...)`

确认无调用：
```bash
grep -rn "isNearTarget" Sources/ --include="*.swift" | grep -v "isNearTarget.*removed\|isNearTarget.*guard\|// isNearTarget"
```
Expected: 只在定义处出现（2 处），无实际调用。

删除这两个方法。

- [ ] **Step 2: 删除 `getSpaceIndex()` 死代码**

文件: `Sources/Overlay/ScreenOverlayManager+SpaceIndex.swift`

找到 `func getSpaceIndex(for screen: NSScreen, preferStableSampling: Bool = true) -> Int?` 方法，删除整个函数。

确认无调用：
```bash
grep -rn "getSpaceIndex" Sources/ --include="*.swift"
```
Expected: 只在定义处出现，无调用。

- [ ] **Step 3: 清理 `usedFallback` 未使用变量**

文件: `Sources/Hook/HookEventHandler.swift`

找到 `var usedFallback = false`（约第 179 行）和 `usedFallback = identity != nil`（约第 219 行）。

删除变量声明和赋值语句。`usedFallback` 被设置后从未被读取。

- [ ] **Step 4: 验证编译通过**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 5: 提交**
Run: `git add Sources/Hook/ClaudeHookModels.swift Sources/Overlay/ScreenOverlayManager+SpaceIndex.swift Sources/Hook/HookEventHandler.swift && git commit -m "$(cat <<'EOF'
refactor: delete dead code — isNearTarget, getSpaceIndex, usedFallback

- isNearTarget() (2 implementations): removed from restore path in
  earlier commit but function definitions remained
- getSpaceIndex(): never called, all space queries use getPerScreenSpaceIndex()
- usedFallback variable: set but never read

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

### Task 4: 合并重复的 captureSpaceContext 实现

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Space/SpaceController+Context.swift:7-69`
- Modify: `Sources/Shutdown/ShutdownSnapshotManager.swift` (调用方更新)

**Symptom:** 两个 `captureSpaceContext()` 实现做完全相同的事，区别只是一个有 `operationID` 参数和详细日志。

- [ ] **Step 1: 确认两个函数位置和调用方**

```bash
grep -rn "captureSpaceContext" Sources/ --include="*.swift"
```
记录所有调用方及其参数格式。

- [ ] **Step 2: 修改 `captureSpaceContext` 为单一实现**

文件: `Sources/Space/SpaceController+Context.swift`

保留带 `operationID` 的完整版本（第 7-54 行），给它加默认参数值 `operationID: String? = nil`。

删除第 56-69 行的简化版本。

更新所有调用简化版的代码改为传 `nil`（主要是 ShutdownSnapshotManager）。

- [ ] **Step 3: 验证编译通过**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/Space/SpaceController+Context.swift Sources/Shutdown/ShutdownSnapshotManager.swift && git commit -m "$(cat <<'EOF'
refactor(space): merge duplicate captureSpaceContext implementations

Two implementations doing the same thing consolidated into one with
optional operationID parameter. ShutdownSnapshotManager now passes nil
for operationID instead of using a separate function.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

### Task 5: 提取 switchDisplayToSpace 中的重复光标操作

**Depends on:** None
**Files:**
- Modify: `Sources/Space/SpaceController+Switch.swift:7-127`

**Symptom:** `switchDisplayToSpace()` 中有两段几乎相同的光标保存/移动/恢复代码（第 65-84 行和第 87-121 行），共 40+ 行重复。

- [ ] **Step 1: 提取光标操作辅助方法**

文件: `Sources/Space/SpaceController+Switch.swift`

在 `switchDisplayToSpace` 函数后面添加一个私有辅助方法：

```swift
private func moveCursorToDisplay(spaceIndex: Int, operationID: String) -> (savedCursor: CGPoint, savedApp: NSRunningApplication?)? {
    let savedFrontApp = NSWorkspace.shared.frontmostApplication
    let savedCursor = NSEvent.mouseLocation
    let mainScreenHeight = NSScreen.screens[0].frame.height
    let savedCursorCG = CGPoint(x: savedCursor.x, y: mainScreenHeight - savedCursor.y)

    if let center = displayCenterCG(spaceIndex: spaceIndex) {
        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                    mouseCursorPosition: center, mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
        }
        usleep(50_000)
        return (savedCursorCG, savedFrontApp)
    }
    log("[SpaceController] moveCursorToDisplay: cannot determine display center", level: .warn, fields: [
        "op": operationID, "spaceIndex": String(spaceIndex)
    ])
    return nil
}

private func restoreCursor(_ savedCursor: CGPoint, savedApp: NSRunningApplication?) {
    if let restoreEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                   mouseCursorPosition: savedCursor, mouseButton: .left) {
        restoreEvent.post(tap: .cghidEventTap)
    }
    savedApp?.activate(options: .activateIgnoringOtherApps)
}
```

- [ ] **Step 2: 重构 switchDisplayToSpace 使用辅助方法**

文件: `Sources/Space/SpaceController+Switch.swift:7-127`

将 steps==0 分支（约第 62-84 行）替换为：
```swift
guard steps != 0 else {
    if let (savedCursor, savedApp) = moveCursorToDisplay(spaceIndex: targetSpace, operationID: op) {
        restoreCursor(savedCursor, savedApp: savedApp)
    }
    return true
}
```

将主 CGEvent 路径（约第 87-121 行）的光标操作替换为：
```swift
guard let (savedCursor, savedApp) = moveCursorToDisplay(spaceIndex: targetSpace, operationID: op) else {
    log("[SpaceController] switchDisplayToSpace: cannot move cursor, proceeding without", level: .warn, fields: ["op": op])
    // 仍然尝试发送 CGEvent
}

let success = NativeSpaceBridge.focusSpace(steps: steps, operationID: op)

if let savedCursor {
    restoreCursor(savedCursor, savedApp: savedApp)
}
```

- [ ] **Step 3: 验证编译通过**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/Space/SpaceController+Switch.swift && git commit -m "$(cat <<'EOF'
refactor(space): extract cursor manipulation helpers in switchDisplayToSpace

40+ lines of duplicate cursor save/move/restore code consolidated into
moveCursorToDisplay() and restoreCursor() helpers. No behavior change.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

### Task 6: 清理重复的坐标验证逻辑

**Depends on:** None
**Files:**
- Modify: `Sources/Hook/ClaudeHookModels.swift` — 统一 `ToggleRecord` 和 `WindowState` 的验证
- Modify: `Sources/Toggle/ToggleEngine.swift:158-183` — 移除内联验证，使用统一方法

**Symptom:** 坐标验证逻辑在 3 个地方用不同容差实现：`ToggleRecord.isValid()`、`ToggleEngine.restore()` 内联检查、`ToggleEngine.save()` 内联检查。

- [ ] **Step 1: 确认 ToggleRecord.isValid() 已覆盖 restore() 的内联验证**

读取 `ToggleRecord.isValid(mainScreenFrame:)` 和 `ToggleEngine.restore()` 的内联验证，确认 `isValid()` 的检查范围 >= 内联检查。

如果 `isValid()` 已经足够严格，删除 `restore()` 中的冗余内联验证。如果 `isValid()` 不够严格，先增强 `isValid()` 再删除内联版本。

- [ ] **Step 2: 验证编译通过**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/Toggle/ToggleEngine.swift Sources/Hook/ClaudeHookModels.swift && git commit -m "$(cat <<'EOF'
refactor(restore): consolidate coordinate validation to ToggleRecord.isValid()

Remove inline frame validation in ToggleEngine.restore() that duplicated
ToggleRecord.isValid() with different tolerances. Now isValid() is the
single source of truth for record validation.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

### Task 7: 消除 Overlay 模块重复缓存

**Depends on:** Task 3
**Files:**
- Modify: `Sources/Overlay/ScreenOverlayManager.swift` — 删除 `cachedSpaceIndices` 字典
- Modify: `Sources/Overlay/ScreenOverlayManager+SpaceIndex.swift` — 统一使用 `screenSpaceCache`

**Symptom:** 两个缓存字典存储相同的空间索引数据：`screenSpaceCache` 和 `cachedSpaceIndices`。

- [ ] **Step 1: 确认 cachedSpaceIndices 的所有使用方**

```bash
grep -rn "cachedSpaceIndices" Sources/ --include="*.swift"
```

- [ ] **Step 2: 将 cachedSpaceIndices 的使用方改为从 screenSpaceCache 读取**

删除 `cachedSpaceIndices` 字典声明。所有读取 `cachedSpaceIndices[uuid]` 的地方改为 `screenSpaceCache[uuid]?.spaceIndex`。

- [ ] **Step 3: 验证编译通过**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/Overlay/ScreenOverlayManager.swift Sources/Overlay/ScreenOverlayManager+SpaceIndex.swift && git commit -m "$(cat <<'EOF'
refactor(overlay): remove duplicate cachedSpaceIndices — use screenSpaceCache

Two dictionaries cached identical space index data. Removed cachedSpaceIndices,
all reads now use screenSpaceCache[uuid]?.spaceIndex.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

## 总预期收益

| Task | 删除/精简行数 | 风险 |
|------|-------------|------|
| Task 1: 死代码删除 | 171 行 | 零 |
| Task 2: CGEvent fallback 注释 | 47 行 | 极低 |
| Task 3: Hook/Overlay 死代码 | 40 行 | 零 |
| Task 4: captureSpaceContext 合并 | 28 行 | 低 |
| Task 5: 光标操作提取 | 40 行 | 低 |
| Task 6: 验证逻辑统一 | 25 行 | 低 |
| Task 7: Overlay 缓存合并 | 15 行 | 低 |
| **Total** | **~366 行** | — |
