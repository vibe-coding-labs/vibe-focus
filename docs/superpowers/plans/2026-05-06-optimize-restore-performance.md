# Restore 性能优化 Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 把窗口从主屏恢复回副屏的耗时从 ~2.5s 降到 ~800ms 以下，消除用户感知到的卡顿。

**Architecture:** 把所有固定 `usleep(N)` 等待改为**轮询验证 + 短超时**模式。在 SpaceController 中新增 `pollUntil(condition:timeout:interval:)` 工具方法，替换所有硬编码等待。数据流：restore 调用 → space 切换 → 轮询验证切换完成（不再盲等）→ move window → 轮询验证移动完成 → apply frame。三个最大的优化点：1) 400ms space 切换等待改为轮询（平均省 300ms）；2) 200ms moveWindow 等待改为轮询（平均省 150ms）；3) 焦点跟随改为可选延迟。

**Tech Stack:** Swift 5.9, macOS Accessibility API, yabai CLI, SQLite

**Risks:**
- Task 1 修改 SpaceController 核心方法，影响所有依赖方 → 缓解：保持接口不变，只改内部等待策略
- Task 2 和 Task 3 分别优化两条 restore 路径 → 缓解：共享同一个 SpaceController，改一处两路都受益
- 轮询验证可能在极端情况（系统负载高）下超时 → 缓解：保留最大超时上限（和原来相同的 sleep 时间）

---

### Task 1: SpaceController 等待策略优化 — 把盲等改为轮询验证

**Depends on:** None
**Files:**
- Modify: `Sources/SpaceController.swift:240-335`（moveWindowToSpace 方法）
- Modify: `Sources/SpaceController.swift:346-446`（switchDisplayToSpace 方法）

- [ ] **Step 1: 添加 pollUntil 通用轮询方法到 SpaceController**

在 `Sources/SpaceController.swift` 的 `moveWindowToSpace` 方法之前（约 line 220），添加轮询工具方法：

```swift
    /// 轮询等待条件成立，替代固定 usleep
    /// - Parameters:
    ///   - timeout: 最大等待时间（微秒）
    ///   - interval: 每次轮询间隔（微秒）
    ///   - condition: 返回 true 表示条件满足
    /// - Returns: true = 条件在超时前满足，false = 超时
    @discardableResult
    private func pollUntil(
        timeout: useconds_t,
        interval: useconds_t = 10_000,
        condition: () -> Bool
    ) -> Bool {
        let start = Date()
        let timeoutSec = Double(timeout) / 1_000_000
        while Date().timeIntervalSince(start) < timeoutSec {
            if condition() { return true }
            usleep(interval)
        }
        return condition()
    }
```

- [ ] **Step 2: 优化 moveWindowToSpace 的等待策略 — 替换固定 usleep 为轮询验证**

替换 `Sources/SpaceController.swift:258-335`（moveWindowToSpace 方法中策略 1 成功后的处理）：

