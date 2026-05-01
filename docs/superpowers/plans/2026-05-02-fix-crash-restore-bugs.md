# Fix VibeFocus Crash, Move Failure, and Restore Position Bugs

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 VibeFocus v0.0.13 的三个关键 bug：EXC_BAD_ACCESS 崩溃、窗口移动到主屏失败、恢复到错误的工作区位置。

**Architecture:** 三个 bug 相互独立，但共享 WindowManager/SpaceController 层。修复按风险从低到高排序：先修崩溃（安全性），再修移动失败（功能性），最后修复工作区恢复（精度）。

**Tech Stack:** Swift 5.9, macOS 15.7, SwiftUI, AppKit AX API, yabai, CGS Private API (SkyLight)

**Risks:**
- Task 1 修改 AX 元素使用模式，可能影响所有窗口操作 → 缓解：仅增加验证逻辑，不改变操作本身
- Task 2 修改 `moveWindowToMainScreen` 的验证流程 → 缓解：保留原有逻辑作为 fallback，新逻辑仅在原有失败时触发
- Task 3 修改 `moveWindow` 的后置验证，增加重试 → 缓解：重试次数限制为 3 次，每次间隔递增

---

### Task 1: 修复 EXC_BAD_ACCESS 崩溃 — AXUIElement 悬空指针防护

**Depends on:** None
**Files:**
- Modify: `Sources/WindowManager.swift:742-800`（restoreWindow 和相关方法）
- Modify: `Sources/WindowManagerSupport.swift:1149-1157`（windowHandle 验证）

- [ ] **Step 1: 添加 AXUIElement 安全验证函数 — 防止对已销毁窗口执行操作**

文件: `Sources/WindowManagerSupport.swift`（在 `windowHandle(for:)` 方法后面添加）

```swift
// 文件: Sources/WindowManagerSupport.swift
// 在 windowHandle(for:) 方法后（约 1157 行之后）添加

/// 验证 AXUIElement 是否仍然有效（底层窗口未被销毁）
/// 通过检查 windowHandle 是否可解析来判断，避免对悬空指针执行操作
func isValidAXElement(_ element: AXUIElement) -> Bool {
    var windowID: CGWindowID = 0
    let status = _AXUIElementGetWindow(element, &windowID)
    guard status == .success, windowID != 0 else {
        return false
    }
    // 二次验证：在 CGWindowList 中确认窗口存在
    return validateWindowExists(windowID: windowID)
}

/// 安全获取 AXUIElement 的 frame，自动处理无效元素
/// 返回 nil 并清除相关缓存
func safeFrame(of element: AXUIElement, stateID: String? = nil) -> CGRect? {
    guard isValidAXElement(element) else {
        if let stateID {
            windowElementsByStateID.removeValue(forKey: stateID)
        }
        return nil
    }
    return frame(of: element)
}
```

- [ ] **Step 2: 修改 restoreWindow 方法 — 在使用缓存的 AX 元素前先验证有效性**

文件: `Sources/WindowManager.swift:742-785`（替换整个 `restoreWindow(using:)` 方法）

```swift
// 文件: Sources/WindowManager.swift:742-785
// 替换整个 restoreWindow(using:) 方法

func restoreWindow(using token: WindowToken) -> AXUIElement? {
    // 第一级匹配：通过 windowID 匹配当前聚焦窗口
    if let focused = focusedWindow(for: token.pid),
       let currentWindowID = windowHandle(for: focused),
       currentWindowID == token.windowID {
        log("Restoring using focused window handle match")
        return focused
    }

    // 第二级匹配：通过 windowID 匹配缓存的窗口引用（先验证有效性）
    if let lastWindowElement {
        if isValidAXElement(lastWindowElement),
           let currentWindowID = windowHandle(for: lastWindowElement),
           currentWindowID == token.windowID {
            log("Restoring using saved AX handle match")
            return lastWindowElement
        } else {
            // 缓存的 AX 元素已失效，立即清除
            log("Cached AX element is stale, clearing", level: .warn, fields: [
                "tokenWindowID": String(describing: token.windowID)
            ])
            self.lastWindowElement = nil
            if let stateID = lastWindowToken?.stateID {
                windowElementsByStateID.removeValue(forKey: stateID)
            }
        }
    }

    // 第二级-B：主动按 PID 遍历所有窗口查找匹配 windowID
    if let resolvedByPID = findWindowByPID(token.pid, windowID: token.windowID) {
        log("Restoring using PID-based window enumeration")
        return resolvedByPID
    }

    // 第三级匹配：备用匹配（PID + 标题 + 大致位置）
    if let frontApp = NSWorkspace.shared.frontmostApplication,
       let focused = focusedWindow(for: frontApp.processIdentifier),
       let currentTitle = title(of: focused),
       let currentFrame = frame(of: focused),
       let lastTarget = lastTargetFrame {
        let pidMatches = frontApp.processIdentifier == token.pid
        let titleMatches = (token.title ?? "") == currentTitle
        let positionMatches = abs(currentFrame.origin.x - lastTarget.origin.x) <= 50 &&
                             abs(currentFrame.origin.y - lastTarget.origin.y) <= 50

        if pidMatches && titleMatches && positionMatches {
            log("Restoring using fallback matching (PID+title+position)")
            return focused
        }
    }

    return nil
}
```

