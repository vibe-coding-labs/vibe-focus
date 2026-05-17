# Fix Cross-Display Window Restore — CGEvent Drag Fallback

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复窗口从主屏幕恢复到副屏幕时失败的问题 — 当所有 space 移动策略失败后，使用 CGEvent 模拟鼠标拖拽将窗口移到目标显示器。

**Architecture:** Restore 触发 → space 移动失败 → **CGEvent 拖拽 fallback（新增）** → 窗口到达目标显示器 → AX 精确设置 origFrame。CGEvent 拖拽模拟用户手动拖动窗口到另一个显示器的行为，macOS 会自动处理跨显示器窗口重分配。

**Tech Stack:** Swift 5.9, macOS CoreGraphics (CGEvent), Accessibility (AXUIElement), macOS 14+

**Risks:**
- CGEvent 拖拽需要窗口应用在前台 → 缓解：拖拽前激活目标应用
- CGEvent 可能被某些 app 的 event tap 拦截 → 缓解：添加验证 + 重试
- 拖拽可能受到 yabai 浮动/平铺模式影响 → 缓解：yabai space 类型已是 float

---

## Root Cause Analysis

```
日志证据 (trace ups-00007559):

1. space 移动尝试:
   - NativeSpaceBridge → result=620756992 (失败)
   - yabai -m window 1272 --space 2 → exitCode=0 但窗口仍在 space 1
   - yabai -m space --focus 2 → "cannot focus space due to an error with the scripting-addition"
   → 所有策略失败

2. nudge 尝试 (当前 fallback):
   - Target: Y=1483.5 (副屏 Y 范围: 1117~2557)
   - Applied: Y=1089.0 (被 macOS 钳制到主屏范围内)

3. origFrame 尝试:
   - Target: Y=1825.0
   - Applied: Y=1089.0 (同样被钳制)

根因: yabai scripting-addition 未安装 (/Library/ScriptingAdditions/yabai.sdef 不存在)
      → yabai 无法真正移动窗口到其他 space
      → 窗口留在主屏 space → AX 设坐标被 macOS 钳制
```

---

### Task 1: Add CGEvent Window Drag Method in NativeSpaceBridge

**Depends on:** None
**Files:**
- Modify: `Sources/Space/NativeSpaceBridge.swift:99-155` (在现有 focusSpace 方法后添加)

- [ ] **Step 1: Add dragWindowToDisplay method — 模拟鼠标拖拽将窗口移到目标显示器**

文件: `Sources/Space/NativeSpaceBridge.swift:155` (文件末尾，focusSpace 方法之后)

