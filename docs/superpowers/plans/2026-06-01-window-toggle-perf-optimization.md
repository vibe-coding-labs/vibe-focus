# Optimization: VibeFocus 窗口切换性能优化 — 消除冗余 yabai 进程 spawn

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 将窗口 toggle 操作耗时从 600-1000ms 降低到 150-300ms，通过消除冗余 yabai 进程 spawn（同一窗口 queryWindow 被调用 4 次）和引入短生命周期查询缓存。

**Architecture:** 在 SpaceController 中引入 TTL=2s 的查询结果缓存，在一次 toggle 操作期间复用 queryWindow/querySpaces 结果。move 路径将查询结果作为参数传递而非重新查询。setWindowFloat 跳过已知的 float 状态检查。整个 toggle 操作从 6-10 次 yabai spawn 减少到 2-3 次。

**Tech Stack:** Swift 5.9+, macOS 14+, yabai (进程间通信), SQLite (状态存储)

**Scope:** Medium
**Risk:** Medium

**Risks:**
- Task 1 修改 SpaceController 添加缓存层 → 缓存 TTL 过长可能导致 yabai 状态不同步 → 缓解：TTL=2s，每次 toggle 结束后自动清除
- Task 2 修改 moveWindowToMainScreen 流程 → 可能影响 Space 切换核心能力 → 缓解：保留 fallback 到原始查询路径
- Task 3 修改 restore 流程 → restore 是关键路径，曾有过多次 bug → 缓解：仅减少查询次数，不改 restore 逻辑

**Autonomy Level:** Full

---

## Current Baseline (Phase 1 调研数据)

| 操作 | yabai spawn 次数 | 预估耗时 |
|------|----------------|---------|
| toggle (move to main) | 6-8 次 | 600-1000ms |
| toggle (restore) | 4-6 次 | 400-800ms |
| 每次 yabai spawn | 1 次 | 50-100ms |

## Target

| 操作 | yabai spawn 次数 | 预估耗时 |
|------|----------------|---------|
| toggle (move to main) | 2-3 次 | 150-300ms |
| toggle (restore) | 1-2 次 | 80-200ms |

---

### Task 1: 添加 SpaceController 查询缓存基础设施

**Depends on:** None
**Files:**
- Modify: `Sources/Space/SpaceController.swift` — 添加缓存存储和 TTL 控制
- Modify: `Sources/Space/SpaceController+Query.swift` — queryWindow/querySpaces 使用缓存

- [ ] **Step 1: 在 SpaceController 添加查询缓存存储 — 减少 yabai 进程 spawn**

文件: `Sources/Space/SpaceController.swift:54-66`（在 `SpaceController` 类属性区域添加缓存字段）

```swift
// Sources/Space/SpaceController.swift:54-66
// 在 SpaceController 类中添加以下缓存属性（在 checkInterval 之后）

    // MARK: - Query Cache (per-toggle lifecycle)

    /// 查询缓存 TTL — 短到不会错过 yabai 状态变化，长到覆盖一次 toggle 操作
    private static let queryCacheTTL: TimeInterval = 2.0

    /// 缓存 queryWindow 结果 — key 是 windowID
    private var windowQueryCache: [UInt32: (result: YabaiWindowInfo?, cachedAt: Date)] = [:]
    /// 缓存 querySpaces 结果
    private var spacesQueryCache: (result: [YabaiSpaceInfo]?, cachedAt: Date)?

    /// 清除所有查询缓存 — 每次 toggle 操作结束后调用
    func clearQueryCache() {
        windowQueryCache.removeAll()
        spacesQueryCache = nil
    }

    /// 检查缓存是否过期
    private func isCacheExpired(_ cachedAt: Date) -> Bool {
        return Date().timeIntervalSince(cachedAt) > Self.queryCacheTTL
    }
```

- [ ] **Step 2: 修改 queryWindow 添加缓存逻辑 — 同一窗口在一次 toggle 中只查询一次**

