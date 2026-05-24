# Toggle Engine Refactor — Dead Code + Logic Cleanup

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 清理 Toggle 目录审核中发现的死代码、冗余逻辑和潜在 bug，不改变核心行为。

**Architecture:** 纯重构 — 删除死代码、提取重复逻辑为 helper、修复坐标系统不一致。数据流不变：save → SQLite → load → restore。

**Tech Stack:** Swift 5.9, macOS 14+, SQLite (WindowStateStore), yabai (SpaceController)

**Scope:** Medium — 4 tasks, 2 files modified
**Risk:** Medium — Task 3 触及 restore() 核心路径

**Risks:**
- Task 3 提取 space switch helper 时可能引入微妙的行为差异 → 缓解：提取后保持完全相同的调用顺序和参数
- Task 4 坐标修复可能改变 origFrame 验证结果 → 缓解：修复后 AppKit 坐标比较更准确，不会误拒有效 restore

**Autonomy Level:** Full

---

### Task 1: Delete dead code — clearByPID + duplicate notification registration

**Depends on:** None
**Files:**
- Modify: `Sources/Toggle/ToggleEngine.swift:107-112`（删除 clearByPID 方法）
- Modify: `Sources/Toggle/ShutdownSnapshotManager.swift:65-69`（删除错误的 willTerminateNotification 注册）

- [ ] **Step 1: Delete ToggleEngine.clearByPID — 无外部调用者的死代码**

文件: `Sources/Toggle/ToggleEngine.swift:106-112`

删除整个 `clearByPID` 方法：

```swift
// DELETE lines 106-112 entirely:
    /// 按 PID 清除 toggle state（PID fallback 场景）
    func clearByPID(pid: Int32) {
        if let record = loadByPID(pid: pid) {
            store.clearToggleRecord(windowID: record.windowID)
            log("ToggleEngine.clearByPID", fields: ["pid": String(pid), "windowID": String(record.windowID)])
        }
    }
```

- [ ] **Step 2: Fix ShutdownSnapshotManager duplicate willTerminateNotification — 删除 NSWorkspace 注册（永远不会触发）**

文件: `Sources/Toggle/ShutdownSnapshotManager.swift:64-69`

替换 `registerShutdownNotifications()` 中的通知注册，删除无效的 NSWorkspace 注册：

```swift
// 替换 Sources/Toggle/ShutdownSnapshotManager.swift:55-79 的 registerShutdownNotifications 方法
    private func registerShutdownNotifications() {
        let nc = NSWorkspace.shared.notificationCenter

        nc.addObserver(
            self,
            selector: #selector(handlePowerOff(_:)),
            name: NSWorkspace.willPowerOffNotification,
            object: nil
        )

        // NSApplication.willTerminateNotification 必须通过 NotificationCenter.default 注册
        // NSWorkspace.shared.notificationCenter 不会分发 NSApplication 通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePowerOff(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil
        )

        log("[ShutdownSnapshot] registered shutdown notifications")
    }
```

- [ ] **Step 3: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/Toggle/ToggleEngine.swift Sources/Toggle/ShutdownSnapshotManager.swift && git commit -m "$(cat <<'EOF'
refactor(toggle): delete dead clearByPID and fix duplicate notification registration

- Remove ToggleEngine.clearByPID — zero external callers
- Remove bogus NSWorkspace notification center registration for
  NSApplication.willTerminateNotification (never fires there)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

### Task 2: Replace hardcoded `1...3` display iteration with dynamic count

**Depends on:** None
**Files:**
- Modify: `Sources/Toggle/ToggleEngine.swift`（5 处 `for d in 1...3` / `for disp in 1...3`）

- [ ] **Step 1: Add displayCount helper to ToggleEngine — 动态获取 yabai display 数量**

文件: `Sources/Toggle/ToggleEngine.swift`（在 `private var store` 之后添加）

在 ToggleEngine 类中添加一个计算属性：

