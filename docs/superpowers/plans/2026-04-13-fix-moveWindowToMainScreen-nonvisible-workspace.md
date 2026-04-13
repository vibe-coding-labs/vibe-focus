# Fix: moveWindowToMainScreen skips non-visible workspace windows on secondary display

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 `moveWindowToMainScreen` 对非可见工作区窗口的 AX frame 误判，使 Stop hook 能正确地将副屏非可见工作区上的窗口移动到主屏幕。

**Architecture:** Stop hook → moveBindingToMainScreen (CG-based isWindowOnMainScreen 正确识别) → moveWindowToMainScreen → AX frame check (错误地认为在主屏) → skip。修复: 在 AX frame check 之前先用 yabai 查询窗口所在显示器编号，yabai 报告副显示器时无论 AX frame 如何都执行移动。

**Tech Stack:** Swift 5.9, AppKit, yabai, Accessibility API

**Risks:**
- yabai 在 Stop hook 时可能不可用 → 缓解: yabai 不可用时退回 AX frame check
- identity.windowID 可能与 AX 解析后的 windowID 不同 → 缓解: yabai 查询使用 identity.windowID，与后续 captureSpaceContext 一致

---

### Root Cause Analysis

**日志证据 (windowID=85, AgentQ, PID 65321):**

```
[16:56:05] restore_post_apply_frame appliedFrame="(332.0, -1415.0, 1145.0, 707.0)" windowActualSpace=Optional(4)
           ↑ 窗口已恢复到 space 4 (副屏)，AX frame 在副屏坐标

[17:05:28] Stop moving window windowID=85
[17:05:28] moveWindowToMainScreen started windowID=85
[17:05:28] moveWindowToMainScreen skipped: already on main screen windowID=85
           ↑ 9分钟后 Stop 触发，AX frame check 错误跳过
```

**根因:** 窗口在副屏的非可见工作区时，macOS AX API 报告的 frame 坐标不准确，可能重叠在主屏区域内。CGWindowListCopyWindowInfo 和 yabai 的 `display` 字段则能正确识别窗口所在显示器。

---

### Task 1: 修复 moveWindowToMainScreen 使用 yabai display 信息

**Depends on:** None
**Files:**
- Modify: `Sources/SpaceController.swift` (添加 `windowDisplayIndex` 公共方法)
- Modify: `Sources/WindowManagerSupport.swift:666-684` (AX frame check 替换为 yabai + AX 组合检查)

- [ ] **Step 1: 在 SpaceController 添加 windowDisplayIndex 公共方法**

文件: `Sources/SpaceController.swift` (在 `windowSpaceIndex` 方法之后添加)

```swift
    func windowDisplayIndex(windowID: UInt32) -> Int? {
        refreshAvailabilityIfNeeded()
        guard isEnabled, let window = queryWindow(windowID: windowID) else {
            return nil
        }
        return window.display
    }
```

- [ ] **Step 2: 修改 moveWindowToMainScreen — 将 AX-only 跳过检查替换为 yabai + AX 组合检查**

文件: `Sources/WindowManagerSupport.swift:666-684`（替换 AX frame 跳过逻辑）

将当前的纯 AX 检查:

```swift
        // 检查窗口是否已在主屏幕上
        // 如果已经在目标位置，跳过移动，避免覆盖已有的 saved state（原来的副屏位置）
        if let mainScreen = getMainScreen() {
            let mainScreenFrame = mainScreen.frame
            let windowCenter = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
            if mainScreenFrame.contains(windowCenter) {
                log(
                    "[WindowManager] moveWindowToMainScreen skipped: already on main screen",
                    fields: [
                        "op": op,
                        "windowID": String(identity.windowID),
                        "reason": reason.rawValue
                    ]
                )
                return true
            }
        }
```

替换为 yabai + AX 组合检查:

```swift
        // 检查窗口是否已在主屏幕上
        // 使用 yabai display 信息作为主要判断依据
        // AX frame 对非可见工作区的窗口不可靠（macOS 会报告错误的坐标）
        let yabaiDisplay = spaceController.windowDisplayIndex(windowID: identity.windowID)
        if let display = yabaiDisplay, display != 1 {
            // yabai 报告窗口在副显示器上，即使 AX frame 看起来在主屏也继续移动
            log(
                "[WindowManager] yabai reports window on secondary display, proceeding with move",
                fields: [
                    "op": op,
                    "windowID": String(identity.windowID),
                    "yabaiDisplay": String(display),
                    "axFrame": "\(currentFrame)"
                ]
            )
        } else if let mainScreen = getMainScreen() {
            let mainScreenFrame = mainScreen.frame
            let windowCenter = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
            if mainScreenFrame.contains(windowCenter) {
                log(
                    "[WindowManager] moveWindowToMainScreen skipped: already on main screen",
                    fields: [
                        "op": op,
                        "windowID": String(identity.windowID),
                        "reason": reason.rawValue,
                        "yabaiDisplay": yabaiDisplay.map(String.init) ?? "nil"
                    ]
                )
                return true
            }
        }
```

- [ ] **Step 3: 验证编译**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**

Run: `git add Sources/SpaceController.swift Sources/WindowManagerSupport.swift && git commit -m "fix(move): use yabai display info instead of AX frame for main-screen skip check"`

---

### Task 2: Build, Deploy, and Verify

**Depends on:** Task 1
**Files:**
- Modify: `Sources/AppVersion.swift` (version bump)

- [ ] **Step 1: Bump version to 0.0.17**

文件: `Sources/AppVersion.swift`

将版本号从 `"0.0.16"` 改为 `"0.0.17"`。

- [ ] **Step 2: Build release**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -3`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: Package and deploy**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && bash scripts/package_release.sh && killall VibeFocusHotkeys; sleep 1; cp .build/release/VibeFocusHotkeys ~/Applications/VibeFocus.app/Contents/MacOS/VibeFocusHotkeys && open ~/Applications/VibeFocus.app`
Expected:
  - Exit code: 0
  - Binary updated, new process starts

- [ ] **Step 4: Verify new process is running with correct binary**

Run: `ps aux | grep VibeFocus | grep -v grep && md5 ~/Applications/VibeFocus.app/Contents/MacOS/VibeFocusHotkeys && md5 /Users/cc11001100/github/vibe-coding-labs/vibe-focus/.build/release/VibeFocusHotkeys`
Expected:
  - New PID visible
  - Both MD5 hashes match

- [ ] **Step 5: Commit version bump**

Run: `git add Sources/AppVersion.swift && git commit -m "release: v0.0.17"`