```swift
// MARK: - Window Drag (CGEvent Mouse Simulation)

/// 通过 CGEvent 模拟鼠标拖拽，将窗口从当前显示器移到目标显示器。
/// macOS 在拖拽过程中检测到窗口跨显示器边界时，会自动将窗口重新分配到目标显示器。
/// 这复刻了用户手动拖动窗口到另一个显示器的行为。
///
/// 坐标系说明：
/// - AX frame (windowFrame): Quartz 坐标系 — 原点在主屏左上角，Y 向下
/// - NSScreen.frame (targetScreen): Cocoa 坐标系 — 原点在主屏左下角，Y 向上
/// - CGEvent: Quartz 坐标系 — 与 AX 相同
/// - 鼠标位置 (NSEvent.mouseLocation): Cocoa 坐标系
/// - 转换: quartzY = mainScreenHeight - cocoaY
static func dragWindowToDisplay(
    windowFrame: CGRect,
    targetScreen: NSScreen,
    operationID: String? = nil
) -> Bool {
    let op = operationID ?? "none"
    let mainScreenHeight = NSScreen.screens[0].frame.height

    // windowFrame 是 AX/Quartz 坐标，不需要转换
    // 标题栏在窗口顶部往下 15px（Quartz 坐标，Y 向下）
    let titleBarCG = CGPoint(x: windowFrame.midX, y: windowFrame.origin.y + 15)

    // targetScreen.frame 是 NSScreen/Cocoa 坐标，需要转换到 Quartz
    let targetCenterCocoaY = targetScreen.frame.origin.y + targetScreen.frame.height / 2
    let targetCenterCG = CGPoint(
        x: targetScreen.frame.origin.x + targetScreen.frame.width / 2,
        y: mainScreenHeight - targetCenterCocoaY
    )

    // NSEvent.mouseLocation 是 Cocoa 坐标，转换到 Quartz 用于恢复
    let savedCursorNS = NSEvent.mouseLocation
    let savedCursorCG = CGPoint(x: savedCursorNS.x, y: mainScreenHeight - savedCursorNS.y)

    log(
        "[NativeSpaceBridge] dragWindowToDisplay starting",
        level: .info,
        fields: [
            "op": op,
            "windowFrame": "\(windowFrame)",
            "titleBarCG": "\(titleBarCG)",
            "targetCenterCG": "\(targetCenterCG)",
            "targetScreenCocoa": "\(targetScreen.frame)"
        ]
    )

    // Step 1: 移动鼠标到标题栏
    postMouse(.mouseMoved, position: titleBarCG)
    usleep(30_000) // 30ms

    // Step 2: 鼠标按下
    postMouse(.leftMouseDown, position: titleBarCG)
    usleep(30_000)

    // Step 3: 分步拖拽到目标显示器（分 5 步，让 macOS 检测到跨显示器）
    let steps = 5
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let interpX = titleBarCG.x + (targetCenterCG.x - titleBarCG.x) * t
        let interpY = titleBarCG.y + (targetCenterCG.y - titleBarCG.y) * t
        postMouse(.leftMouseDragged, position: CGPoint(x: interpX, y: interpY))
        usleep(20_000) // 20ms per step
    }

    // Step 4: 确保到达目标位置
    postMouse(.leftMouseDragged, position: targetCenterCG)
    usleep(100_000) // 100ms 等待 macOS 处理显示器切换

    // Step 5: 鼠标释放
    postMouse(.leftMouseUp, position: targetCenterCG)
    usleep(50_000)

    // Step 6: 恢复鼠标位置
    postMouse(.mouseMoved, position: savedCursorCG)

    log(
        "[NativeSpaceBridge] dragWindowToDisplay completed",
        level: .info,
        fields: [
            "op": op,
            "targetScreenCocoa": "\(targetScreen.frame)"
        ]
    )
    return true
}

private static func postMouse(_ type: CGEventType, position: CGPoint) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: position, mouseButton: .left) else { return }
    event.post(tap: .cghidEventTap)
}
```

- [ ] **Step 2: 提交**
Run: `git add Sources/Space/NativeSpaceBridge.swift && git commit -m "feat(space): add CGEvent drag-to-display fallback for cross-display window moves"`

---

### Task 2: Integrate Drag Fallback into ToggleEngine Restore Flow

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Toggle/ToggleEngine.swift:184-230` (restore 方法的 step 5.5 两步恢复部分)

- [ ] **Step 1: 替换 ToggleEngine.restore() 中的两步恢复逻辑 — space 移动失败时用 CGEvent 拖拽替代 nudge**

文件: `Sources/Toggle/ToggleEngine.swift:190-230` (替换从 `// 5.5 两步恢复` 到 `restored = wm.apply(...)` 的整个 if/else 块)