```swift
// 在 Sources/Toggle/ToggleEngine.swift:18 的 private var store 之后添加
    private var displayCount: Int {
        SpaceController.shared.queryDisplays()?.count ?? NSScreen.screens.count
    }
```

- [ ] **Step 2: Replace all `1...3` with `1...displayCount`**

文件: `Sources/Toggle/ToggleEngine.swift`（5 处替换）

执行以下替换（使用 replace_all 语义）：
- `for disp in 1...3` → `for disp in 1...displayCount`
- `for d in 1...3` → `for d in 1...displayCount`

共 5 处（line 238, 279, 292, 593, 612）。

注意：`1...displayCount` 在 displayCount=0 时会 trap。但这是不可能的情况 — 至少有 1 个显示器。如果担心安全，可以用 `1...max(displayCount, 1)`。

- [ ] **Step 3: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/Toggle/ToggleEngine.swift && git commit -m "$(cat <<'EOF'
refactor(toggle): replace hardcoded display count 1...3 with dynamic displayCount

Uses yabai display query count (fallback to NSScreen.screens.count)
instead of assuming exactly 3 displays.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

### Task 3: Extract duplicate space switch logic into performSpaceSwitch helper

**Depends on:** Task 2
**Files:**
- Modify: `Sources/Toggle/ToggleEngine.swift:237-348`（restore 中的跨显示器切换）
- Modify: `Sources/Toggle/ToggleEngine.swift:590-641`（switchToOriginalSpace 中的重复逻辑）

这是最大的重构。`restore()` 和 `switchToOriginalSpace()` 有 ~70 行几乎相同的空间切换代码。提取为一个 helper。

- [ ] **Step 1: Add performSpaceSwitch helper method — 封装重复的空间切换+轮询+display 追踪逻辑**

文件: `Sources/Toggle/ToggleEngine.swift`（在 `switchToOriginalSpace` 方法之前添加）

在 ToggleEngine 的 private 区域添加 helper：

```swift
    // MARK: - Space Switch Helper

    /// 封装空间切换 + 轮询等待 + display 追踪的通用逻辑
    /// 被 restore() 和 switchToOriginalSpace() 共用
    private func performSpaceSwitch(
        targetDisplay: Int,
        targetSpace: Int,
        traceID: String,
        intentionallySwitchedDisplays: inout Set<Int>
    ) -> Bool {
        let spaceController = SpaceController.shared

        // 1. 记录切换前的 display states
        var preSwitchSpaces: [Int: Int] = [:]
        for d in 1...displayCount {
            if let v = spaceController.displayVisibleSpace(displayIndex: d) {
                preSwitchSpaces[d] = v
            }
        }

        // 2. 执行切换
        let switched = spaceController.switchDisplayToSpace(
            targetSpace: targetSpace,
            operationID: traceID
        )

        guard switched else { return false }

        // 3. 追踪被 switchDisplayToSpace 影响的所有 display
        for d in 1...displayCount {
            let postVis = spaceController.displayVisibleSpace(displayIndex: d)
            if let pre = preSwitchSpaces[d], let post = postVis, pre != post {
                intentionallySwitchedDisplays.insert(d)
                log("[ToggleEngine] display \(d) intentionally switched \(pre)->\(post)", level: .debug, fields: [
                    "traceID": traceID,
                    "display": String(d),
                    "from": String(pre),
                    "to": String(post)
                ])
            }
        }

        // 4. 轮询等待目标 display 到达目标 space
        let started = Date()
        var pollCount = 0
        while Date().timeIntervalSince(started) < 0.4 {
            if spaceController.displayVisibleSpace(displayIndex: targetDisplay) == targetSpace { break }
            usleep(30_000)
            pollCount += 1
        }
        let finalSpace = spaceController.displayVisibleSpace(displayIndex: targetDisplay)
        log("[ToggleEngine] space poll completed", level: .debug, fields: [
            "traceID": traceID,
            "targetDisplay": String(targetDisplay),
            "targetSpace": String(targetSpace),
            "finalSpace": String(describing: finalSpace),
            "pollCount": String(pollCount),
            "reachedTarget": String(finalSpace == targetSpace)
        ])

        return true
    }
```

