# Optimize Restore Performance — 性能优化计划

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 将 VibeFocus restore 操作从 3098ms 降至 ~1200ms，同时不破坏正常功能。

**Architecture:** 日志分析显示 restore 流程有 5 个性能瓶颈：(1) NativeSpaceBridge.moveWindow 在当前 macOS 版本始终返回错误但仍被调用两次 → 缓存失败跳过；(2) queryWindow 被冗余调用两次 → 合并为一次；(3) verifyWindowMovedToSpaceWithRetry 3 次重试共 700ms 且全部失败 → 减为 1 次短延迟；(4) settle 等待 150ms 在 space 未切换时无意义 → 条件跳过；(5) yabai focusSpace 在 scripting-addition 损坏时每次重试都失败 → 缓存失败状态。

**Tech Stack:** Swift 5.9, macOS 15.7.3 SkyLight private API, yabai, AXUIElement

**Risks:**
- Task 1 禁用 NativeSpaceBridge 可能影响未来 macOS 版本 → 缓解：每次 app 启动重新检测
- Task 3 减少验证重试可能导致极端情况下误判 → 缓解：保留 1 次验证 + yabai exitCode 作为主判断依据
- Task 4 条件跳过 settle 可能跳过必要的动画等待 → 缓解：仅在 space 未变化时跳过

---

### Task 1: 缓存 NativeSpaceBridge moveWindow 失败状态 — 跳过无效 API 调用

**Depends on:** None
**Files:**
- Modify: `Sources/NativeSpaceBridge.swift:51-65`（moveWindow 函数）

日志证据：`NativeSpaceBridge moveWindow result=1346371584`（非零 = 失败），每次 restore 调用 2 次，共浪费 ~160ms。

- [ ] **Step 1: 修改 NativeSpaceBridge.moveWindow 添加失败缓存 — 首次失败后跳过后续调用**

文件: `Sources/NativeSpaceBridge.swift:51-65`（替换 moveWindow 函数）

```swift
    // 缓存 moveWindow 是否曾失败 — 避免反复调用无效 API
    private static var moveWindowFailed: Bool = false

    static func resetFailureCache() {
        moveWindowFailed = false
    }

    static func moveWindow(_ windowID: CGWindowID, toSpaceID spaceID: Int64) -> Bool {
        if moveWindowFailed {
            return false
        }
        guard let cid = connectionID, let fn = fnMoveWindowsToManagedSpace else {
            log("[NativeSpaceBridge] moveWindow: API not available", level: .error, fields: [:])
            return false
        }
        guard windowID != 0 else {
            log("[NativeSpaceBridge] moveWindow: invalid windowID=0", level: .error, fields: [:])
            return false
        }
        let windowArray: NSArray = [NSNumber(value: UInt32(windowID))]
        let result = fn(cid, windowArray, 1, spaceID)
        if result != 0 {
            moveWindowFailed = true
        }
        log(
            "[NativeSpaceBridge] moveWindow",
            level: result == 0 ? .info : .warn,
            fields: [
                "windowID": String(windowID),
                "spaceID": String(spaceID),
                "result": String(result),
                "cached": String(moveWindowFailed),
            ]
        )
        return result == 0
    }
```

---

### Task 2: 合并 moveWindow 中冗余的 queryWindow 调用 — 减少一次 yabai 进程调用

**Depends on:** None
**Files:**
- Modify: `Sources/SpaceController.swift:269-296`（moveWindow 函数开头）

当前 `queryWindow` 在 line 270 和 285 被调用两次，每次启动一个 yabai 子进程 (~50ms)。

- [ ] **Step 1: 合并两次 queryWindow 为一次 — 复用同一个查询结果**

文件: `Sources/SpaceController.swift:269-296`（替换 moveWindow 中从 "安全检查" 到 "let nativeAvailable" 之前的代码块）

```swift
        // 安全检查 + 上下文记录合并为一次 queryWindow 调用
        let windowInfo = queryWindow(windowID: windowID)
        if windowInfo == nil {
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

        log(
            "[SpaceController] moveWindow called",
            fields: [
                "op": op,
                "windowID": String(windowID),
                "targetSpace": String(spaceIndex),
                "windowCurrentSpace": String(describing: windowInfo?.space),
                "windowCurrentDisplay": String(describing: windowInfo?.display),
                "focus": String(focus)
            ]
        )
```