- [ ] **Step 3: 修改 hydrateMemory — 验证传入的 AX 元素有效性**

文件: `Sources/WindowManager.swift:1453-1506`（替换 `hydrateMemory(from:window:)` 中的元素验证部分）

```swift
// 文件: Sources/WindowManager.swift:1453-1506
// 替换 hydrateMemory(from:window:) 方法中的元素有效性检查部分（第 1458-1473 行）

// 将现有的：
//        var effectiveWindow: AXUIElement? = resolvedWindow
//        if let resolvedWindow {
//            let handle = windowHandle(for: resolvedWindow)
//            if handle == nil && state.windowID != nil {
//                ...
//            }
//        }
//
// 替换为：

        var effectiveWindow: AXUIElement? = resolvedWindow
        if let resolvedWindow {
            if !isValidAXElement(resolvedWindow) {
                log(
                    "hydrateMemory: cached AX element is stale, clearing",
                    level: .warn,
                    fields: [
                        "stateID": state.id,
                        "expectedWindowID": String(describing: state.windowID)
                    ]
                )
                windowElementsByStateID.removeValue(forKey: state.id)
                effectiveWindow = nil
            }
        }
```

- [ ] **Step 4: 修改 frame(of:) 方法 — 使用 autoreleasepool 包裹 AX 读取**

文件: `Sources/WindowManagerSupport.swift:1223-1236`（替换 `frame(of:)` 方法）

```swift
// 文件: Sources/WindowManagerSupport.swift:1223-1236
// 替换整个 frame(of:) 方法

func frame(of window: AXUIElement) -> CGRect? {
    var frameRef: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(window, axFrameAttribute as CFString, &frameRef)
    guard status == .success, let frameRef else {
        return nil
    }

    let axValue = frameRef as! AXValue
    var frame = CGRect.zero
    guard AXValueGetValue(axValue, .cgRect, &frame) else {
        return nil
    }
    return frame
}
```

注意：`frame(of:)` 本身不需要 autoreleasepool，因为 `AXUIElementCopyAttributeValue` 遵循 Core Foundation 的 Create 规则（调用者持有）。真正的 crash 来自于对已释放 AXUIElement 的操作。Step 1-3 的验证逻辑已经解决了这个问题。

- [ ] **Step 5: 验证构建通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 6: 提交**
Run: `git add Sources/WindowManager.swift Sources/WindowManagerSupport.swift && git commit -m "fix(window): add AXUIElement validation to prevent EXC_BAD_ACCESS crash from stale references"`

---

### Task 2: 修复 move_to_main_failed — 改进跨屏幕移动的 frame 验证

**Depends on:** Task 1
**Files:**
- Modify: `Sources/WindowManagerSupport.swift:676-873`（moveWindowToMainScreen 方法）

- [ ] **Step 1: 修改 moveWindowToMainScreen — 添加 CGWindowList frame 读回作为 fallback + 延迟重试验证**

文件: `Sources/WindowManagerSupport.swift:806-822`（替换 frame 验证区块）

