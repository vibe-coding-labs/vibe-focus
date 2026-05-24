# Refactor: Extract restore() Sub-methods

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 将 ToggleEngine+Restore.swift 中 379 行的 `restore()` 方法拆分为 3 个专注的子方法，提升可读性和可维护性。

**Architecture:** 纯提取 — restore() 变为协调器，子方法各自处理一个关注点。数据流不变：resolve → validate → switch → apply → verify → fix → cleanup。

**Safety Net:** `swift build` 编译验证
**Scope:** Small
**Risk:** Low

**Before/After:**
- Before: restore() 379 行单方法
- After: restore() ~160 行协调器 + performCrossDisplayRestore() ~140 行 + fixAccidentalDisplaySwitches() ~35 行

**Risks:**
- 提取时参数传递可能遗漏 → 缓解：保持与原代码完全相同的参数和调用顺序
- `inout Set<Int>` 传递需要正确处理 → 缓解：performCrossDisplayRestore 仍使用 inout

**Autonomy Level:** Full

---

### Task 1: Extract performCrossDisplayRestore — 跨显示器移动逻辑

**Depends on:** None
**Files:**
- Modify: `Sources/Toggle/ToggleEngine+Restore.swift`（提取 restore() 中的跨显示器路径）

- [ ] **Step 1: 在 restore() 之后添加 performCrossDisplayRestore 方法**

文件: `Sources/Toggle/ToggleEngine+Restore.swift`（在 `performSpaceSwitch` 方法之前添加）

从 restore() 中提取跨显示器 restore 全部逻辑（space switch → AX apply → post-move verification），封装为独立方法：