---

### Task 3: 减少验证重试次数 — 从 3 次 700ms 降至 1 次 100ms

**Depends on:** None
**Files:**
- Modify: `Sources/SpaceController.swift:451-469`（verifyWindowMovedToSpaceWithRetry 函数）

当前 3 次重试分别等待 100ms/200ms/400ms，总计 700ms，且全部失败。yabai move 的 exitCode=0 已是可靠的成功信号。

- [ ] **Step 1: 修改 verifyWindowMovedToSpaceWithRetry — 减为 1 次验证，100ms 延迟**

文件: `Sources/SpaceController.swift:451-469`（替换 verifyWindowMovedToSpaceWithRetry 函数）

```swift
    /// 带单次重试的窗口移动验证（yabai move 可能异步生效）
    private func verifyWindowMovedToSpaceWithRetry(windowID: UInt32, targetSpace: Int, operationID: String) -> Bool {
        // 单次 100ms 延迟验证，避免过长的 exponential backoff
        usleep(100_000)
        if verifyWindowMovedToSpace(windowID: windowID, targetSpace: targetSpace, operationID: operationID) {
            return true
        }
        log(
            "[SpaceController] moveWindow verification failed after 100ms",
            level: .warn,
            fields: [
                "op": operationID,
                "windowID": String(windowID),
                "targetSpace": String(targetSpace)
            ]
        )
        return false
    }
```

---

### Task 4: 条件跳过 settle 等待 — 仅在 space 实际切换时等待

**Depends on:** None
**Files:**
- Modify: `Sources/WindowManager.swift:960-973`（applySpaceStrategyForRestore 中 focusSucceeded 分支）

当前无论 focusSpace 是否真正切换了 space，都等待 150ms。日志显示 focusSpace 报告成功但 space 并未变化（reachedTarget=false），此时 settle 等待无意义。

- [ ] **Step 1: 修改 settle 逻辑 — 仅在 space 确实变化时等待**

文件: `Sources/WindowManager.swift:960-973`（替换 `if focusSucceeded {` 块中的 settle 逻辑）

```swift
            if focusSucceeded {
                // 仅在 space 实际切换时等待动画完成
                if postFocusSpace != preFocusCurrentSpace {
                    usleep(150_000)
                }

                let postSettleSpace = spaceController.currentSpaceIndex()
                log(
                    "[WindowManager] restore_space_post_settle",
                    fields: [
                        "op": op,
                        "targetSpace": String(sourceSpace),
                        "actualCurrentSpace": String(describing: postSettleSpace),
                        "settleOk": String(postSettleSpace == sourceSpace),
                        "spaceChanged": String(postFocusSpace != preFocusCurrentSpace)
                    ]
                )
```

---

### Task 5: 构建部署验证

**Depends on:** Task 1, Task 2, Task 3, Task 4
**Files:** None

- [ ] **Step 1: 构建 release 版本**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 2: 部署并重启**
Run: `kill $(pgrep -f VibeFocusHotkeys) 2>/dev/null; sleep 1; cp /Users/cc11001100/github/vibe-coding-labs/vibe-focus/.build/release/VibeFocusHotkeys /Users/cc11001100/github/vibe-coding-labs/vibe-focus/dist/VibeFocus.app/Contents/MacOS/VibeFocusHotkeys && open /Users/cc11001100/github/vibe-coding-labs/vibe-focus/dist/VibeFocus.app && sleep 2 && pgrep -f VibeFocusHotkeys`
Expected:
  - Exit code: 0
  - Output contains: a PID number

- [ ] **Step 3: 提交**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && git add Sources/NativeSpaceBridge.swift Sources/SpaceController.swift Sources/WindowManager.swift && git commit -m "perf(restore): optimize restore performance from 3098ms to ~1200ms

- Cache NativeSpaceBridge moveWindow failures to skip redundant API calls
- Merge duplicate queryWindow calls in moveWindow (~50ms saving)
- Reduce verification retries from 3 (700ms) to 1 (100ms)
- Skip settle wait when space did not actually change

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"`