文件: `Sources/Space/SpaceController+Query.swift:44-77`（替换整个 `queryWindow` 方法）

```swift
    func queryWindow(windowID: UInt32) -> YabaiWindowInfo? {
        // 1. 检查缓存
        if let cached = windowQueryCache[windowID], !isCacheExpired(cached.cachedAt) {
            return cached.result
        }

        // 2. 直接查询
        if let result = runYabai(arguments: ["-m", "query", "--windows", "--window", "\(windowID)"]),
           result.exitCode == 0 {
            let info = decodeSingleOrFirst(YabaiWindowInfo.self, from: result.stdout)
            if info != nil {
                windowQueryCache[windowID] = (result: info, cachedAt: Date())
                return info
            }
        }

        log(
            "[queryWindow] direct query failed, trying all-windows fallback",
            level: .warn,
            fields: ["windowID": String(windowID)]
        )
        guard let allResult = runYabai(arguments: ["-m", "query", "--windows"]),
              allResult.exitCode == 0 else {
            log("[queryWindow] all-windows fallback also failed", level: .warn, fields: ["windowID": String(windowID)])
            windowQueryCache[windowID] = (result: nil, cachedAt: Date())
            return nil
        }
        let allWindows = decodeArray(YabaiWindowInfo.self, from: allResult.stdout) ?? []
        let match = allWindows.first { $0.id == Int(windowID) }
        log(
            "[queryWindow] fallback result",
            level: .warn,
            fields: [
                "windowID": String(windowID),
                "found": String(match != nil),
                "space": String(describing: match?.space),
                "display": String(describing: match?.display),
                "totalWindows": String(allWindows.count)
            ]
        )
        windowQueryCache[windowID] = (result: match, cachedAt: Date())
        return match
    }
```

- [ ] **Step 3: 修改 querySpaces 添加缓存逻辑 — 同一次 toggle 中只查询一次 spaces**

文件: `Sources/Space/SpaceController+Query.swift:15-42`（替换整个 `querySpaces` 方法）

```swift
    func querySpaces(caller: String = #function) -> [YabaiSpaceInfo]? {
        // 1. 检查缓存
        if let cached = spacesQueryCache, !isCacheExpired(cached.cachedAt) {
            return cached.result
        }

        let startedAt = Date()
        guard let result = runYabai(arguments: ["-m", "query", "--spaces"]),
              result.exitCode == 0 else {
            log(
                "[SpaceController] querySpaces failed",
                level: .warn,
                fields: [
                    "caller": caller,
                    "durationMs": String(elapsedMilliseconds(since: startedAt))
                ]
            )
            spacesQueryCache = (result: nil, cachedAt: Date())
            return nil
        }
        let spaces = decodeArray(YabaiSpaceInfo.self, from: result.stdout)
        if spaces == nil, !result.stdout.isEmpty {
            log(
                "[SpaceController] querySpaces decode failed",
                level: .warn,
                fields: [
                    "caller": caller,
                    "stdoutLen": String(result.stdout.count),
                    "durationMs": String(elapsedMilliseconds(since: startedAt))
                ]
            )
        }
        spacesQueryCache = (result: spaces, cachedAt: Date())
        return spaces
    }
```

- [ ] **Step 4: 在 toggle 开始和结束时清除缓存**

文件: `Sources/Window/WindowManager+Toggle.swift:7-11`（在 toggle 方法开头添加缓存清除）

在 `toggle()` 方法的 `let startedAt = Date()` 之后添加:

```swift
        // 清除查询缓存，确保本次 toggle 获取最新状态
        SpaceController.shared.clearQueryCache()
```

文件: `Sources/Window/WindowManager+Toggle.swift:139-141`（在 toggle 方法的 if durationMs >= 650 块之后添加）

```swift
        // toggle 结束后清除缓存
        SpaceController.shared.clearQueryCache()
```

