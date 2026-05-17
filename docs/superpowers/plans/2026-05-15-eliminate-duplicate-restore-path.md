# 消除 restore 双路径 — 根治 restore bug 反复出现

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 消除 WindowManager.restore() 和 ToggleEngine.restore() 之间的重复 restore 执行逻辑，使 ToggleEngine.restore() 成为唯一的 restore 执行入口，从根本上防止两条路径 drift 导致的回归 bug。

**Architecture:** Carbon hotkey → `toggle()` → `WindowManager.restore()` 做前置验证（AX 权限、窗口识别、record 校验） → 委托 `ToggleEngine.restore()` 执行（space switch + moveWindow + apply frame） → `WindowManager.restore()` 做后置处理（frame verify + focus follow + cleanup）。UserPromptSubmit hook → `HookEventHandler` → 直接调用 `ToggleEngine.restore()`。两条入口都经过同一个执行函数。

**Tech Stack:** Swift 5, macOS AX API, yabai space management

**Risks:**
- ToggleEngine.restore() 中的 isNearTarget 和 findWindowByPID 会与 WindowManager.restore() 重复执行 → 缓解：冗余检查无害，且保证 ToggleEngine 可独立调用
- ToggleEngine.restore() 目前始终返回 true（即使 apply 失败）→ Task 1 修正返回值

---

### Task 1: 修正 ToggleEngine.restore() 返回实际 apply 结果

**Depends on:** None
**Files:**
- Modify: `Sources/Toggle/ToggleEngine.swift:168-181`

- [ ] **Step 1: 修改 ToggleEngine.restore() 使其返回 apply 的实际结果而非硬编码 true**

文件: `Sources/Toggle/ToggleEngine.swift:168-181`（替换 restore 方法的结尾部分）

```swift
        let restored = wm.apply(frame: record.origFrame, to: restoreAX, operationID: trace, stage: "restore_orig")
        if !restored {
            log("ToggleEngine.restore: frame apply failed", level: .error, fields: [
                "traceID": trace
            ])
        }

        log("ToggleEngine.restore: finished", level: .info, fields: [
            "traceID": trace,
            "windowID": String(windowID),
            "restoredTo": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y))",
            "success": String(restored)
        ])
        return restored
```

- [ ] **Step 2: 验证编译**
Run: `swift build 2>&1 | tail -3`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/Toggle/ToggleEngine.swift && git commit -m "fix(restore): ToggleEngine.restore returns actual apply result instead of hardcoded true"`

---

### Task 2: 简化 WindowManager.restore() 委托给 ToggleEngine.restore()

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Window/WindowManager+Restore.swift:163-241`

- [ ] **Step 1: 将 WindowManager.restore() 中的 space-switch + moveWindow + apply frame 块替换为对 ToggleEngine.restore() 的委托调用**

文件: `Sources/Window/WindowManager+Restore.swift:163-241`（替换从 "// 8. Space 预切换" 到 "CrashContextRecorder.shared.record" 的 apply 失败分支）

替换为：

```swift
        // 8. 委托 ToggleEngine 执行 restore（space switch + moveWindow + apply frame）
        // ToggleEngine 是唯一的 restore 执行入口，避免双路径 drift 导致回归
        log("[WindowManager] restore: delegating to ToggleEngine.restore", fields: [
            "op": op,
            "windowID": String(currentWindowID),
            "triggerSource": triggerSource
        ])
        let restoreSucceeded = engine.restore(
            windowID: currentWindowID,
            triggerSource: triggerSource,
            traceID: op
        )
        log("[WindowManager] restore: ToggleEngine.restore returned", fields: [
            "op": op,
            "success": String(restoreSucceeded)
        ])

        guard restoreSucceeded else {
            log("[WindowManager] restore failed: ToggleEngine.restore returned false", level: .error, fields: [
                "op": op,
                "windowID": String(currentWindowID)
            ])
            CrashContextRecorder.shared.record("restore_failed_engine op=\(op)")
            return
        }

        // 9. ToggleEngine 执行后重新获取 AX element（space 切换可能使引用失效）
        let restoreAX = findWindowByPID(record.pid, windowID: currentWindowID) ?? window

        // 10. 验证 frame
        guard let restoredFrame = self.frame(of: restoreAX) else {
            log("[WindowManager] restore failed: cannot read back frame", level: .error, fields: ["op": op])
            CrashContextRecorder.shared.record("restore_failed_readback op=\(op)")
            return
        }

        guard framesMatch(restoredFrame, origFrame) else {
            log(
                "[WindowManager] restore failed: frame mismatch",
                level: .error,
                fields: [
                    "op": op,
                    "expected": String(describing: origFrame),
                    "actual": String(describing: restoredFrame),
                    "preApplyFrame": String(describing: currentFrame),
                    "targetSpace": String(targetSpace)
                ]
            )
            CrashContextRecorder.shared.record("restore_failed_frame_mismatch op=\(op)")
            return
        }
```

- [ ] **Step 2: 验证编译**
Run: `swift build 2>&1 | tail -3`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 部署并测试**
Run: `./scripts/dev-build.sh 2>&1 | tail -3`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error"

- [ ] **Step 4: 提交**
Run: `git add Sources/Window/WindowManager+Restore.swift && git commit -m "refactor(restore): eliminate duplicate restore path — WindowManager delegates to ToggleEngine

WindowManager.restore() now delegates space-switch + moveWindow + apply-frame
to ToggleEngine.restore() instead of reimplementing it. This ensures there is
only ONE restore execution path, preventing the recurring bug where one path
gets fixed but the other drifts.

Pre-validation (AX permission, window ID, record check) and post-processing
(frame verify, focus follow, cleanup) remain in WindowManager.restore()."`