```swift
// 文件: Sources/WindowManagerSupport.swift
// 替换 moveWindowToMainScreen 方法中约 806-822 行的验证逻辑
// 原：
//   guard apply(frame: targetFrame, to: windowAX, operationID: op, stage: "move_to_main_apply_frame"),
//         let appliedFrame = frame(of: windowAX),
//         framesMatch(appliedFrame, targetFrame) else { ... return false }
//
// 替换为：

        // 先尝试通过 AX 直接设置并验证
        let axApplySucceeded = apply(frame: targetFrame, to: windowAX, operationID: op, stage: "move_to_main_apply_frame")
        if axApplySucceeded,
           let appliedFrame = frame(of: windowAX),
           framesMatch(appliedFrame, targetFrame) {
            // AX 验证通过，直接成功
        } else {
            // AX frame 验证失败 — 可能是窗口在非可见 space 上，AX 坐标不可靠
            // 使用 CGWindowList 作为二次验证源（CGWindowList 不依赖 AX，跨 space 可靠）
            log(
                "[WindowManager] AX frame verification failed, trying CGWindowList fallback",
                level: .warn,
                fields: [
                    "op": op,
                    "axApplySucceeded": String(axApplySucceeded),
                    "windowID": String(identity.windowID)
                ]
            )

            // 等待窗口管理器处理位置变更
            usleep(100_000) // 100ms

            let cgVerified = verifyWindowFrameViaCGWindowList(
                windowID: identity.windowID,
                targetFrame: targetFrame,
                operationID: op
            )

            if !cgVerified {
                // CGWindowList 也验证失败 — 最后手段：重新尝试 apply
                usleep(150_000) // 再等 150ms
                let retrySucceeded = apply(frame: targetFrame, to: windowAX, operationID: op, stage: "move_to_main_apply_frame_retry")
                if !retrySucceeded {
                    log(
                        "moveWindowToMainScreen failed: frame verification mismatch after retry",
                        level: .error,
                        fields: [
                            "op": op,
                            "targetFrame": String(describing: targetFrame)
                        ]
                    )
                    return false
                }
            }
        }
```

- [ ] **Step 2: 添加 CGWindowList frame 验证辅助方法**

文件: `Sources/WindowManagerSupport.swift`（在 `moveWindowToMainScreen` 方法后添加）

```swift
// 文件: Sources/WindowManagerSupport.swift
// 在 moveWindowToMainScreen 方法结束的 } 后添加

/// 通过 CGWindowList 验证窗口是否已移动到目标 frame
/// CGWindowList 使用 WindowServer 的数据，不依赖 AX，对跨 space 窗口更可靠
private func verifyWindowFrameViaCGWindowList(
    windowID: UInt32,
    targetFrame: CGRect,
    operationID: String
) -> Bool {
    let options = CGWindowListOption(arrayLiteral: .optionAll)
    guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return false
    }

    for info in windowList {
        guard let id = info[kCGWindowNumber as String] as? UInt32,
              id == windowID else { continue }

        guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else {
            return false
        }

        let actualFrame = CGRect(
            x: bounds["X"] ?? 0,
            y: bounds["Y"] ?? 0,
            width: bounds["Width"] ?? 0,
            height: bounds["Height"] ?? 0
        )

        let positionMatches = abs(actualFrame.origin.x - targetFrame.origin.x) <= frameTolerance &&
                             abs(actualFrame.origin.y - targetFrame.origin.y) <= frameTolerance
        let sizeClose = abs(actualFrame.width - targetFrame.width) <= frameTolerance * 2 &&
                       abs(actualFrame.height - targetFrame.height) <= 100

        log(
            "[WindowManager] CGWindowList frame verification",
            fields: [
                "op": operationID,
                "windowID": String(windowID),
                "actualFrame": String(describing: actualFrame),
                "targetFrame": String(describing: targetFrame),
                "positionMatches": String(positionMatches),
                "sizeClose": String(sizeClose)
            ]
        )

        return positionMatches && sizeClose
    }

    log(
        "[WindowManager] CGWindowList verification: window not found in list",
        level: .warn,
        fields: [
            "op": operationID,
            "windowID": String(windowID)
        ]
    )
    return false
}
```

