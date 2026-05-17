# Fix: Restore 缺少 moveWindow 调用导致窗口留在主屏

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 Carbon hotkey 触发的 restore 路径缺少 `spaceController.moveWindow()` 调用，导致窗口无法从主屏幕恢复到副屏幕的回归 bug。

**Architecture:** Carbon hotkey → `toggle()` → `WindowManager.restore()` 执行恢复时，只调用了 `switchDisplayToSpace()`（切换目标显示器可见的 Space），但没有调用 `moveWindow()`（将窗口分配到目标 Space）。窗口仍然在主屏幕的 Space 上，`apply(frame: origFrame)` 设置副屏坐标被 macOS 裁剪，窗口留在主屏。修复方法：在 `switchDisplayToSpace()` 之后、`apply(frame:)` 之前，添加 `spaceController.moveWindow()` 调用，与 `ToggleEngine.restore()` 中的 `switchToOriginalSpace()` 保持一致。

**Tech Stack:** Swift 5, macOS AX API, yabai space management

**Risks:**
- `moveWindow` 依赖 yabai/NativeSpaceBridge，如果两者都不可用则无法移动窗口 → 缓解：`ToggleEngine` 的同一调用在同样条件下工作，且 `moveWindow` 有多重策略回退

---

### Task 1: 在 WindowManager+Restore 的 Space 切换后添加 moveWindow 调用

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowManager+Restore.swift:193-214`

- [ ] **Step 1: 在 Space 切换成功后添加 moveWindow 调用 — 将窗口从主屏 Space 分配到目标 Space**

文件: `Sources/Window/WindowManager+Restore.swift:193-214`

在 Step 8 的 space 切换轮询等待完成后（line 193 之后）、Step 9 重新获取 AX element 之前（line 195 之前），插入 `moveWindow` 调用。参照 `ToggleEngine.switchToOriginalSpace()` 的逻辑（ToggleEngine.swift:252-278）。

替换 `Sources/Window/WindowManager+Restore.swift:193-214` 的代码块：

```swift
        // 8b. 将窗口移动到目标 space（必须在 apply frame 之前，否则 AX 坐标不匹配）
        let moveStart = Date()
        let moved = spaceController.moveWindow(
            currentWindowID,
            toSpaceIndex: targetSpace,
            focus: triggerSource == "carbon_hotkey",
            operationID: op
        )
        log("[WindowManager] restore: moveWindow result", fields: [
            "op": op,
            "moved": String(moved),
            "moveWindowMs": String(elapsedMilliseconds(since: moveStart))
        ])
        if moved {
            let started = Date()
            while Date().timeIntervalSince(started) < 0.2 {
                if let s = spaceController.windowSpaceIndex(windowID: currentWindowID), s == targetSpace { break }
                usleep(20_000)
            }
        } else {
            log("[WindowManager] restore: moveWindow failed, attempting AX frame apply anyway", level: .warn, fields: [
                "op": op,
                "windowID": String(currentWindowID),
                "targetSpace": String(targetSpace)
            ])
        }

        // 9. Space 切换后重新获取 AX element（引用可能失效）
        let restoreAX = findWindowByPID(record.pid, windowID: currentWindowID) ?? window

        // 10. Apply frame
        log("[WindowManager] restore: applying frame", fields: [
            "op": op,
            "currentFrame": String(describing: currentFrame),
            "targetOrigFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y)) \(Int(origFrame.size.width))x\(Int(origFrame.size.height))",
            "targetSpace": String(targetSpace),
            "targetDisplay": String(targetDisplay)
        ])
        guard apply(frame: origFrame, to: restoreAX, operationID: op, stage: "restore_apply_frame") else {
            log("[WindowManager] restore failed: apply frame failed", level: .error, fields: [
                "op": op,
                "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y))",
                "currentFrame": String(describing: currentFrame)
            ])
            CrashContextRecorder.shared.record("restore_failed_apply_frame op=\(op)")
            return
        }
```

- [ ] **Step 2: 验证编译通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 部署并测试**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && ./scripts/dev-build.sh 2>&1 | tail -3`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error"

- [ ] **Step 4: 提交**
Run: `git add Sources/Window/WindowManager+Restore.swift && git commit -m "fix(restore): add missing moveWindow call in WindowManager restore path

WindowManager.restore() was only calling switchDisplayToSpace() but not
moveWindow(), so the window stayed on the main screen's space. AX frame
apply with secondary display coordinates would fail or get clipped.

ToggleEngine.restore() already had the correct moveWindow() call via
switchToOriginalSpace(). This fix aligns WindowManager+Restore with the
proven ToggleEngine path."`