```swift
        // 5.5 两步恢复：先确保窗口在目标显示器上，再精移到 origFrame
        // macOS 会限制窗口在当前 space 的显示器范围内，直接设副屏坐标会被 clamp
        // 策略：如果窗口仍在主屏但 origFrame 在副屏，先用 CGEvent 拖拽到副屏
        var restored = false
        let mainScreenFrame = NSScreen.screens.first { $0.frame.origin == .zero }?.frame ?? .zero
        let postSwitchFrame = wm.frame(of: restoreAX)
        let windowOnMain = postSwitchFrame.map { mainScreenFrame.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false
        let origOnMain = mainScreenFrame.contains(origCenter)

        if windowOnMain && !origOnMain {
            // 窗口仍在主屏但 origFrame 在副屏 — 尝试拖拽到副屏
            let targetScreen = NSScreen.screens.first { $0.frame.origin != .zero }
            if let screen = targetScreen {
                log(
                    "[ToggleEngine] restore: space move failed, trying CGEvent drag to target display",
                    level: .info,
                    fields: [
                        "traceID": trace,
                        "windowID": String(windowID),
                        "targetScreen": "\(screen.frame)",
                        "origFrame": "\(record.origFrame)"
                    ]
                )

                // 激活窗口所属应用，确保拖拽事件被正确接收
                if let app = NSRunningApplication(processIdentifier: pid_t(record.pid)) {
                    app.activate(options: .activateIgnoringOtherApps)
                    usleep(50_000)
                }

                // 用当前 frame（不是 origFrame）计算拖拽起点
                let dragFrame = postSwitchFrame ?? record.origFrame
                let dragSucceeded = NativeSpaceBridge.dragWindowToDisplay(
                    windowFrame: dragFrame,
                    targetScreen: screen,
                    operationID: trace
                )

                if dragSucceeded {
                    // 等待 macOS 完成显示器切换
                    usleep(150_000)

                    // 重新获取 AX element（窗口可能在新显示器上有新的引用）
                    let postDragAX = wm.findWindowByPID(record.pid, windowID: record.windowID) ?? restoreAX
                    let postDragFrame = wm.frame(of: postDragAX)

                    log(
                        "[ToggleEngine] restore: post-drag frame check",
                        level: .info,
                        fields: [
                            "traceID": trace,
                            "windowID": String(windowID),
                            "postDragFrame": postDragFrame.map { "\($0)" } ?? "nil",
                            "targetScreen": "\(screen.frame)"
                        ]
                    )

                    // 验证窗口是否已移到目标显示器
                    let nowOnMain = postDragFrame.map { mainScreenFrame.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? true
                    if !nowOnMain {
                        // 窗口已到副屏 — 应用精确 origFrame
                        restored = wm.apply(frame: record.origFrame, to: postDragAX, operationID: trace, stage: "restore_orig")
                    } else {
                        log(
                            "[ToggleEngine] restore: drag did not move window off main screen, trying direct apply as last resort",
                            level: .warn,
                            fields: [
                                "traceID": trace,
                                "windowID": String(windowID),
                                "postDragFrame": postDragFrame.map { "\($0)" } ?? "nil"
                            ]
                        )
                        restored = wm.apply(frame: record.origFrame, to: postDragAX, operationID: trace, stage: "restore_orig")
                    }
                } else {
                    restored = wm.apply(frame: record.origFrame, to: restoreAX, operationID: trace, stage: "restore_orig")
                }
            } else {
                restored = wm.apply(frame: record.origFrame, to: restoreAX, operationID: trace, stage: "restore_orig")
            }
        } else {
            // 窗口已在正确显示器或 origFrame 也在主屏 — 直接精移
            restored = wm.apply(frame: record.origFrame, to: restoreAX, operationID: trace, stage: "restore_orig")
        }
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/Toggle/ToggleEngine.swift && git commit -m "fix(restore): use CGEvent drag fallback when space move fails for cross-display restores"`

---

### Task 3: Build, Deploy and Verify

**Depends on:** Task 2
**Files:** None (build + deploy only)

- [ ] **Step 1: 构建并部署 app bundle**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && ./scripts/build-and-deploy.sh 2>&1 | tail -30`
Expected:
  - Exit code: 0
  - Output contains: "signed" or "Deployed"

- [ ] **Step 2: 重启 VibeFocus**
Run: `pkill -x VibeFocus; sleep 1; open /Applications/VibeFocus.app`
Expected:
  - VibeFocus app launches successfully

- [ ] **Step 3: 验证日志无报错**
Run: `sleep 3 && tail -20 /Users/cc11001100/Library/Logs/VibeFocus/vibefocus.log | grep -i "error\|crash\|fatal"`
Expected:
  - Exit code: 1 (no matches found)
  - No error lines in recent log

- [ ] **Step 4: 提交所有变更**
Run: `git add -A && git status`
