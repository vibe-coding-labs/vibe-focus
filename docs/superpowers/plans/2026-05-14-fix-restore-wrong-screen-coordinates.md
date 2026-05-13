# Fix: Restore 应用副屏幕坐标到主屏幕上的窗口

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 restore 操作在 space 移动失败后仍然将副屏幕坐标应用到主屏幕窗口的 Bug，导致窗口"回退不成功反而往下移动"。

**Architecture:** 根因分析：日志铁证显示 `moveWindow failed` 后 `ToggleEngine.restore: success` 紧随其后。三个层面的问题：(1) ToggleEngine.restore 中 apply() 失败仍 return true；(2) WindowManager.restore 中 space 移动失败后继续 apply frame；(3) moveWindow 的 NativeSpaceBridge "recently failed" 缓存导致重试被跳过。修复策略：在每个层面增加安全检查，确保 space 移动失败时绝不应用副屏幕坐标。

**Tech Stack:** Swift 5, macOS Accessibility API, yabai space manager, NativeSpaceBridge (CGS private API)

**Risks:**
- Task 1 修改 restore 返回逻辑，apply 失败时 return false 而非 true — 可能导致 HookEventHandler 报告 restore 失败，但这是正确行为
- Task 2 增加 moveWindow 重试前清除 NativeSpaceBridge 失败缓存 — 可能增加 80-150ms 延迟，但提高成功率
- Task 3 部署需要完整 app bundle + code signing

---

### Task 1: 修复 ToggleEngine.restore 和 WindowManager.restore 的安全检查

**Depends on:** None
**Files:**
- Modify: `Sources/Toggle/ToggleEngine.swift:184-196`
- Modify: `Sources/Window/WindowManager+Restore.swift:163-260`

- [ ] **Step 1: 修复 ToggleEngine.restore 中 apply 失败仍 return true 的 Bug**

文件: `Sources/Toggle/ToggleEngine.swift:184-196`

当前代码：
```swift
let restored = wm.apply(frame: record.origFrame, to: restoreAX, operationID: trace, stage: "restore_orig")
if !restored {
    log("ToggleEngine.restore: frame apply failed", level: .error, fields: [
        "traceID": trace
    ])
}

log("ToggleEngine.restore: success", level: .info, fields: [
    "traceID": trace,
    "windowID": String(windowID),
    "restoredTo": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y))"
])
return true
```

替换为：
```swift
let restored = wm.apply(frame: record.origFrame, to: restoreAX, operationID: trace, stage: "restore_orig")
if !restored {
    log("ToggleEngine.restore: frame apply failed, returning false", level: .error, fields: [
        "traceID": trace,
        "windowID": String(windowID),
        "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y)) \(Int(record.origFrame.size.width))x\(Int(record.origFrame.size.height))"
    ])
    return false
}

log("ToggleEngine.restore: success", level: .info, fields: [
    "traceID": trace,
    "windowID": String(windowID),
    "restoredTo": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y))"
])
return true
```

- [ ] **Step 2: 修复 WindowManager.restore 中 space 移动失败后继续 apply frame 的问题**

文件: `Sources/Window/WindowManager+Restore.swift:163-260`

当前代码在 "display already on correct space" 分支中，moveWindow 返回 false 后有 return 逻辑，但在 `displayCurrentSpace != targetSpace` 分支中，switchDisplayToSpace 失败后没有 return（只是 log 了 warn），代码会继续到 moveWindow 调用。

此外，当前代码在 `displayCurrentSpace` 为 nil 时（`else` 分支），也没有 return，会继续执行。

检查并确保以下三个分支都在失败时设置 `spaceReady = false` 或 return：

1. `displayCurrentSpace == targetSpace` 分支：moveWindow 失败 → 已有 return（行 199-201），OK
2. `displayCurrentSpace != targetSpace` 分支：switchDisplayToSpace 失败 → 需要确保不继续到 moveWindow
3. `displayCurrentSpace == nil` 分支 → 需要确保不继续到 moveWindow

当前代码行 252-260 已有 `if !spaceReady { return }` 检查，所以 WindowManager+Restore 的逻辑实际上是正确的。但需要确认 `spaceReady` 在所有失败路径都被设为 false。

验证现有代码：在 `displayCurrentSpace != targetSpace` 分支中，如果 `switched` 为 false，代码执行到行 241-244 的 `} else {` 块，只打了 warn log，然后继续到行 246 的 `}`。此时 `spaceReady` 仍为 false（初始值），所以行 252 的 `if !spaceReady` 会触发 return。

在 `displayCurrentSpace == nil` 分支（行 246-250 的 `} else {`），同样只打了 warn log，`spaceReady` 为 false，会 return。

