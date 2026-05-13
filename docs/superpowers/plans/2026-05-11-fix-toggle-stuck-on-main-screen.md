# Fix Toggle Stuck on Main Screen (P0 Regression)

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复窗口在主屏幕且无 ToggleRecord 时 toggle 无法切回的 bug。当窗口已在主屏且无恢复记录时，toggle 应将窗口移到副屏幕。

**Architecture:** 用户按 Ctrl+Q → toggle() → shouldRestoreCurrentWindow() 返回 false → 当前逻辑走 move_to_main（窗口已在主屏，无操作）。修复：检测"窗口在主屏 + 无 ToggleRecord"的 stuck 状态 → 移到副屏幕，形成正确的 toggle 循环。

**Tech Stack:** Swift 5.9, macOS 13+, AppKit NSScreen

**Risks:**
- 改变了"窗口一直在主屏"的 toggle 行为（之前无操作，现在会移到副屏）→ 这是正确的 toggle 行为
- 需要正确选择目标副屏幕（可能有多块副屏）→ 缓解：选择第一块非主屏的屏幕

---

### Task 1: Add "Move to Secondary Screen" Branch for Stuck Windows

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowManager+Toggle.swift:93-107`（在 else 分支中添加 stuck 检测）

- [ ] **Step 1: 修改 toggle() 函数 — 添加"窗口卡在主屏"的检测和副屏移动逻辑**

文件: `Sources/Window/WindowManager+Toggle.swift:79-107`（替换 shouldRestore/else 分支）

将现有的 if/else 分支改为三路分支：restore / move_to_secondary / move_to_main。当窗口在主屏且 `shouldRestore=false` 时，移到副屏。

```swift
        if shouldRestore {
            log(
                "[WindowManager] toggle branching to restore",
                level: .debug,
                fields: ["op": op]
            )
            restore(operationID: op, triggerSource: triggerSource)
            if let winIDStr = toggleContext["windowID"], let winID = UInt32(winIDStr) {
                AuditLogger.shared.record(
                    eventType: "toggle_restore",
                    windowID: winID,
                    details: ["mode": "restore", "source": triggerSource]
                )
            }
        } else if toggleContext["onMainScreen"] == "true" {
            // Window is on main screen but has no valid toggle record → stuck state.
            // Move to secondary screen to unblock the toggle cycle.
            log(
                "[WindowManager] toggle: window stuck on main screen with no toggle record, moving to secondary",
                level: .info,
                fields: ["op": op, "windowID": toggleContext["windowID"] ?? "nil"]
            )
            moveStuckWindowToSecondaryScreen(operationID: op, triggerSource: triggerSource)
            if let winIDStr = toggleContext["windowID"], let winID = UInt32(winIDStr) {
                AuditLogger.shared.record(
                    eventType: "toggle_move_to_secondary",
                    windowID: winID,
                    details: ["mode": "move_to_secondary_stuck", "source": triggerSource]
                )
            }
        } else {
            log(
                "[WindowManager] toggle branching to moveToMainScreen",
                level: .debug,
                fields: ["op": op]
            )
            moveToMainScreen(operationID: op, triggerSource: triggerSource)
            if let winIDStr = toggleContext["windowID"], let winID = UInt32(winIDStr) {
                AuditLogger.shared.record(
                    eventType: "toggle_move_to_main",
                    windowID: winID,
                    details: ["mode": "move_to_main", "source": triggerSource]
                )
            }
        }
```

- [ ] **Step 2: 添加 moveStuckWindowToSecondaryScreen 方法 — 将卡住的窗口移到副屏幕**

文件: `Sources/Window/WindowManager+Toggle.swift`（在 `moveToMainScreen` 方法之前添加）

```swift
    private func moveStuckWindowToSecondaryScreen(operationID: String, triggerSource: String) {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let focusedWin = focusedWindow(for: frontApp.processIdentifier),
              let currentFrame = frame(of: focusedWin) else {
            log("[WindowManager] moveStuckWindowToSecondaryScreen: no focused window", level: .warn)
            return
        }

        // Find first non-main screen
        let screens = NSScreen.screens
        guard screens.count > 1, let mainScreen = getMainScreen() else {
            log("[WindowManager] moveStuckWindowToSecondaryScreen: no secondary screen available", level: .warn)
            return
        }

        let secondaryScreen = screens.first { screen in
            !mainScreen.frame.contains(CGPoint(x: screen.frame.midX, y: screen.frame.midY))
        }

        guard let targetScreen = secondaryScreen else {
            log("[WindowManager] moveStuckWindowToSecondaryScreen: could not find secondary screen", level: .warn)
            return
        }

        let targetFrame = targetScreen.visibleFrame
        let newX = targetFrame.origin.x + (targetFrame.width - currentFrame.width) / 2
        let newY = targetFrame.origin.y + (targetFrame.height - currentFrame.height) / 2
        let centeredFrame = CGRect(x: newX, y: newY, width: currentFrame.width, height: currentFrame.height)

        let position = CGPoint(x: centeredFrame.origin.x, y: centeredFrame.origin.y)
        let size = CGSize(width: centeredFrame.width, height: centeredFrame.height)
        AXUIElementSetAttributeValue(focusedWin, kAXPositionAttribute as CFString, AXValueFromCGPoint(position) as! CFTypeRef)
        AXUIElementSetAttributeValue(focusedWin, kAXSizeAttribute as CFString, AXValueFromCGSize(size) as! CFTypeRef)

        log(
            "[WindowManager] moveStuckWindowToSecondaryScreen: moved window",
            fields: [
                "op": operationID,
                "windowID": String(describing: windowHandle(for: focusedWin)),
                "fromX": String(Int(currentFrame.origin.x)),
                "fromY": String(Int(currentFrame.origin.y)),
                "toX": String(Int(centeredFrame.origin.x)),
                "toY": String(Int(centeredFrame.origin.y))
            ]
        )
    }
```

- [ ] **Step 3: 验证编译**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 4: 部署并验证**
Run: `bash scripts/dev-build.sh 2>&1 | tail -10`
Expected:
  - Output contains: "构建成功"

- [ ] **Step 5: 提交**
Run: `git add Sources/Window/WindowManager+Toggle.swift && git commit -m "fix(toggle): handle window stuck on main screen with no toggle record"`