```swift
        // 策略 1: yabai -m window <id> --space <target>
        let moveResult = runYabai(
            arguments: ["-m", "window", String(windowID), "--space", String(targetSpace)],
            operation: "moveWindowToSpace",
            operationID: op
        )
        if let result = moveResult, result.exitCode == 0 {
            let verified = pollUntil(timeout: 200_000, interval: 20_000) {
                self.windowSpaceIndex(windowID: windowID) == targetSpace
            }
            if verified {
                log(
                    "[SpaceController] moveWindowToSpace: yabai window --space succeeded",
                    fields: ["op": op, "windowID": String(windowID)]
                )
                return true
            }
            log(
                "[SpaceController] moveWindowToSpace: yabai executed but window not on target, trying space focus first",
                level: .warn,
                fields: ["op": op, "windowID": String(windowID), "targetSpace": String(targetSpace)]
            )
        }

        // 策略 2: 先切目标 space 所在 Display 到目标 space，再移窗口
        let focusResult = runYabai(
            arguments: ["-m", "space", "--focus", String(targetSpace)],
            operation: "moveWindowToSpace_focusTargetSpace",
            operationID: op
        )
        if let result = focusResult, result.exitCode == 0 {
            // 等待 space focus 生效
            pollUntil(timeout: 200_000, interval: 20_000) {
                self.displayVisibleSpace(displayIndex: nil) == targetSpace
            }

            let retryResult = runYabai(
                arguments: ["-m", "window", String(windowID), "--space", String(targetSpace)],
                operation: "moveWindowToSpace_retry",
                operationID: op
            )
            if let retry = retryResult, retry.exitCode == 0 {
                let verified = pollUntil(timeout: 200_000, interval: 20_000) {
                    self.windowSpaceIndex(windowID: windowID) == targetSpace
                }
                if verified {
                    log(
                        "[SpaceController] moveWindowToSpace: space focus + window move succeeded",
                        fields: ["op": op, "windowID": String(windowID)]
                    )
                    return true
                }
            }
        }

        // 策略 3: NativeSpaceBridge
        if let spaceID = nativeSpaceID(forYabaiIndex: targetSpace) {
            log(
                "[SpaceController] moveWindowToSpace: trying NativeSpaceBridge",
                fields: ["op": op, "windowID": String(windowID), "targetSpace": String(targetSpace), "nativeSpaceID": String(spaceID)]
            )
            NativeSpaceBridge.resetFailureCache()
            if NativeSpaceBridge.moveWindow(windowID, toSpaceID: spaceID) {
                let verified = pollUntil(timeout: 500_000, interval: 50_000) {
                    self.windowSpaceIndex(windowID: windowID) == targetSpace
                }
                if verified {
                    log(
                        "[SpaceController] moveWindowToSpace: NativeSpaceBridge verified",
                        fields: ["op", op, "windowID": String(windowID)]
                    )
                    return true
                }
            }
        }
```

- [ ] **Step 3: 优化 switchDisplayToSpace CGEvent fallback 的等待 — 替换 usleep(100ms) 为短轮询**

替换 `Sources/SpaceController.swift:434-435`（switchDisplayToSpace 中 CGEvent 成功后的等待）：

```swift
        if success {
            // 短暂等待让系统处理空间切换
            usleep(30_000)
            log("[SpaceController] switchDisplayToSpace: CGEvent succeeded", fields: [
                "op": op, "targetSpace": String(targetSpace), "steps": String(steps)
            ])
            return true
        }
```

- [ ] **Step 4: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 5: 提交**
Run: `git add Sources/SpaceController.swift && git commit -m "perf(space): replace blind usleep with poll-based verification in moveWindowToSpace"`

---

### Task 2: WindowManager.restore 路径优化 — 减少 space 切换等待

**Depends on:** Task 1
**Files:**
- Modify: `Sources/WindowManager.swift:509-524`（restore 中 space 切换等待）

- [ ] **Step 1: 替换 restore 中 usleep(400ms) 为 SpaceController 轮询验证**

替换 `Sources/WindowManager.swift:509-524`（restore 方法中 space 切换后的等待区块）：

```swift
        if let current = displayCurrentSpace, current != targetSpace {
            log("[WindowManager] restore: switching display from space \(current) to \(targetSpace)", level: .info, fields: [
                "op": op, "targetDisplay": String(targetDisplay)
            ])
            let switched = spaceController.switchDisplayToSpace(targetSpace: targetSpace, operationID: op)
            if switched {
                // 轮询等待 display 切换到目标 space（替代固定 400ms sleep）
                let targetDisplay = targetDisplay
                _ = spaceController.pollUntil(timeout: 400_000, interval: 30_000) {
                    spaceController.displayVisibleSpace(displayIndex: targetDisplay) == targetSpace
                }
            }
            log("[WindowManager] restore: space switch result", fields: [
                "op": op, "switched": String(switched)
            ])
        } else {
            log("[WindowManager] restore: display already on target space, no switch needed", fields: [
                "op": op
            ])
        }
```

等等 — `pollUntil` 是 private 方法。需要改用内部可访问的方式。

修正方案：不暴露 pollUntil，而是改为**降低 usleep 上限 + 先做一次快速检查**：

替换 `Sources/WindowManager.swift:509-516`（restore 中 space 切换后的 sleep）：