**结论：WindowManager+Restore.swift 的 spaceReady 检查逻辑是正确的，不需要修改。**

- [ ] **Step 3: 在 ToggleEngine.restore 中增加 restore 后窗口位置验证**

文件: `Sources/Toggle/ToggleEngine.swift:184-196`（Step 1 修改后的位置）

在 apply frame 成功后，增加一个验证步骤：检查窗口是否真的到达了目标 space。如果窗口仍在主屏幕上，说明 space 移动虽然报告成功但实际失败，此时应该报告 restore 失败。

在 Step 1 替换后的代码后面追加验证：

```swift
// 验证窗口确实到达了目标 space（防御性检查）
let postRestoreSpace = spaceController.windowSpaceIndex(windowID: windowID)
if let postSpace = postRestoreSpace, postSpace != record.sourceSpace {
    log("ToggleEngine.restore: window ended up on wrong space after restore", level: .error, fields: [
        "traceID": trace,
        "windowID": String(windowID),
        "expectedSpace": String(record.sourceSpace),
        "actualSpace": String(postSpace)
    ])
    return false
}
```

- [ ] **Step 4: 提交**
Run: `git add Sources/Toggle/ToggleEngine.swift && git commit -m "fix(restore): abort restore when apply frame fails, add post-restore space verification"`

---

### Task 2: 改进 moveWindow 重试机制 — 清除 NativeSpaceBridge 失败缓存

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Space/SpaceController+Move.swift:85-128`

- [ ] **Step 1: 在 moveWindow 的 NativeSpaceBridge 策略前清除失败缓存**

文件: `Sources/Space/SpaceController+Move.swift:85-87`

当前代码在策略 1 调用 NativeSpaceBridge 之前没有清除失败缓存，导致如果同一窗口之前 moveWindow 失败过，NativeSpaceBridge 会被跳过。

在策略 1 之前增加缓存清除：

```swift
// 策略 1：使用 NativeSpaceBridge (CGS API) 直接移动
// 清除失败缓存，给本次操作一个全新机会
NativeSpaceBridge.resetFailureCache()
if nativeAvailable, let spaceID = nativeSpaceID(forYabaiIndex: spaceIndex) {
```

- [ ] **Step 2: 在 yabai 策略的 NativeSpaceBridge fallback 前也清除缓存**

文件: `Sources/Space/SpaceController+Move.swift:161`

当前代码：
```swift
if nativeAvailable, let spaceID = nativeSpaceID(forYabaiIndex: spaceIndex) {
```

替换为：
```swift
if nativeAvailable, let spaceID = nativeSpaceID(forYabaiIndex: spaceIndex) {
    NativeSpaceBridge.resetFailureCache()
```

- [ ] **Step 3: 提交**
Run: `git add Sources/Space/SpaceController+Move.swift && git commit -m "fix(space): clear NativeSpaceBridge failure cache before moveWindow retry"`

---

### Task 3: 构建并部署修复后的 VibeFocus

**Depends on:** Task 1, Task 2
**Files:**
- Modify: 无（部署流程）

- [ ] **Step 1: 构建并部署 VibeFocus**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && bash scripts/dev-build.sh`

Expected:
  - Exit code: 0
  - Output contains: "Build Succeeded" or similar
  - /Applications/VibeFocus.app exists and is updated

- [ ] **Step 2: 重启 VibeFocus**
Run: `killall VibeFocus 2>/dev/null; sleep 1; open /Applications/VibeFocus.app`

Expected:
  - VibeFocus process is running (check with `ps aux | grep VibeFocus | grep -v grep`)

- [ ] **Step 3: 验证修复 — 测试 Ctrl+Q toggle/restore 循环**

手动测试步骤：
1. 在副屏幕上打开一个终端窗口
2. 按 Ctrl+Q 将窗口移到主屏幕
3. 按 Ctrl+Q 将窗口恢复到副屏幕
4. 验证窗口确实回到了副屏幕的原始位置
5. 如果窗口仍在主屏幕上或位置偏移，检查日志

Run: `tail -50 ~/Library/Logs/VibeFocus/vibefocus.log | grep -i "restore\|abort\|space switch failed"`

Expected:
  - 如果 restore 成功：看到 "ToggleEngine.restore: success" 且窗口在副屏幕
  - 如果 space 移动失败：看到 "space switch failed, aborting" 而不是 "restore: success" + 错误坐标

- [ ] **Step 4: 提交部署记录**
Run: `git add -A && git commit -m "deploy: fix restore wrong-screen coordinates + moveWindow retry improvement"`