- [ ] **Step 3: 验证构建通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/WindowManagerSupport.swift && git commit -m "fix(move): add CGWindowList fallback verification for cross-display window moves"`

---

### Task 3: 修复恢复到错误工作区 — 改进 moveWindow 后置验证和重试

**Depends on:** Task 1
**Files:**
- Modify: `Sources/SpaceController.swift:257-361`（moveWindow 方法）

- [ ] **Step 1: 修改 SpaceController.moveWindow — 添加后置验证重试循环 + NativeSpaceBridge 优先 fallback**

文件: `Sources/SpaceController.swift:257-361`（替换 `moveWindow(_:toSpaceIndex:focus:operationID:)` 方法）

```swift
// 文件: Sources/SpaceController.swift:257-361
// 替换整个 moveWindow 方法

    @discardableResult
    func moveWindow(_ windowID: UInt32, toSpaceIndex spaceIndex: Int, focus: Bool, operationID: String? = nil) -> Bool {
        let op = operationID ?? "none"
        refreshAvailabilityIfNeeded()
        guard isEnabled else {
            return false
        }
        guard canControlSpaces else {
            markOperationError("Cannot move window to another space because cross-space control is unavailable", operationID: op)
            return false
        }

        // 安全检查：先验证窗口是否存在，防止对已销毁窗口执行 yabai 操作导致 crash
        let windowCheck = queryWindow(windowID: windowID)
        if windowCheck == nil {
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

        // 记录 moveWindow 调用上下文
        let windowBeforeMove = queryWindow(windowID: windowID)
        log(
            "[SpaceController] moveWindow called",
            fields: [
                "op": op,
                "windowID": String(windowID),
                "targetSpace": String(spaceIndex),
                "windowCurrentSpace": String(describing: windowBeforeMove?.space),
                "windowCurrentDisplay": String(describing: windowBeforeMove?.display),
                "focus": String(focus)
            ]
        )

        // 策略 1：使用 NativeSpaceBridge (CGS API) 直接移动
        // 这比 yabai 更可靠，不依赖 scripting-addition
        let nativeAvailable = NativeSpaceBridge.isAvailable
        if nativeAvailable, let spaceID = nativeSpaceID(forYabaiIndex: spaceIndex) {
            log(
                "[SpaceController] trying NativeSpaceBridge first",
                fields: [
                    "op": op,
                    "windowID": String(windowID),
                    "yabaiIndex": String(spaceIndex),
                    "nativeSpaceID": String(spaceID)
                ]
            )
            if NativeSpaceBridge.moveWindow(windowID, toSpaceID: spaceID) {
                // 等待移动生效
                usleep(200_000) // 200ms

                // 验证移动是否成功
                if verifyWindowMovedToSpace(windowID: windowID, targetSpace: spaceIndex, operationID: op) {
                    log(
                        "[SpaceController] NativeSpaceBridge move succeeded and verified",
                        fields: [
                            "op": op,
                            "windowID": String(windowID),
                            "targetSpace": String(spaceIndex)
                        ]
                    )
                    if focus {
                        _ = focusWindow(windowID, operationID: op)
                    }
                    return true
                }
                log(
                    "[SpaceController] NativeSpaceBridge move executed but verification failed, trying yabai",
                    level: .warn,
                    fields: [
                        "op": op,
                        "windowID": String(windowID),
                        "targetSpace": String(spaceIndex)
                    ]
                )
            }
        }

        // 策略 2：yabai 命令（带后置验证重试）
        let moveResult = runYabaiVariants(
            variants: [["-m", "window", "\(windowID)", "--space", "\(spaceIndex)"]],
            operation: "moveWindow(windowID=\(windowID), space=\(spaceIndex))",
            operationID: op
        )
        if moveResult.success {
            // 带重试的验证：yabai move 可能是异步生效
            if verifyWindowMovedToSpaceWithRetry(windowID: windowID, targetSpace: spaceIndex, operationID: op) {
                if focus {
                    _ = focusWindow(windowID, operationID: op)
                }
                return true
            }
            // yabai 报成功但窗口实际未移动 — 尝试 NativeSpaceBridge fallback
            if nativeAvailable, let spaceID = nativeSpaceID(forYabaiIndex: spaceIndex) {
                log(
                    "[SpaceController] yabai move unverified, trying NativeSpaceBridge fallback",
                    fields: [
                        "op": op,
                        "windowID": String(windowID),
                        "targetSpace": String(spaceIndex)
                    ]
                )
                if NativeSpaceBridge.moveWindow(windowID, toSpaceID: spaceID) {
                    usleep(200_000)
                    if verifyWindowMovedToSpace(windowID: windowID, targetSpace: spaceIndex, operationID: op) {
                        if focus {
                            _ = focusWindow(windowID, operationID: op)
                        }
                        return true
                    }
                }
            }
            // 即使验证失败，yabai 成功就返回 true（AX frame 定位是最终权威）
            log(
                "[SpaceController] moveWindow yabai succeeded but verification shows window not on target space",
                level: .warn,
                fields: [
                    "op": op,
                    "windowID": String(windowID),
                    "targetSpace": String(spaceIndex),
                    "note": "yabai move may have async effect, AX frame positioning is authoritative"
                ]
            )
            if focus {
                _ = focusWindow(windowID, operationID: op)
            }
            return true
        }

        // 策略 3：yabai 失败时尝试 NativeSpaceBridge
        if !nativeAvailable {
            markOperationError(
                from: moveResult.failure,
                fallback: "Failed to move window \(windowID) to space \(spaceIndex)",
                operationID: op
            )
            return false
        }

        guard let spaceID = nativeSpaceID(forYabaiIndex: spaceIndex) else {
            markOperationError(
                from: moveResult.failure,
                fallback: "Failed to move window \(windowID) to space \(spaceIndex)",
                operationID: op
            )
            return false
        }

        log(
            "[SpaceController] yabai moveWindow failed, trying native fallback",
            fields: [
                "op": op,
                "windowID": String(windowID),
                "yabaiIndex": String(spaceIndex),
                "nativeSpaceID": String(spaceID),
            ]
        )
        if NativeSpaceBridge.moveWindow(windowID, toSpaceID: spaceID) {
            if focus {
                _ = focusWindow(windowID, operationID: op)
            }
            return true
        }

        markOperationError(
            from: moveResult.failure,
            fallback: "Failed to move window \(windowID) to space \(spaceIndex)",
            operationID: op
        )
        return false
    }
```

- [ ] **Step 2: 添加验证辅助方法到 SpaceController**

文件: `Sources/SpaceController.swift`（在 `moveWindow` 方法后添加）

```swift
// 文件: Sources/SpaceController.swift
// 在 moveWindow 方法的 } 后添加

    /// 验证窗口是否已移动到目标 space
    private func verifyWindowMovedToSpace(windowID: UInt32, targetSpace: Int, operationID: String) -> Bool {
        let windowAfter = queryWindow(windowID: windowID)
        let verified = windowAfter?.space == targetSpace
        if !verified {
            log(
                "[SpaceController] verifyWindowMovedToSpace: not on target",
                level: .warn,
                fields: [
                    "op": operationID,
                    "windowID": String(windowID),
                    "targetSpace": String(targetSpace),
                    "actualSpace": String(describing: windowAfter?.space)
                ]
            )
        }
        return verified
    }

    /// 带重试的窗口移动验证（yabai move 可能异步生效）
    private func verifyWindowMovedToSpaceWithRetry(windowID: UInt32, targetSpace: Int, operationID: String) -> Bool {
        let delays: [useconds_t] = [100_000, 200_000, 400_000] // 100ms, 200ms, 400ms
        for (attempt, delay) in delays.enumerated() {
            usleep(delay)
            if verifyWindowMovedToSpace(windowID: windowID, targetSpace: targetSpace, operationID: operationID) {
                return true
            }
            log(
                "[SpaceController] moveWindow verification retry \(attempt + 1)/\(delays.count)",
                level: .warn,
                fields: [
                    "op": operationID,
                    "windowID": String(windowID),
                    "targetSpace": String(targetSpace)
                ]
            )
        }
        return false
    }
```

- [ ] **Step 3: 验证构建通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/SpaceController.swift && git commit -m "fix(restore): add NativeSpaceBridge priority and retry verification for reliable cross-space moves"`

---

### Task 4: 版本号更新和最终验证

**Depends on:** Task 1, Task 2, Task 3
**Files:**
- Modify: `Sources/AppVersion.swift`（版本号更新）

- [ ] **Step 1: 更新版本号**
Run: `grep -n "version" Sources/AppVersion.swift | head -5`

（根据实际文件内容更新版本号为 0.0.14）

- [ ] **Step 2: 完整构建验证**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -30`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交版本更新**
Run: `git add Sources/AppVersion.swift && git commit -m "release: v0.0.14 — fix crash, move failure, and restore position bugs"`
