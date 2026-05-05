# Fix Toggle Restore Wrong Space — focusSpace 切错 Display

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 toggle restore 时窗口恢复到错误 Space 的 bug。根因是 `focusSpace` (Ctrl+Left/Right) 只影响当前焦点所在的 Display，而不是窗口所在的 Display。当窗口在 Display 2 Space 2，但用户焦点在 Display 1 时，Ctrl+Right 切的是 Display 1 的 space，导致窗口停留在错误 Space。

**Architecture:** restore 路径：AX frame apply → 窗口落在副屏当前活跃 Space → 检测到 Space 不匹配 → **需要先 focusWindow 把焦点移到目标窗口的 Display** → 然后 focusSpace(steps) 才能切正确的 Display → reapply frame。

**Tech Stack:** Swift 5.9, macOS 13+, yabai, AppleScript System Events, AX API

**Risks:**
- focusWindow 后需要等待 macOS 切换焦点 Display，时间不确定 → 缓解：增加 focusWindow 后的等待时间到 300ms
- focusSpace AppleScript 执行有延迟 → 缓解：已有 400ms 等待

---

### Task 1: 修复 restore space 切换逻辑 — focusSpace 前先 focus 到目标 Display

**Depends on:** None
**Files:**
- Modify: `Sources/WindowManager.swift:662-708`（restore 方法中 space 修正区块）

- [ ] **Step 1: 修改 space 修正逻辑 — focusSpace 前先 focusWindow 确保焦点在目标 Display**

文件: `Sources/WindowManager.swift:662-708`（替换 `if let currentSpace = currentWindowSpace, currentSpace != targetSpace` 内的 carbon_hotkey 分支）

当前代码在 carbon_hotkey 分支中的执行顺序是：focusWindow → focusSpace → reapply。问题在于 focusWindow 已经在 671 行调用了，但 focusWindow 之后只等了 150ms，然后 focusSpace 就开始执行。日志显示 focusWindow 返回了 `focusChanged=false`（因为焦点已经在 Terminal 上），焦点 Display 没变。

真正的问题是：**focusWindow(windowID) 不会切换焦点 Display**。需要用 `yabai -m window --focus <id>` 让 macOS 把焦点切换到窗口所在的 Display，然后才能用 Ctrl+Left/Right 切换该 Display 的 space。

实际上日志显示 focusWindow 已经用了 yabai：`yabai command result args="-m window --focus 64" exitCode=0`，但 `focusChanged=false`。这是因为窗口虽然在 Display 2 上，但 yabai focus 没有把用户视角移到 Display 2（macOS 可能认为窗口不在可见的 space 上所以不切换）。

**解决方案：** 不依赖 focusSpace(Ctrl+Left/Right) 来切 Display 的 space。改用 yabai `--space` 命令直接把窗口移到目标 space，然后再 focusWindow 切换用户视角。

