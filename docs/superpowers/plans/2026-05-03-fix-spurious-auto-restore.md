# Bug Fix: Claude Code hook 导致窗口在主屏幕打字时被自动移回副屏

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 ClaudeHookServer 的 UserPromptSubmit fallback 路径错误 restore 窗口的 bug — 用户在主屏打字时，Claude Code hook 触发 UserPromptSubmit，fallback 路径匹配到 toggle 创建的 saved state，导致窗口被意外移回副屏。

**Architecture:** 用户 Ctrl+Q toggle 窗口到主屏 → `moveToMainScreen(sessionID: nil)` 保存 saved state（sessionID=nil）→ 用户在主屏使用 Claude Code 打字 → hook 触发 UserPromptSubmit → ClaudeHookServer 尝试 sessionID 匹配（失败，因为 toggle 的 state 没有 sessionID）→ fallback 调用 `shouldRestoreCurrentWindow()` → 通过 windowID 匹配到 toggle 创建的 state → 错误执行 restore → 窗口被移回副屏。修复：在 hook 路径调用 shouldRestoreCurrentWindow 时，只匹配有 sessionID 的 saved state（即 hook 自己创建的 state），跳过 toggle 创建的无 sessionID state。

**Tech Stack:** Swift 5.9, macOS 14+

**Risks:**
- 修改 shouldRestoreCurrentWindow 签名可能影响热键 toggle 路径 → 缓解：添加可选参数，默认值保持原有行为
- 过滤 sessionID=nil 的 state 可能导致 hook 路径永远无法 restore → 缓解：hook 自己通过 `moveWindowToMainScreen(sessionID:)` 创建的 state 有 sessionID，不受影响

---

### Task 1: 给 shouldRestoreCurrentWindow 添加 sessionID 过滤参数

**Depends on:** None
**Files:**
- Modify: `Sources/WindowManager.swift:717`（shouldRestoreCurrentWindow 函数签名）
- Modify: `Sources/WindowManager.swift:784`（windowID 匹配路径）
- Modify: `Sources/WindowManager.swift:818`（fallback 匹配路径）
- Modify: `Sources/ClaudeHookServer.swift:508`（hook 调用处）

- [ ] **Step 1: 修改 shouldRestoreCurrentWindow 函数签名 — 添加 requireSessionID 参数**

文件: `Sources/WindowManager.swift:717`

将 `shouldRestoreCurrentWindow()` 改为 `shouldRestoreCurrentWindow(requireSessionID: Bool = false)`，当 `requireSessionID=true` 时，跳过 sessionID 为 nil 的 saved state。

```swift
func shouldRestoreCurrentWindow(requireSessionID: Bool = false) -> Bool {
    log(
        "[WindowManager] shouldRestoreCurrentWindow called",
        level: .debug,
        fields: [
            "savedStatesCount": String(savedWindowStates.count),
            "requireSessionID": String(requireSessionID)
        ]
    )
```

- [ ] **Step 2: 修改 windowID 匹配路径 — 过滤无 sessionID 的 state**

文件: `Sources/WindowManager.swift:784`（替换 `if let matchedState = savedWindowStates.reversed().first` 行）

在 `first(where:)` 闭包中增加 sessionID 过滤条件。

```swift
if let matchedState = savedWindowStates.reversed().first(where: { state in
    guard state.windowID == currentWindowID else { return false }
    if requireSessionID && state.sessionID == nil { return false }
    return true
}) {
```

- [ ] **Step 3: 修改 fallback 匹配路径 — 过滤无 sessionID 的 state**

文件: `Sources/WindowManager.swift:818-824`（替换 `findStateByFallbackMatching` 调用）

在 `findStateByFallbackMatching` 返回结果后，增加 sessionID 检查。

```swift
// 第二级匹配：通过 PID + 窗口标题 + 大致位置（备用机制）
if let currentFrame,
   let matchedState = findStateByFallbackMatching(
       pid: frontApp.processIdentifier,
       title: currentTitle,
       frame: currentFrame
   ) {
    if requireSessionID && matchedState.sessionID == nil {
        log(
            "[WindowManager] fallback match found but skipped: requireSessionID=true and state has no sessionID",
            level: .info,
            fields: [
                "stateID": matchedState.id,
                "windowID": String(describing: matchedState.windowID)
            ]
        )
    } else if isSavedStateCorrupted(matchedState) {
```

- [ ] **Step 4: 修改 ClaudeHookServer 的 fallback 调用 — 传入 requireSessionID=true**

文件: `Sources/ClaudeHookServer.swift:508`

```swift
if WindowManager.shared.shouldRestoreCurrentWindow(requireSessionID: true) {
```

- [ ] **Step 5: 验证构建**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 6: 提交**
Run: `git add Sources/WindowManager.swift Sources/ClaudeHookServer.swift && git commit -m "fix(hook): prevent UserPromptSubmit fallback from restoring toggle-moved windows

Root cause: When user presses Ctrl+Q to toggle window to main screen,
moveToMainScreen saves state with sessionID=nil. Later, when Claude Code
hook triggers UserPromptSubmit, the sessionID matching fails (nil != hook's
sessionID), so it falls back to shouldRestoreCurrentWindow() which matches
the toggle-created state by windowID, causing unwanted restore back to
secondary screen.

Fix: Add requireSessionID parameter to shouldRestoreCurrentWindow(). When
called from hook fallback path, pass requireSessionID=true to skip states
without sessionID (i.e., toggle-created states). Hook-created states have
sessionID set and will still match correctly.

Evidence: 34 hook-restore-fallback operations found in logs, 8 of which
were spurious (no toggle in prior 60s). Each moved window from main screen
targetFrame (71,38) back to secondary screen originalFrame.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"`