```swift
    // MARK: - Cross-Display Restore

    /// 跨显示器 restore：切目标 display 到目标 space → AX apply → 验证 post-move 位置
    private func performCrossDisplayRestore(
        record: ToggleRecord,
        windowAX: AXUIElement,
        effectiveWindowID: UInt32,
        triggerSource: String,
        traceID: String,
        intentionallySwitchedDisplays: inout Set<Int>
    ) -> Bool {
        let wm = WindowManager.shared
        let spaceController = SpaceController.shared

        let targetDisplay = record.sourceYabaiDisp
        let targetSpace = record.sourceSpace
        let displayCurrentSpace = spaceController.displayVisibleSpace(displayIndex: targetDisplay)

        log("[ToggleEngine] restore: pre-apply space switch", fields: [
            "traceID": traceID,
            "windowID": String(effectiveWindowID),
            "targetDisplay": String(describing: targetDisplay),
            "targetSpace": String(targetSpace),
            "displayCurrentSpace": String(describing: displayCurrentSpace)
        ])

        if let current = displayCurrentSpace, current != targetSpace {
            let switched = performSpaceSwitch(
                targetDisplay: targetDisplay,
                targetSpace: targetSpace,
                traceID: traceID,
                intentionallySwitchedDisplays: &intentionallySwitchedDisplays
            )

            if switched {
                usleep(150_000)
            } else {
                let visibleSpace = spaceController.displayVisibleSpace(displayIndex: targetDisplay)
                log("[ToggleEngine] restore: target space switch failed, falling back to visible space", level: .warn, fields: [
                    "traceID": traceID,
                    "targetSpace": String(targetSpace),
                    "visibleSpace": String(describing: visibleSpace),
                    "targetDisplay": String(targetDisplay)
                ])
                if let vis = visibleSpace, vis != current {
                    _ = performSpaceSwitch(
                        targetDisplay: targetDisplay,
                        targetSpace: vis,
                        traceID: traceID,
                        intentionallySwitchedDisplays: &intentionallySwitchedDisplays
                    )
                    usleep(100_000)
                }
            }
            log("[ToggleEngine] restore: display switched to target space", fields: [
                "traceID": traceID,
                "targetSpace": String(targetSpace),
                "intentionallySwitchedDisplays": intentionallySwitchedDisplays.sorted().map { "d\($0)" }.joined(separator: ",")
            ])
        }

        // AX apply
        var restored = wm.apply(frame: record.origFrame, to: windowAX, operationID: traceID, stage: "restore_orig")

        if restored {
            if let postFrame = wm.frame(of: windowAX) {
                let onExpectedScreen: Bool
                if record.sourceYabaiDisp == 1 {
                    onExpectedScreen = CoordinateKit.isOnMainScreen(postFrame)
                } else {
                    onExpectedScreen = !CoordinateKit.isOnMainScreen(postFrame)
                }
                if !onExpectedScreen {
                    log("[ToggleEngine] restore: AX apply succeeded but window on WRONG screen, marking as failed", level: .warn, fields: [
                        "traceID": traceID,
                        "windowID": String(effectiveWindowID),
                        "postFrame": "\(postFrame)",
                        "expectedDisplay": String(record.sourceYabaiDisp)
                    ])
                    restored = false
                } else {
                    log("[ToggleEngine] restore: AX apply moved window to correct screen", fields: [
                        "traceID": traceID,
                        "windowID": String(effectiveWindowID),
                        "origFrame": "\(record.origFrame)"
                    ])
                }
            }
        }

        if !restored {
            log("ToggleEngine.restore: AX apply failed, no fallback available", level: .error, fields: [
                "traceID": traceID,
                "windowID": String(effectiveWindowID)
            ])
            return false
        }

        // Post-move verification
        let postMoveAX = wm.findWindowByPID(record.pid, windowID: effectiveWindowID) ?? windowAX
        let postMoveWindowID = wm.windowHandle(for: postMoveAX) ?? effectiveWindowID

        if postMoveWindowID != effectiveWindowID {
            log("[ToggleEngine] restore: CGWindowNumber changed after cross-display move", level: .info, fields: [
                "traceID": traceID,
                "beforeCrossMoveID": String(effectiveWindowID),
                "afterCrossMoveID": String(postMoveWindowID)
            ])
        }

        spaceController.setWindowFloat(postMoveWindowID, operationID: traceID)

        if let actualSpace = spaceController.windowSpaceIndex(windowID: postMoveWindowID),
           actualSpace != record.sourceSpace {
            log("[ToggleEngine] restore: window on wrong space after AX apply, trying moveWindow fallback", level: .warn, fields: [
                "traceID": traceID,
                "effectiveWindowID": String(postMoveWindowID),
                "actualSpace": String(actualSpace),
                "targetSpace": String(record.sourceSpace)
            ])
            let moved = spaceController.moveWindow(
                postMoveWindowID,
                toSpaceIndex: record.sourceSpace,
                focus: triggerSource == "carbon_hotkey",
                operationID: traceID
            )

            if !moved {
                log("[ToggleEngine] restore: moveWindow failed, switching display to window's actual space for visibility", level: .warn, fields: [
                    "traceID": traceID,
                    "effectiveWindowID": String(postMoveWindowID),
                    "actualSpace": String(actualSpace),
                    "targetSpace": String(record.sourceSpace)
                ])
                let switched = spaceController.switchDisplayToSpace(
                    targetSpace: actualSpace,
                    operationID: traceID
                )
                log("[ToggleEngine] restore: display switch to actual space result", fields: [
                    "traceID": traceID,
                    "switched": String(switched),
                    "actualSpace": String(actualSpace)
                ])
            }
        }

        return true
    }
```

- [ ] **Step 2: 替换 restore() 中的跨显示器代码为 performCrossDisplayRestore 调用**

文件: `Sources/Toggle/ToggleEngine+Restore.swift`

在 restore() 中，将 `if needCrossDisplayMove { ... } else if restored { ... }` 整个块（从 `// 4. 跨显示器 restore` 注释开始，到 `switchToOriginalSpace` 调用结束）替换为：

```swift
        // 4. 执行 restore
        if needCrossDisplayMove {
            restored = performCrossDisplayRestore(
                record: record,
                windowAX: windowAX,
                effectiveWindowID: effectiveWindowID,
                triggerSource: triggerSource,
                traceID: trace,
                intentionallySwitchedDisplays: &intentionallySwitchedDisplays
            )
        } else {
            // 主屏内 restore：AX apply + 切换 space
            restored = wm.apply(frame: record.origFrame, to: windowAX, operationID: trace, stage: "restore_orig")

            if restored {
                if let postFrame = wm.frame(of: windowAX) {
                    let onMainScreen = CoordinateKit.isOnMainScreen(postFrame)
                    if onMainScreen {
                        log("[ToggleEngine] restore: AX apply moved window to correct screen", fields: [
                            "traceID": trace,
                            "windowID": String(windowID),
                            "origFrame": "\(record.origFrame)"
                        ])
                    }
                }

                switchToOriginalSpace(
                    record: record,
                    windowAX: windowAX,
                    effectiveWindowID: effectiveWindowID,
                    triggerSource: triggerSource,
                    traceID: trace,
                    intentionallySwitchedDisplays: &intentionallySwitchedDisplays
                )
            } else {
                log("ToggleEngine.restore: AX apply failed, no fallback available", level: .error, fields: [
                    "traceID": trace,
                    "windowID": String(windowID)
                ])
            }
        }
```