```swift
        if let current = displayCurrentSpace, current != targetSpace {
            log("[WindowManager] restore: switching display from space \(current) to \(targetSpace)", level: .info, fields: [
                "op": op, "targetDisplay": String(targetDisplay)
            ])
            let switched = spaceController.switchDisplayToSpace(targetSpace: targetSpace, operationID: op)
            if switched {
                // 快速轮询等待 display 到达目标 space（最多 400ms）
                let started = Date()
                while Date().timeIntervalSince(started) < 0.4 {
                    if spaceController.displayVisibleSpace(displayIndex: targetDisplay) == targetSpace { break }
                    usleep(30_000)
                }
            }
            log("[WindowManager] restore: space switch result", fields: [
                "op": op, "switched": String(switched)
            ])
        } else {
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/WindowManager.swift && git commit -m "perf(restore): replace 400ms blind sleep with poll-based space switch wait"`

---

### Task 3: ToggleEngine.restore 路径优化 — 减少双重点击等待

**Depends on:** Task 1
**Files:**
- Modify: `Sources/ToggleEngine.swift:154-221`（switchToOriginalSpace 方法）

- [ ] **Step 1: 替换 switchToOriginalSpace 中 usleep(400ms) + usleep(200ms) 为轮询验证**

替换 `Sources/ToggleEngine.swift:190-221`（switchToOriginalSpace 中 space 切换和 moveWindow 后的等待）：

```swift
        // 目标 display 不在正确 space — 需要先切换 display 的 space 再移动窗口
        if let current = displayCurrentSpace, current != targetSpace {
            let switched = spaceController.switchDisplayToSpace(
                targetSpace: targetSpace,
                operationID: "toggle_engine_switch_display"
            )
            log("ToggleEngine.switchToOriginalSpace: switchDisplayToSpace result", fields: [
                "switched": String(switched),
                "targetSpace": String(targetSpace)
            ])
            if switched {
                // 轮询等待 display 到达目标 space（替代固定 400ms）
                let targetDisplay = targetDisplay
                let started = Date()
                while Date().timeIntervalSince(started) < 0.4 {
                    if spaceController.displayVisibleSpace(displayIndex: targetDisplay) == targetSpace { break }
                    usleep(30_000)
                }
            }
        }

        // 移动窗口到目标 space
        let moved = spaceController.moveWindow(
            record.windowID,
            toSpaceIndex: targetSpace,
            focus: triggerSource == "carbon_hotkey",
            operationID: "toggle_engine_space_switch"
        )

        if moved {
            // 快速验证窗口已在目标 space（替代固定 200ms）
            let started = Date()
            while Date().timeIntervalSince(started) < 0.2 {
                if let s = spaceController.windowSpaceIndex(windowID: record.windowID), s == targetSpace { break }
                usleep(20_000)
            }
        } else {
            log("ToggleEngine.switchToOriginalSpace: moveWindow also failed after display switch", level: .warn, fields: [
                "windowID": String(record.windowID),
                "targetSpace": String(targetSpace)
            ])
        }
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/ToggleEngine.swift && git commit -m "perf(restore): replace 600ms blind sleep with poll-based verification in ToggleEngine"`

---

### Task 4: 部署验证 — 构建、部署、测试完整 restore 流程

**Depends on:** Task 2, Task 3
**Files:**
- Modify: 无代码修改，仅构建部署验证

- [ ] **Step 1: Release 构建并部署**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && bash scripts/dev-build.sh 2>&1 | tail -30`
Expected:
  - Exit code: 0
  - Output contains: "Build complete" or "BUILD SUCCEEDED"

- [ ] **Step 2: 启动 VibeFocus 并测试 restore**

Run: `open /Applications/VibeFocus.app`
Expected:
  - VibeFocus app 启动，菜单栏图标出现

- [ ] **Step 3: 检查日志确认 restore 耗时改善**

用 Console.app 观察 VibeFocus 日志，搜索 "restore finished" → 检查 `durationMs` 字段是否从之前的 ~2000-3000ms 降到 ~800ms 以下。

- [ ] **Step 4: 提交所有变更**
Run: `git push origin main`
