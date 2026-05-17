# Fix Restore Double-Move — Try AX Apply First, CGEvent Drag as Fallback

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 消除 restore 时的"窗口移动两次"现象 — 先尝试 AX 直接 apply origFrame，仅在 macOS 钳制坐标时才回退到 CGEvent 拖拽。

**Architecture:** Restore 触发 → 先 AX apply origFrame → 读回 frame → 如果匹配则完成（单次移动）→ 如果被钳制则回退到 CGEvent drag + AX apply（两次移动，仅在必要时）。

**Tech Stack:** Swift 5.9, macOS AXUIElement, CoreGraphics CGEvent

**Risks:**
- AX 跨显示器 apply 可能在某些 macOS 版本不生效 → 缓解：CGEvent 拖拽作为 fallback 仍然保留

---

### Task 1: Refactor ToggleEngine.restore() to Try AX Apply First

**Depends on:** None
**Files:**
- Modify: `Sources/Toggle/ToggleEngine.swift:197-280` (step 5.5 两步恢复区块)

- [ ] **Step 1: 替换 restore 流程中 step 5.5 — 先 AX apply，失败再 CGEvent drag**

文件: `Sources/Toggle/ToggleEngine.swift:197-280` (替换从 `// 5.5 两步恢复` 到 `restored = wm.apply(...)` 的整个 if/else 块)

```swift
        // 5.5 恢复窗口到原始位置
        // 策略：先尝试 AX 直接 apply origFrame（macOS 会自动处理跨显示器移动）
        // 仅在 AX 坐标被钳制时才回退到 CGEvent 拖拽
        var restored = false

        // 先尝试直接 apply
        restored = wm.apply(frame: record.origFrame, to: restoreAX, operationID: trace, stage: "restore_orig")

        if restored {
            // 直接 apply 成功 — 单次移动完成
            log("[ToggleEngine] restore: direct AX apply succeeded", level: .info, fields: [
                "traceID": trace,
                "windowID": String(windowID),
                "origFrame": "\(record.origFrame)"
            ])
        } else {
            // AX apply 失败（坐标被钳制） — 回退到 CGEvent 拖拽
            let mainScreenFrame = NSScreen.screens.first { $0.frame.origin == .zero }?.frame ?? .zero
            let currentFrame = wm.frame(of: restoreAX)
            let windowOnMain = currentFrame.map { mainScreenFrame.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false

            if windowOnMain && !mainScreenFrame.contains(origCenter) {
                let targetScreen = NSScreen.screens.first { $0.frame.origin != .zero }
                if let screen = targetScreen {
                    log(
                        "[ToggleEngine] restore: AX apply clamped, trying CGEvent drag fallback",
                        level: .info,
                        fields: [
                            "traceID": trace,
                            "windowID": String(windowID),
                            "currentFrame": currentFrame.map { "\($0)" } ?? "nil",
                            "targetScreen": "\(screen.frame)",
                            "origFrame": "\(record.origFrame)"
                        ]
                    )

                    if let app = NSRunningApplication(processIdentifier: pid_t(record.pid)) {
                        app.activate(options: .activateIgnoringOtherApps)
                        usleep(50_000)
                    }

                    let dragFrame = currentFrame ?? record.origFrame
                    let dragSucceeded = NativeSpaceBridge.dragWindowToDisplay(
                        windowFrame: dragFrame,
                        targetScreen: screen,
                        operationID: trace
                    )

                    if dragSucceeded {
                        usleep(150_000)
                        let postDragAX = wm.findWindowByPID(record.pid, windowID: record.windowID) ?? restoreAX
                        restored = wm.apply(frame: record.origFrame, to: postDragAX, operationID: trace, stage: "restore_orig_after_drag")
                    }
                }
            }

            if !restored {
                log("ToggleEngine.restore: all restore strategies failed", level: .error, fields: [
                    "traceID": trace,
                    "windowID": String(windowID)
                ])
            }
        }
```

- [ ] **Step 2: 验证编译**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 构建部署**
Run: `bash scripts/dev-build.sh 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - Output contains: "构建成功"

- [ ] **Step 4: 重启 VibeFocus 并验证无错误**
Run: `pkill -x VibeFocus; sleep 1; open /Applications/VibeFocus.app; sleep 3; tail -10 /Users/cc11001100/Library/Logs/VibeFocus/vibefocus.log | grep -i "error\|crash\|fatal" || echo "No errors"`
Expected:
  - Output: "No errors"

- [ ] **Step 5: 触发 restore 验证单次移动**
Run: `curl -s -X POST "http://127.0.0.1:$(python3 -c "import json; print(json.load(open('/Users/cc11001100/.vibefocus/hook-config.json'))['port'])")/claude/hook?token=$(python3 -c "import json; print(json.load(open('/Users/cc11001100/.vibefocus/hook-config.json'))['token'])")" -H "Content-Type: application/json" -d '{"event":"UserPromptSubmit","session_id":"5e863500-ac1c-4fa5-b0cd-9250bf0eefe2","cwd":"/Users/cc11001100/github/vibe-coding-labs/vibe-focus"}'`
Expected:
  - Output contains: "restored" or "no_binding_skip"

  然后检查日志确认 `direct AX apply succeeded` 出现且无 CGEvent drag fallback：
Run: `sleep 3 && grep "restore.*direct AX apply succeeded\|restore.*CGEvent drag fallback" /Users/cc11001100/Library/Logs/VibeFocus/vibefocus.log | tail -5`
Expected:
  - Contains "direct AX apply succeeded"
  - Does NOT contain "CGEvent drag fallback" (说明单次移动成功)

- [ ] **Step 6: 提交**
Run: `git add Sources/Toggle/ToggleEngine.swift && git commit -m "fix(restore): try AX apply first to eliminate double-move, CGEvent drag as fallback only"`