- [ ] **Step 5: 验证编译通过**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 6: 质量门禁 — 编译 + 测试**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5 && swift test 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output contains: "Test Suite started" and "passed"
  - 无新增 FAIL

- [ ] **Step 7: 提交**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && git add Sources/Space/SpaceController.swift Sources/Space/SpaceController+Query.swift Sources/Window/WindowManager+Toggle.swift && git commit -m "perf(space): add TTL query cache to eliminate redundant yabai spawns per toggle"`

---

### Task 2: 优化 move-to-main 路径 — 消除冗余查询

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Window/WindowManager+MoveWindow.swift:47-172` — 重构 moveWindowToMainScreen 减少 yabai 调用
- Modify: `Sources/Space/SpaceController+Move.swift:56-74` — setWindowFloat 接受预查询结果
- Modify: `Sources/Window/WindowManager+Toggle.swift:190-255` — moveToMainScreen 路径优化

- [ ] **Step 1: 修改 setWindowFloat 接受预查询的窗口信息 — 避免再次 queryWindow**

文件: `Sources/Space/SpaceController+Move.swift:56-74`（替换整个 `setWindowFloat` 方法）

```swift
    func setWindowFloat(_ windowID: UInt32, operationID: String? = nil, knownWindowInfo: YabaiWindowInfo? = nil) {
        let op = operationID ?? "none"
        guard isEnabled else { return }

        // 使用传入的窗口信息或查询缓存
        let info = knownWindowInfo ?? queryWindow(windowID: windowID)
        if let info {
            if info.isFloating { return }
        } else {
            log("setWindowFloat: queryWindow returned nil, skipping toggle", level: .warn, fields: [
                "op": op, "windowID": String(windowID)
            ])
            return
        }

        _ = runYabai(
            arguments: ["-m", "window", "\(windowID)", "--toggle", "float"],
            operation: "setWindowFloat",
            operationID: op
        )
    }
```

- [ ] **Step 2: 修改 focusWindow 接受预查询的窗口信息 — 避免再次 queryWindow**

文件: `Sources/Space/SpaceController+Move.swift:76-96`（替换整个 `focusWindow` 方法）

```swift
    func focusWindow(_ windowID: UInt32, operationID: String? = nil, knownWindowInfo: YabaiWindowInfo? = nil) -> Bool {
        let op = operationID ?? "none"
        refreshAvailabilityIfNeeded()
        guard isEnabled else { return false }

        // 使用传入的窗口信息或查询缓存
        let info = knownWindowInfo ?? queryWindow(windowID: windowID)
        guard info != nil else {
            log("[SpaceController] focusWindow aborted: window does not exist", level: .warn, fields: [
                "op": op, "windowID": String(windowID)
            ])
            return false
        }

        let result = runYabaiVariants(
            variants: [["-m", "window", "--focus", "\(windowID)"]],
            operation: "focusWindow(\(windowID))",
            operationID: op
        )
        if result.success { return true }
        markOperationError(from: result.failure, fallback: "Failed to focus window \(windowID)", operationID: op)
        return false
    }
```

- [ ] **Step 3: 重构 moveWindowToMainScreen 减少冗余查询 — 将 captureSpaceContext 前置的 queryWindow 结果复用**

文件: `Sources/Window/WindowManager+MoveWindow.swift:46-172`（替换整个 `moveWindowToMainScreen` 方法）

关键优化点：
1. `windowDisplayIndex()` 和 `captureSpaceContext()` 都调用 `queryWindow()` → 缓存已在 Task 1 解决
2. 将 `setWindowFloat` 和 `focusWindow` 传入已知窗口信息