```swift
            if let currentSpace = currentWindowSpace, currentSpace != targetSpace {
                log(
                    "[WindowManager] restore: window on wrong Space \(currentSpace), need Space \(targetSpace)",
                    level: .warn,
                    fields: ["op": op, "windowID": String(windowID)]
                )

                if triggerSource == "carbon_hotkey" {
                    // toggle: 先用 yabai 把窗口移到目标 space，再 focusWindow 切用户视角
                    // focusSpace(Ctrl+Left/Right) 只影响焦点所在的 Display，不可靠
                    let movedByYabai = spaceController.moveWindowToSpace(
                        windowID: windowID,
                        targetSpaceIndex: targetSpace,
                        operationID: op
                    )
                    log(
                        "[WindowManager] restore: moveWindowToSpace result",
                        fields: [
                            "op": op,
                            "windowID": String(windowID),
                            "targetSpace": String(targetSpace),
                            "movedByYabai": String(movedByYabai)
                        ]
                    )

                    if movedByYabai {
                        usleep(300_000)

                        // reapply frame（space 切换后可能需要重新设置位置）
                        if let targetFrame = lastWindowFrame {
                            _ = apply(frame: targetFrame, to: window, operationID: op, stage: "restore_reapply_frame")
                            usleep(100_000)
                        }
                    } else {
                        // yabai moveWindowToSpace 也失败了 — fallback: focusWindow + focusSpace
                        log(
                            "[WindowManager] restore: moveWindowToSpace failed, trying focusSpace fallback",
                            level: .warn,
                            fields: ["op": op, "windowID": String(windowID)]
                        )
                        _ = spaceController.focusWindow(windowID, operationID: op)
                        usleep(300_000)

                        let steps = targetSpace - currentSpace
                        if steps != 0 {
                            _ = NativeSpaceBridge.focusSpace(steps: steps, operationID: op)
                            usleep(400_000)
                        }

                        if let targetFrame = lastWindowFrame {
                            _ = apply(frame: targetFrame, to: window, operationID: op, stage: "restore_reapply_frame_fallback")
                            usleep(100_000)
                        }
                    }
                } else {
                    // hook-restore: 只设 AX frame，不干预焦点和 Space
                    // macOS 会自动把窗口放到 frame 坐标对应的 Space
                    if let targetFrame = lastWindowFrame {
                        _ = apply(frame: targetFrame, to: window, operationID: op, stage: "restore_apply_frame_no_space_switch")
                        usleep(100_000)
                    }
                }

                let recheckSpace = spaceController.windowSpaceIndex(windowID: windowID)
                log(
                    "[WindowManager] restore: after Space handling",
                    fields: [
                        "op": op,
                        "windowID": String(windowID),
                        "targetSpace": String(targetSpace),
                        "recheckSpace": String(describing: recheckSpace),
                        "triggerSource": triggerSource
                    ]
                )
            }
```

- [ ] **Step 2: 验证 moveWindowToSpace 方法签名存在**

在执行前需要确认 `SpaceController.moveWindowToSpace` 的方法签名。用 grep 搜索：

Run: `grep -n "func moveWindowToSpace\|func moveWindow.*space" /Users/cc11001100/github/vibe-coding-labs/vibe-focus/Sources/SpaceController.swift`
Expected:
  - 找到 moveWindowToSpace 或类似方法

- [ ] **Step 3: 验证编译**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Output contains: "Build complete!"

---

### Task 2: 增强关键路径日志 — 打印更多决策信息

**Depends on:** Task 1
**Files:**
- Modify: `Sources/WindowManager.swift:462-470,644-723`（restore 方法多个关键点）

- [ ] **Step 1: 增强 restore 方法的日志 — 在每个关键决策点打印详细信息**

在以下位置添加/增强日志（不改变逻辑，只增加日志输出）：

1. **Line ~468**: 在 spacePrepared 处增加当前 space 上下文日志
2. **Line ~647**: 在 targetSpace 赋值处增加来源信息
3. **Line ~713-721**: 在 following window 逻辑处增加更多信息

在 `let spacePrepared = true` 之前（约 line 467-468）添加日志：

文件: `Sources/WindowManager.swift:467`（在 `let spacePrepared = true` 之前插入）

```swift
        log(
            "[WindowManager] restore: preparing space correction",
            level: .info,
            fields: [
                "op": op,
                "windowID": String(describing: windowHandle(for: window)),
                "sourceSpaceIndex": String(describing: lastSourceSpaceIndex),
                "sourceYabaiDisplayIndex": String(describing: lastSourceYabaiDisplayIndex),
                "triggerSource": triggerSource
            ]
        )
```

在 `let targetSpace = lastSourceSpaceIndex` 之后（约 line 647）添加日志：

文件: `Sources/WindowManager.swift:648`（在 `if let windowID = windowHandle` 之前插入）

```swift
        log(
            "[WindowManager] restore: target space determined",
            level: .info,
            fields: [
                "op": op,
                "targetSpace": String(describing: targetSpace),
                "lastSourceSpaceIndex": String(describing: lastSourceSpaceIndex)
            ]
        )
```

- [ ] **Step 2: 验证编译**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Output contains: "Build complete!"

---

### Task 3: 构建部署 + 提交

**Depends on:** Task 1, Task 2
**Files:**
- 无代码修改

- [ ] **Step 1: 构建并部署**
Run: `bash scripts/dev-build.sh 2>&1 | tail -10`
Expected:
  - Output contains: "构建成功！"

- [ ] **Step 2: 提交**
Run: `git add Sources/WindowManager.swift Sources/ToggleEngine.swift && git commit -m "fix(restore): use moveWindowToSpace instead of focusSpace for correct display targeting"`

