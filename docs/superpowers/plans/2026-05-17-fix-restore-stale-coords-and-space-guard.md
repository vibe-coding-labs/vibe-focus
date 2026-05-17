# Bug Fix: Restore Stale Coordinates + Space Move Failure Guard

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复两个导致窗口 restore 后漂移到主屏底部的 bug：(1) 修复前保存的旧 toggle record 使用 Cocoa 坐标，被错误恢复；(2) yabai space 移动失败后仍 apply 副屏坐标，macOS 限制到主屏范围内。

**Root Cause 1:** `readAccurateFrame` 的 Cocoa→Quartz 坐标转换修复（commit 236f471）只影响新保存的 record。旧 SQLite record 中的 `origFrame` 仍是 Cocoa 坐标（Y=-1415），恢复时被当作 Quartz 坐标使用，窗口飞到屏幕上方，macOS 推到主屏底部只露标题栏。

**Root Cause 2:** `ToggleEngine.switchToOriginalSpace()` 中 yabai `window --space N` 报告 exitCode=0 但实际未移动窗口，verification polling 也失败。代码未中断恢复流程，继续 `apply(frame: origFrame)` 时窗口仍在主屏，AX 设 Y=1822（副屏坐标）被 macOS 限制到 Y=1089（主屏底部）。

**Architecture:** 在 `ToggleEngine.restore()` 中添加两道防线：(1) origFrame 校验 — 检查坐标是否在任何已知屏幕范围内，不在则清除 record；(2) space 移动结果检查 — 如果窗口仍不在目标屏幕上，跳过 frame apply。

**Tech Stack:** Swift 5.9, macOS 14+, NSScreen, AX API

**Risks:**
- origFrame 校验可能误拒合法部分在屏幕外的窗口 → 缓解：用 `insetBy(dx: -200, dy: -200)` 扩大检测范围
- 窗口 space 检测依赖 CGWindowList，可能与 yabai 结果不一致 → 缓解：用 Quartz 坐标直接判断窗口中心点所在屏幕

---

### Task 1: Add origFrame Validation in ToggleEngine.restore

**Depends on:** None
**Files:**
- Modify: `Sources/Toggle/ToggleEngine.swift:105-143` (restore 方法前半段)

- [ ] **Step 1: 在 restore 起始处添加 origFrame 屏幕校验 — 拦截修复前的旧 Cocoa 坐标 record**

文件: `Sources/Toggle/ToggleEngine.swift:113`（在 `log("ToggleEngine.restore: starting"...)` 之后、`let wm =` 之前插入）

```swift
        // 校验 origFrame 坐标是否在已知屏幕范围内
        // 修复前的旧 record 保存了 yabai Cocoa 坐标（如 Y=-1415），
        // 不在任何屏幕范围内，需要清除避免错误恢复
        let origCenter = CGPoint(x: record.origFrame.midX, y: record.origFrame.midY)
        let expandedBounds = NSScreen.screens.map { $0.frame.insetBy(dx: -200, dy: -200) }
        let onAnyScreen = expandedBounds.contains { $0.contains(origCenter) }
        if !onAnyScreen {
            log(
                "[ToggleEngine] restore: origFrame not on any screen, clearing corrupted record",
                level: .warn,
                fields: [
                    "traceID": trace,
                    "windowID": String(windowID),
                    "origFrame": "\(record.origFrame)",
                    "screens": NSScreen.screens.map { "\($0.frame)" }.joined(separator: ", ")
                ]
            )
            clear(windowID: windowID)
            return false
        }
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 3: 部署**
Run: `bash scripts/dev-build.sh 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "构建成功" or "签名验证通过"

- [ ] **Step 4: 提交**
Run: `git add Sources/Toggle/ToggleEngine.swift && git commit -m "fix(restore): validate origFrame against screen bounds to reject stale Cocoa-coordinate records"`

---

### Task 2: Guard Frame Apply After Failed Space Move

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Toggle/ToggleEngine.swift:160-168` (restore 方法后半段，switchToOriginalSpace 之后)

- [ ] **Step 1: 在 switchToOriginalSpace 后添加窗口实际屏幕位置检查 — 窗口仍在主屏时跳过 apply**

文件: `Sources/Toggle/ToggleEngine.swift:165`（在 `let restoreAX = ...` 之后、`let restored = wm.apply(...)` 之前插入）

```swift
        // 检查窗口是否实际在目标屏幕上
        // 如果 space 移动失败，窗口仍在主屏，apply 副屏坐标会被 macOS 限制到主屏底部
        if let restoredFrame = wm.frame(of: restoreAX) {
            let mainScreenFrame = NSScreen.screens.first { $0.frame.origin == .zero }?.frame ?? .zero
            let windowCenter = CGPoint(x: restoredFrame.midX, y: restoredFrame.midY)
            if mainScreenFrame.contains(windowCenter) {
                // 窗口在主屏上 — 检查 origFrame 是否也在主屏范围
                let origOnMain = mainScreenFrame.contains(origCenter)
                if !origOnMain {
                    log(
                        "[ToggleEngine] restore: window stuck on main screen after space move failure, skipping frame apply",
                        level: .warn,
                        fields: [
                            "traceID": trace,
                            "windowID": String(windowID),
                            "currentFrame": "\(restoredFrame)",
                            "origFrame": "\(record.origFrame)"
                        ]
                    )
                    return false
                }
            }
        }
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0

- [ ] **Step 3: 部署并重启**
Run: `bash scripts/dev-build.sh 2>&1 | tail -5 && open /Applications/VibeFocus.app`
Expected:
  - Exit code: 0

- [ ] **Step 4: 提交**
Run: `git add Sources/Toggle/ToggleEngine.swift && git commit -m "fix(restore): skip frame apply when window stuck on main screen after space move failure"`