- [ ] **Step 2: Refactor restore() cross-display path — 使用 performSpaceSwitch 替换内联代码**

文件: `Sources/Toggle/ToggleEngine.swift:276-347`

替换 restore() 中的跨显示器切换部分。将以下代码：

```swift
// 原 lines 276-347 中的 switchDisplayToSpace + display tracking + polling 代码
// 替换为调用 performSpaceSwitch
            if let current = displayCurrentSpace, current != targetSpace {
                // 记录切换前的 display states，用于检测 switchDisplayToSpace 实际影响了哪些 display
                var preSwitchSpaces: [Int: Int] = [:]
                for d in 1...displayCount {
                    if let v = spaceController.displayVisibleSpace(displayIndex: d) {
                        preSwitchSpaces[d] = v
                    }
                }

                let switched = spaceController.switchDisplayToSpace(
                    targetSpace: targetSpace,
                    operationID: trace
                )

                // 检测哪些 display 的 space 被改变了，全部标记为故意切换
                if switched {
                    for d in 1...displayCount {
                        let postVis = spaceController.displayVisibleSpace(displayIndex: d)
                        if let pre = preSwitchSpaces[d], let post = postVis, pre != post {
                            intentionallySwitchedDisplays.insert(d)
                            // ... log ...
                        }
                    }

                    let td = targetDisplay
                    let started = Date()
                    var pollCount = 0
                    while Date().timeIntervalSince(started) < 0.4 {
                        if spaceController.displayVisibleSpace(displayIndex: td) == targetSpace { break }
                        usleep(30_000)
                        pollCount += 1
                    }
                    // ... poll result logging ...
                    usleep(150_000)
                } else {
                    // fallback logic...
                }
```

替换为：

```swift
            if let current = displayCurrentSpace, current != targetSpace {
                log("[ToggleEngine] restore: pre-apply space switch", fields: [
                    "traceID": trace,
                    "windowID": String(windowID),
                    "targetDisplay": String(describing: targetDisplay),
                    "targetSpace": String(targetSpace),
                    "displayCurrentSpace": String(describing: displayCurrentSpace)
                ])

                let switched = performSpaceSwitch(
                    targetDisplay: targetDisplay,
                    targetSpace: targetSpace,
                    traceID: trace,
                    intentionallySwitchedDisplays: &intentionallySwitchedDisplays
                )

                if switched {
                    usleep(150_000)
                } else {
                    // space switch 失败 — fallback 到目标 display 的 visible space
                    let visibleSpace = spaceController.displayVisibleSpace(displayIndex: targetDisplay)
                    log("[ToggleEngine] restore: target space switch failed, falling back to visible space", level: .warn, fields: [
                        "traceID": trace,
                        "targetSpace": String(targetSpace),
                        "visibleSpace": String(describing: visibleSpace),
                        "targetDisplay": String(targetDisplay)
                    ])
                    if let vis = visibleSpace, vis != current {
                        _ = performSpaceSwitch(
                            targetDisplay: targetDisplay,
                            targetSpace: vis,
                            traceID: trace,
                            intentionallySwitchedDisplays: &intentionallySwitchedDisplays
                        )
                        usleep(100_000)
                    }
                }
                log("[ToggleEngine] restore: display switched to target space", fields: [
                    "traceID": trace,
                    "switched": String(switched),
                    "targetSpace": String(targetSpace),
                    "intentionallySwitchedDisplays": intentionallySwitchedDisplays.sorted().map { "d\($0)" }.joined(separator: ",")
                ])
            }
```

- [ ] **Step 3: Refactor switchToOriginalSpace() — 使用 performSpaceSwitch 替换内联代码**

文件: `Sources/Toggle/ToggleEngine.swift`（switchToOriginalSpace 方法中的 space switch 部分）

将 switchToOriginalSpace 中的重复空间切换代码替换为 performSpaceSwitch 调用。原代码（~50 行的 pre-switch capture + switchDisplayToSpace + display tracking + polling）替换为：