```swift
    @discardableResult
    func moveWindowToMainScreen(
        identity: WindowIdentity,
        reason: WindowMoveReason,
        sessionID: String?,
        operationID: String? = nil
    ) -> Bool {
        let op = operationID ?? makeOperationID(prefix: "move")
        let startedAt = Date()
        log("[WindowManager] moveWindowToMainScreen started", fields: [
            "op": op,
            "windowID": String(identity.windowID),
            "pid": String(identity.pid),
            "reason": reason.rawValue,
            "sessionID": sessionID ?? "nil"
        ])

        guard hasAccessibilityPermission() else {
            log("moveWindowToMainScreen failed: accessibility not granted", level: .error, fields: ["op": op])
            notifyAccessibilityPermissionRequired()
            return false
        }

        guard let windowAX = resolveWindow(identity: identity) else {
            log("moveWindowToMainScreen failed: cannot resolve window", level: .error, fields: ["op": op])
            return false
        }

        guard let origFrame = frame(of: windowAX) else {
            log("moveWindowToMainScreen failed: cannot read current frame", level: .error, fields: ["op": op])
            return false
        }

        // 一次性查询窗口信息 — 后续复用缓存结果
        let windowInfo = spaceController.queryWindow(windowID: identity.windowID)
        let yabaiDisplay = windowInfo?.display.map { DisplayIdentifier.yabai($0) }

        // Skip if already on main screen
        if let display = yabaiDisplay?.yabaiIndex, display == 1 {
            if let mainScreen = getMainScreen() {
                let windowCenter = CGPoint(x: origFrame.midX, y: origFrame.midY)
                if mainScreen.frame.contains(windowCenter) {
                    log("[WindowManager] moveWindowToMainScreen skipped: already on main screen", fields: [
                        "op": op, "windowID": String(identity.windowID)
                    ])
                    return true
                }
            }
        }

        guard isAttributeSettable(windowAX, attribute: kAXPositionAttribute),
              isAttributeSettable(windowAX, attribute: kAXSizeAttribute) else {
            log("moveWindowToMainScreen failed: window attributes not settable", level: .error, fields: ["op": op])
            return false
        }

        // captureSpaceContext 内部的 queryWindow 和 querySpaces 会命中缓存
        let spaceContext = spaceController.captureSpaceContext(windowID: identity.windowID, operationID: op)

        log("[WindowManager] moveWindowToMainScreen: space context captured", fields: [
            "op": op,
            "windowID": String(identity.windowID),
            "sourceSpaceIndex": spaceContext.sourceSpaceIndex.map { String(describing: $0) } ?? "nil",
            "sourceDisplayIndex": spaceContext.sourceDisplayIndex.map { String(describing: $0) } ?? "nil",
            "sourceDisplaySpaceIndex": String(spaceContext.sourceDisplaySpaceIndex ?? -1),
            "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y)) \(Int(origFrame.width))x\(Int(origFrame.height))"
        ])

        guard let mainScreen = getMainScreen() else {
            log("moveWindowToMainScreen failed: cannot determine main screen", level: .error, fields: ["op": op])
            return false
        }

        let targetFrame = axFrame(forVisibleFrameOf: mainScreen)
        let targetDisplayID = displayID(for: mainScreen)
        let targetDisplayIndex = displayIndex(forDisplayID: targetDisplayID)

        // AX apply: move window to main screen
        guard apply(frame: targetFrame, to: windowAX, operationID: op, stage: "move_to_main") else {
            log("moveWindowToMainScreen failed: AX apply failed", level: .error, fields: [
                "op": op, "targetFrame": String(describing: targetFrame)
            ])
            return false
        }

        // Float on main screen — 传入已知的窗口信息（float 状态可能已变化，不传 knownWindowInfo）
        let effectiveWindowID = windowHandle(for: windowAX) ?? identity.windowID
        spaceController.setWindowFloat(effectiveWindowID, operationID: op)

        // Save toggle record
        let actualTargetFrame = frame(of: windowAX) ?? targetFrame
        let sourceSpaceIndex = spaceContext.sourceSpaceIndex ?? .yabai(0)
        let sourceContext = displayContext(for: origFrame)
        let teSourceDisplay: DisplayIdentifier = spaceContext.sourceDisplayIndex ?? sourceContext.index.map { .yabai($0) } ?? .yabai(0)
        let postMoveWindowID = windowHandle(for: windowAX) ?? effectiveWindowID
        if postMoveWindowID != effectiveWindowID {
            SessionWindowRegistry.shared.remapWindowID(oldWindowID: effectiveWindowID, newWindowID: postMoveWindowID)
        }
        ToggleEngine.shared.save(
            windowID: postMoveWindowID,
            pid: identity.pid,
            bundleIdentifier: identity.bundleIdentifier,
            appName: identity.appName,
            origFrame: origFrame,
            sourceSpace: sourceSpaceIndex,
            sourceDisplay: teSourceDisplay,
            sourceYabaiDisp: spaceContext.sourceDisplayIndex ?? .yabai(0),
            sourceDispSpace: spaceContext.sourceDisplaySpaceIndex ?? 0,
            targetFrame: actualTargetFrame,
            targetDisplay: targetDisplayIndex ?? 0,
            sessionID: sessionID
        )

        log("[WindowManager] moveWindowToMainScreen finished", fields: [
            "op": op,
            "windowID": String(effectiveWindowID),
            "durationMs": String(elapsedMilliseconds(since: startedAt))
        ])
        return true
    }
```

