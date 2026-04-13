# Fix: focusSpace CGEvent Fallback 跨显示器切换失败

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 `focusSpace` 方法的 CGEvent fallback 在跨显示器场景下始终跳过的问题，使用户通过发送提示词恢复窗口到副屏时能正确切换工作区焦点。

**Architecture:** restore 流程: UserPromptSubmit → handleUserPromptSubmit → restore → applySpaceStrategyForRestore → focusSpace(sourceSpace) → yabai `space --focus` 失败(scripting-addition 损坏) → CGEvent fallback → `calculateFocusSteps` 返回 steps=0 (错误地认为已在目标 space) → 跳过 → focusSpace 返回 true 但未切换 → moveWindow 通过 yabai 成功移动窗口到目标 space → frame 应用正确 → 但用户焦点仍停留在主显示器。修复: calculateFocusSteps 需要检查全局焦点 space 而非目标显示器上的可见 space; focusSpace 在 steps=0 时仍需移动光标到目标显示器以切换活跃显示器。

**Tech Stack:** Swift 5.9, AppKit, CGEvent API, yabai

**Risks:**
- CGEvent mouseMoved 在某些 macOS 版本可能不触发显示器切换 → 缓解: 当前代码已有使用 CGEvent mouseMoved 的先例且工作正常
- 修改 focusSpace 可能影响手动快捷键触发的 restore → 缓解: 手动快捷键也走同样的 focusSpace 路径，修复对两者都有益

---

### Root Cause Analysis

**日志证据（v0.0.15, PID 65321）— 每次 restore 都出现:**

```
calculateFocusSteps currentIdx=0 display=2 displaySpaces="2:v=true,3:v=false,4:v=false" steps=0 target=2 targetIdx=0
CGEvent fallback skipped: steps=0 (already on target space) currentSpace=Optional(1)
restore_space_post_settle settleOk=false targetSpace=2
```

**根因 1: `calculateFocusSteps` 使用目标显示器上的可见 space 作为"当前 space"**

`Sources/SpaceController.swift:1077-1082` — `currentSpace = displaySpaces.first(where: { $0.isVisible == true })` 找到目标显示器上可见的 space。因为 macOS 每个显示器同时只显示一个 space，可见 space 永远与目标 space 相同（如果窗口在那个 space 上）。因此 `currentIdx == targetIdx`，steps 永远为 0。

**根因 2: `focusSpace` 在 steps=0 时立即返回 true 而不检查全局焦点**

`Sources/SpaceController.swift:400-409` — `if steps == 0 { return true }` 直接返回成功，即使 `currentSpace=Optional(1)` (主显示器) 与 `targetSpace=2` (副显示器) 不同。光标不会被移动到目标显示器，全局焦点不会切换。

---

### Task 1: 修复 focusSpace 在 steps=0 时仍执行光标移动

**Depends on:** None
**Files:**
- Modify: `Sources/SpaceController.swift:396-409` (focusSpace 方法中 steps==0 的处理)

- [ ] **Step 1: 修改 focusSpace — steps=0 时检查全局焦点并执行光标移动**

文件: `Sources/SpaceController.swift:396-409`（替换 steps==0 的处理区块）

将当前的直接返回逻辑:

```swift
        if steps == 0 {
            log(
                "[SpaceController] CGEvent fallback skipped: steps=0 (already on target space)",
                fields: [
                    "op": op,
                    "targetSpace": String(spaceIndex),
                    "currentSpace": String(describing: preFocusSpace)
                ]
            )
            return true // 已在目标空间
        }
```

替换为检查全局焦点并移动光标的版本:

```swift
        if steps == 0 {
            // steps=0 表示目标 space 在目标显示器上已经是可见的
            // 但全局焦点可能在另一个显示器上，仍需移动光标以切换活跃显示器
            let currentGlobalSpace = queryFocusedSpace()?.index
            if currentGlobalSpace == spaceIndex {
                log(
                    "[SpaceController] CGEvent fallback skipped: global space matches target",
                    fields: [
                        "op": op,
                        "targetSpace": String(spaceIndex),
                        "currentGlobalSpace": String(describing: currentGlobalSpace)
                    ]
                )
                return true // 全局焦点已在目标 space
            }

            // 全局焦点不在目标 space — 移动光标到目标显示器以切换活跃显示器
            log(
                "[SpaceController] steps=0 but global space differs, moving cursor to target display",
                fields: [
                    "op": op,
                    "targetSpace": String(spaceIndex),
                    "currentGlobalSpace": String(describing: currentGlobalSpace),
                    "hasDisplayCenter": String(displayCenterCG(spaceIndex: spaceIndex) != nil)
                ]
            )

            let savedCursor = NSEvent.mouseLocation
            let mainScreenHeight = NSScreen.screens[0].frame.height
            let savedCursorCG = CGPoint(x: savedCursor.x, y: mainScreenHeight - savedCursor.y)

            if let center = displayCenterCG(spaceIndex: spaceIndex) {
                if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                            mouseCursorPosition: center, mouseButton: .left) {
                    moveEvent.post(tap: .cghidEventTap)
                }
                usleep(50_000)
            }

            // 恢复鼠标位置
            if let restoreEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                           mouseCursorPosition: savedCursorCG, mouseButton: .left) {
                restoreEvent.post(tap: .cghidEventTap)
            }

            usleep(150_000) // 等待显示器切换

            let postSwitchSpace = queryFocusedSpace()?.index
            log(
                "[SpaceController] cursor move completed",
                fields: [
                    "op": op,
                    "targetSpace": String(spaceIndex),
                    "preSwitchGlobalSpace": String(describing: currentGlobalSpace),
                    "postSwitchGlobalSpace": String(describing: postSwitchSpace),
                    "reachedTarget": String(postSwitchSpace == spaceIndex)
                ]
            )
            return true
        }
```

- [ ] **Step 2: 验证编译**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**

Run: `git add Sources/SpaceController.swift && git commit -m "fix(space): focusSpace CGEvent fallback moves cursor when cross-display steps=0"`

---

### Task 2: Build, Deploy, and Verify

**Depends on:** Task 1
**Files:**
- Modify: `Sources/AppVersion.swift` (version bump)

- [ ] **Step 1: Bump version to 0.0.16**

文件: `Sources/AppVersion.swift`

将版本号从 `"0.0.15"` 改为 `"0.0.16"`。

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

- [ ] **Step 5: Verify CGEvent fallback in logs**

Run: `grep -E "steps=0 but global space differs|cursor move completed|CGEvent fallback skipped.*global space matches" /tmp/vibefocus.log | tail -10`
Expected:
  - When restore triggers, logs show "steps=0 but global space differs, moving cursor to target display"
  - Or "global space matches target" when already on correct space
  - No more "CGEvent fallback skipped: steps=0 (already on target space)" with mismatched currentSpace

- [ ] **Step 6: Commit version bump**

Run: `git add Sources/AppVersion.swift && git commit -m "release: v0.0.16"`