```swift
        // 目标 display 不在正确 space — 需要先切换 display 的 space 再移动窗口
        if let current = displayCurrentSpace, current != targetSpace {
            let switchStart = Date()
            let switched = performSpaceSwitch(
                targetDisplay: targetDisplay,
                targetSpace: targetSpace,
                traceID: traceID,
                intentionallySwitchedDisplays: &intentionallySwitchedDisplays
            )
            log("ToggleEngine.switchToOriginalSpace: switchDisplayToSpace result", fields: [
                "traceID": traceID,
                "switched": String(switched),
                "targetSpace": String(targetSpace),
                "switchDisplayMs": String(elapsedMilliseconds(since: switchStart))
            ])
        }
```

- [ ] **Step 4: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 5: 质量门禁 — 确认行为不变**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | grep -i error`
Expected:
  - Exit code: 1 (grep found nothing)
  - 无编译错误

手工检查：
- [ ] performSpaceSwitch 的参数传递与原内联代码一致
- [ ] `inout Set<Int>` 正确传递给调用者
- [ ] fallback 逻辑保持不变（switched=false 时尝试 visible space）
- [ ] usleep 时机不变（switched=true 后 150ms，fallback 后 100ms）

- [ ] **Step 6: 提交**
Run: `git add Sources/Toggle/ToggleEngine.swift && git commit -m "$(cat <<'EOF'
refactor(toggle): extract performSpaceSwitch helper to eliminate 70 lines of duplication

restore() and switchToOriginalSpace() had identical space switch + display
tracking + polling code. Extracted into performSpaceSwitch() to reduce
maintenance burden and risk of divergent fixes.

Behavior unchanged — same call order, same parameters, same usleep timings.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

### Task 4: Fix origFrame coordinate system mismatch in restore() validation

**Depends on:** Task 3
**Files:**
- Modify: `Sources/Toggle/ToggleEngine.swift:157-183`

**问题：** `restore()` 的 origFrame 验证将 NSScreen.frame 从 AppKit 坐标转换为 Quartz 坐标，然后检查 origFrame（AppKit 坐标）是否在 Quartz 范围内。对于垂直排列的显示器，这会导致误判 — 有效的 restore 被拒绝。

**根因：** `origFrame` 来自 `wm.frame(of: windowAX)`，这是 AppKit 坐标。`save()` 中的验证正确地使用了 AppKit 坐标，但 `restore()` 错误地转换了屏幕坐标。

- [ ] **Step 1: Fix restore() origFrame validation — 使用 AppKit 坐标统一比较**

文件: `Sources/Toggle/ToggleEngine.swift:157-183`

替换坐标验证代码：

```swift
        // 校验 origFrame 坐标是否在已知屏幕范围内
        // origFrame 是 AppKit 坐标（来自 AX API），直接用 NSScreen.frame（也是 AppKit）比较
        let origCenter = CGPoint(x: record.origFrame.midX, y: record.origFrame.midY)
        let onAnyScreen = NSScreen.screens.contains { screen in
            screen.frame.insetBy(dx: -200, dy: -200).contains(origCenter)
        }
        if !onAnyScreen {
            log(
                "[ToggleEngine] restore: origFrame not on any screen, skipping restore (data preserved)",
                level: .warn,
                fields: [
                    "traceID": trace,
                    "windowID": String(windowID),
                    "origFrame": "\(record.origFrame)",
                    "screens": NSScreen.screens.map { "\($0.frame)" }.joined(separator: ", ")
                ]
            )
            return false
        }
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/Toggle/ToggleEngine.swift && git commit -m "$(cat <<'EOF'
fix(toggle): restore origFrame validation used wrong coordinate system

origFrame from AX API is in AppKit coordinates, but restore() was
converting NSScreen.frame to Quartz coordinates before comparison.
This caused false rejects on vertically stacked monitors.

Now both origFrame and NSScreen.frame use AppKit coordinates consistently,
matching the save() path.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`