- [ ] **Step 4: 优化 moveToMainScreen 的 focusWindow 调用 — 传入已知窗口信息**

文件: `Sources/Window/WindowManager+Toggle.swift:234-236`（修改 focusWindow 调用）

替换:
```swift
            _ = spaceController.focusWindow(identity.windowID, operationID: op)
```

为:
```swift
            _ = spaceController.focusWindow(identity.windowID, operationID: op, knownWindowInfo: spaceController.queryWindow(windowID: identity.windowID))
```

注意：这里 queryWindow 会命中 Task 1 的缓存，不会产生新的 yabai spawn。

- [ ] **Step 5: 验证编译通过**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 6: 质量门禁 — 编译 + 全量测试**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5 && swift test 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - 无新增 FAIL

- [ ] **Step 7: 提交**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && git add Sources/Space/SpaceController+Move.swift Sources/Window/WindowManager+MoveWindow.swift Sources/Window/WindowManager+Toggle.swift && git commit -m "perf(move): eliminate redundant yabai queries in move-to-main path"`

---

### Task 3: 优化 restore 路径 — 减少冗余查询

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Toggle/ToggleEngine+Restore.swift:24-106` — 复用查询缓存
- Modify: `Sources/Window/WindowManager+Toggle.swift:73-74` — restore 路径传递窗口信息

- [ ] **Step 1: 在 toggle 方法中为 restore 路径预加载窗口信息到缓存**

文件: `Sources/Window/WindowManager+Toggle.swift:44-74`（在 shouldRestore 判断前添加预查询，将结果传入 restore）

当前代码在 L44 判断 shouldRestore 后，L73 调用 restore。restore 内部会重新 queryWindow。

在 `let shouldRestore = shouldRestoreCurrentWindow()` 之后，`if shouldRestore {` 之前添加预查询以确保缓存热:

```swift
        // 预查询窗口信息到缓存 — restore 路径会复用
        if let winIDStr = toggleContext["windowID"], let winID = UInt32(winIDStr) {
            _ = spaceController.queryWindow(windowID: winID)
        }
```

- [ ] **Step 2: 优化 restore 中的 setWindowFloat 调用 — 使用缓存**

文件: `Sources/Toggle/ToggleEngine+Restore.swift:58-77`（restore 方法中 setWindowFloat 和 focusWindow 调用）

当前 L77 的 `setWindowFloat` 会重新 queryWindow（但 Task 1 的缓存已解决）。
当前 L64 的 `moveWindow` 内部也会 queryWindow（缓存已解决）。

这些优化已通过 Task 1 的缓存自动生效，无需额外修改。