注意：需要删除原来的 `restored = wm.apply(...)` 行和后面的 `if restored { ... } / if !restored { ... } / if needCrossDisplayMove, restored { ... } / else if restored { ... }` 等所有分支。新代码中的 `restored` 变量需要在声明时去掉初始值，改为条件赋值。

- [ ] **Step 3: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/Toggle/ToggleEngine+Restore.swift && git commit -m "$(cat <<'EOF'
refactor(toggle): extract performCrossDisplayRestore from restore()

restore() was 379 lines — extract cross-display move logic (space switch +
AX apply + post-move verification) into dedicated performCrossDisplayRestore()
method (~140 lines).

restore() is now a ~240 line coordinator. No behavior change.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

### Task 2: Extract fixAccidentalDisplaySwitches — 意外切换检测逻辑

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Toggle/ToggleEngine+Restore.swift`（提取 restore() 中的意外切换检测）

- [ ] **Step 1: 在 restore() 之后添加 fixAccidentalDisplaySwitches 方法**

文件: `Sources/Toggle/ToggleEngine+Restore.swift`（在 `performCrossDisplayRestore` 方法之后添加）

```swift
    // MARK: - Accidental Switch Detection

    /// 检测并修复 CGEvent 意外切换非目标 display 的问题
    private func fixAccidentalDisplaySwitches(
        preRestoreDisplaySpaces: [Int: Int],
        intentionallySwitchedDisplays: Set<Int>,
        traceID: String
    ) {
        let spaceController = SpaceController.shared
        var accidentalSwitches: [String] = []

        for (disp, preVis) in preRestoreDisplaySpaces {
            if intentionallySwitchedDisplays.contains(disp) { continue }
            let currentVis = spaceController.displayVisibleSpace(displayIndex: disp)
            if let cur = currentVis, cur != preVis {
                accidentalSwitches.append("d\(disp):s\(preVis)->s\(cur)")
                log("[ToggleEngine] restore: display \(disp) was accidentally switched from space \(preVis) to \(cur), fixing", level: .warn, fields: [
                    "traceID": traceID,
                    "display": String(disp),
                    "preRestoreSpace": String(preVis),
                    "currentSpace": String(cur),
                    "intentionallySwitchedDisplays": intentionallySwitchedDisplays.sorted().map { "d\($0)" }.joined(separator: ",")
                ])
                _ = spaceController.switchDisplayToSpace(
                    targetSpace: preVis,
                    operationID: traceID
                )
            }
        }

        if accidentalSwitches.isEmpty {
            log("[ToggleEngine] restore: no accidental display switches detected", level: .debug, fields: [
                "traceID": traceID,
                "intentionallySwitchedDisplays": intentionallySwitchedDisplays.sorted().map { "d\($0)" }.joined(separator: ",")
            ])
        } else {
            log("[ToggleEngine] restore: fixed accidental switches", fields: [
                "traceID": traceID,
                "accidentalSwitches": accidentalSwitches.joined(separator: ",")
            ])
        }
    }
```

- [ ] **Step 2: 替换 restore() 中的意外切换检测为 fixAccidentalDisplaySwitches 调用**

文件: `Sources/Toggle/ToggleEngine+Restore.swift`

在 restore() 中，将 `// 6. 检测并修复 CGEvent 意外切换其他 display 的问题` 注释及其后面的整个 if 块替换为：

```swift
        // 6. 检测并修复 CGEvent 意外切换其他 display
        if restored, !preRestoreDisplaySpaces.isEmpty {
            fixAccidentalDisplaySwitches(
                preRestoreDisplaySpaces: preRestoreDisplaySpaces,
                intentionallySwitchedDisplays: intentionallySwitchedDisplays,
                traceID: trace
            )
        }
```

- [ ] **Step 3: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/Toggle/ToggleEngine+Restore.swift && git commit -m "$(cat <<'EOF'
refactor(toggle): extract fixAccidentalDisplaySwitches from restore()

Move accidental display switch detection (~35 lines) into dedicated
fixAccidentalDisplaySwitches() method. restore() is now a ~200 line
coordinator calling focused sub-methods.

No behavior change.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