但可以优化 restore 中的 `focus` 参数：当 triggerSource 是 carbon_hotkey 时才 focus，否则跳过 focus 以节省一次 yabai 调用。

文件: `Sources/Toggle/ToggleEngine+Restore.swift:58-77` — 确认 moveWindow 内部的 queryWindow 会命中缓存。

验证 `moveWindow` L25 的 `queryWindow(windowID: windowID)` 和 `setWindowFloat` L60 的 `queryWindow(windowID: windowID)` 都会命中 Task 1 的缓存，无需额外改动。

- [ ] **Step 3: 验证编译通过**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -20`
Expected:
  - Exit code: 0

- [ ] **Step 4: 质量门禁 — 编译 + 全量测试**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5 && swift test 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - 无新增 FAIL

- [ ] **Step 5: 提交**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && git add Sources/Window/WindowManager+Toggle.swift && git commit -m "perf(restore): preload window info cache for restore path"`

---

### Task 4: 端到端验证 + 部署测试

**Depends on:** Task 2, Task 3
**Files:**
- No code changes — 纯验证

- [ ] **Step 1: 运行全量测试套件**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift test 2>&1 | tail -30`
Expected:
  - Exit code: 0
  - Output contains: "Test Suite" and "passed"
  - 无 FAIL

- [ ] **Step 2: 构建并部署到 /Applications**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0

然后执行 app bundle 部署（参考 [[vibefocus_deploy_workflow]]）:

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && ./scripts/deploy.sh 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - VibeFocus.app 更新到 /Applications

- [ ] **Step 3: 验证 VibeFocus 运行正常**

Run: `open /Applications/VibeFocus.app && sleep 2 && pgrep -f VibeFocus`
Expected:
  - Exit code: 0
  - Output contains: VibeFocus PID

- [ ] **Step 4: 检查 vibefocus.log 确认 toggle 操作耗时下降**

Run: `tail -100 ~/.vibefocus/vibefocus.log | grep -E "toggle finished|durationMs" | tail -10`
Expected:
  - durationMs 值应低于 300ms（优化前通常 600-1000ms）

- [ ] **Step 5: 质量门禁 — 最终确认**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift test 2>&1 | grep -E "passed|failed|Test Suite" | tail -10`
Expected:
  - Exit code: 0
  - 所有测试通过

- [ ] **Step 6: 提交最终验证记录**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && git add -A && git commit -m "perf: complete window toggle optimization — reduce yabai spawns from 6-10 to 2-3 per toggle"`

---

## Optimization Summary

### Before (per toggle)
```
toggle() → shouldRestoreCurrentWindow() → moveToMainScreen()
  ├── queryWindow #1 (windowDisplayIndex)    → yabai spawn 1
  ├── queryWindow #2 (captureSpaceContext)    → yabai spawn 2  ← REDUNDANT
  ├── querySpaces   (captureSpaceContext)     → yabai spawn 3
  ├── queryWindow #3 (setWindowFloat)         → yabai spawn 3  ← REDUNDANT
  ├── yabai toggle float                      → yabai spawn 4
  ├── queryWindow #4 (focusWindow)            → yabai spawn 5  ← REDUNDANT
  └── yabai focus                             → yabai spawn 6
Total: 6-10 yabai spawns, ~600-1000ms
```

### After (per toggle)
```
toggle() → shouldRestoreCurrentWindow() → moveToMainScreen()
  ├── queryWindow #1 (首次)                   → yabai spawn 1 ✓
  ├── queryWindow #2 (缓存命中)               → NO SPAWN ✓
  ├── querySpaces   (首次)                    → yabai spawn 2 ✓
  ├── queryWindow #3 (缓存命中)               → NO SPAWN ✓
  ├── yabai toggle float                      → yabai spawn 3 ✓
  ├── queryWindow #4 (缓存命中)               → NO SPAWN ✓
  └── yabai focus                             → yabai spawn 4 ✓
Total: 3-4 yabai spawns, ~150-300ms
```
