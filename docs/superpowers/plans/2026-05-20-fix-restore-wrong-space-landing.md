# Bug Fix: Restore 把窗口放到错误 space (2-1 而非 2-2)

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Symptom:** 窗口从主屏 restore 回副屏时，本来在 2-2 的窗口被错误地放到 2-1。用户看到 overlay 显示 "2-1" 而不是 "2-2"，且窗口不可见。

**Root Cause:** ToggleEngine.restore 的 step 6 "accidental switch" 检测逻辑把**restore 自身引起的目标 display space 切换**误判为"意外切换"，然后反向切换 display 回原 space，破坏了 restore 结果。

具体链条：
1. restore step 4a: switchDisplayToSpace(2) 把 display 2 从 space 3 切到 space 2 ✅
2. restore step 4b: AX apply 把窗口移到 display 2 space 2 ✅
3. restore step 6: 检测到 display 2 从 space 3→2，误判为"意外切换"
4. 代码反向执行 switchDisplayToSpace(3)，把 display 2 切回 space 3 ❌
5. 窗口在 display 2 的 space 2 上，但 display 2 可见 space 是 3 → 窗口不可见

代码 line 418 `if disp == intentionallySwitchedDisplay { continue }` 理论上应该跳过目标 display 2，但实际运行时**没有跳过**。原因可能：
- `intentionallySwitchedDisplay` 只排除了 `sourceYabaiDisp`，但 restore 过程中 `switchDisplayToSpace` 的 CGEvent fallback 可能影响了多个 display
- 代码只跟踪了**最终目标 display**，没有跟踪**中间过程**中所有被故意切换的 display

**Impact:** 所有跨 display restore 操作（约占 80% 的 restore 场景）都受影响。日志中 58 次 "max corrections reached" 事件均为此 bug 导致。

**Scope:** Small
**Risk:** Medium
**Risks:**
- 修改 step 6 检测逻辑可能影响真正的意外切换修复 — 缓解：明确跟踪所有故意切换的 display
- RestoreWatchdog 的 "not floating" 检测也需要同步修复 — 缓解：correction 时先 setWindowFloat 再 apply frame

**Architecture:** restore 流程修复：step 6 改用显式跟踪的 `intentionallySwitchedDisplays` 集合替代单一 `sourceYabaiDisp`；RestoreWatchdog 增加 setWindowFloat + moveWindow 组合修复

**Tech Stack:** Swift 5.9, macOS 14, yabai, CGEvent/AX API

**Autonomy Level:** Full

---

### Task 1: 修复 ToggleEngine.restore 的 accidental switch 检测逻辑

**Depends on:** None
**Files:**
- Modify: `Sources/Toggle/ToggleEngine.swift:237-303` (step 3.5 + step 4a + step 6)
- Modify: `Sources/Toggle/ToggleEngine.swift:412-445` (step 6 检测逻辑)

- [ ] **Step 1: 修改 step 3.5 — 跟踪所有故意切换的 display，而不仅是 sourceYabaiDisp**

文件: `Sources/Toggle/ToggleEngine.swift:237-250`

替换 `preRestoreDisplaySpaces` 采集逻辑，增加 `intentionallySwitchedDisplays: Set<Int>` 跟踪所有在 restore 过程中被故意切换的 display：

```swift
// 3.5 记录所有 display 当前可见 space（用于 restore 后检测意外切换）
var preRestoreDisplaySpaces: [Int: Int] = [:]
for disp in 1...3 {
    if let vis = spaceController.displayVisibleSpace(displayIndex: disp) {
        preRestoreDisplaySpaces[disp] = vis
    }
}
var restored = false
let needCrossDisplayMove = record.sourceYabaiDisp != 1

// 跟踪所有在 restore 过程中被故意切换的 display
// 不仅包括 sourceYabaiDisp（目标 display），还包括 step 4a/switchToOriginalSpace 中切换的其他 display
var intentionallySwitchedDisplays: Set<Int> = [record.sourceYabaiDisp]

log("[ToggleEngine] restore: captured pre-restore display spaces", level: .debug, fields: [
    "traceID": trace,
    "preRestoreDisplaySpaces": preRestoreDisplaySpaces.map { "d\($0.key)=s\($0.value)" }.joined(separator: ","),
    "needCrossDisplayMove": String(needCrossDisplayMove),
    "intentionallySwitchedDisplays": intentionallySwitchedDisplays.sorted().map { "d\($0)" }.joined(separator: ",")
])
```

- [ ] **Step 2: 修改 step 4a — 记录 switchDisplayToSpace 影响的 display**

文件: `Sources/Toggle/ToggleEngine.swift:257-303`

在 `switchDisplayToSpace` 调用后，把实际被切换的 display 加入 `intentionallySwitchedDisplays`。同时在 switchToOriginalSpace 中也记录：

在 step 4a 的 `switchDisplayToSpace` 成功后，查询实际切换了哪个 display 并记录：

```swift
if needCrossDisplayMove {
    // 4a. 先切换目标 display 到原始 space
    let targetDisplay = record.sourceYabaiDisp
    let targetSpace = record.sourceSpace
    let displayCurrentSpace = spaceController.displayVisibleSpace(displayIndex: targetDisplay)

    log("[ToggleEngine] restore: pre-apply space switch", fields: [
        "traceID": trace,
        "windowID": String(windowID),
        "targetDisplay": String(describing: targetDisplay),
        "targetSpace": String(targetSpace),
        "displayCurrentSpace": String(describing: displayCurrentSpace)
    ])

    if let current = displayCurrentSpace, current != targetSpace {
        // 记录切换前的 display states，用于检测 switchDisplayToSpace 实际影响了哪些 display
        var preSwitchSpaces: [Int: Int] = [:]
        for d in 1...3 {
            if let v = spaceController.displayVisibleSpace(displayIndex: d) {
                preSwitchSpaces[d] = v
            }
        }

        let switched = spaceController.switchDisplayToSpace(
            targetSpace: targetSpace,
            operationID: trace
        )
        if switched {
            // 检测哪些 display 的 space 被改变了，全部标记为故意切换
            for d in 1...3 {
                let postVis = spaceController.displayVisibleSpace(displayIndex: d)
                if let pre = preSwitchSpaces[d], let post = postVis, pre != post {
                    intentionallySwitchedDisplays.insert(d)
                    log("[ToggleEngine] restore: display \(d) intentionally switched \(pre)->\(post) by switchDisplayToSpace", level: .debug, fields: [
                        "traceID": trace,
                        "display": String(d),
                        "from": String(pre),
                        "to": String(post)
                    ])
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
            let finalSpace = spaceController.displayVisibleSpace(displayIndex: td)
            log("[ToggleEngine] restore: space poll completed", level: .debug, fields: [
                "traceID": trace,
                "targetDisplay": String(td),
                "targetSpace": String(targetSpace),
                "finalSpace": String(describing: finalSpace),
                "pollCount": String(pollCount),
                "reachedTarget": String(finalSpace == targetSpace)
            ])
            usleep(150_000)
        }
        log("[ToggleEngine] restore: display switched to target space", fields: [
            "traceID": trace,
            "switched": String(switched),
            "targetSpace": String(targetSpace),
            "intentionallySwitchedDisplays": intentionallySwitchedDisplays.sorted().map { "d\($0)" }.joined(separator: ",")
        ])
    }
}
```

- [ ] **Step 3: 修改 step 6 — 用 intentionallySwitchedDisplays 集合替代单一 intentionallySwitchedDisplay**

文件: `Sources/Toggle/ToggleEngine.swift:412-445`

替换 step 6 的检测逻辑，用 `intentionallySwitchedDisplays` 集合判断哪些 display 的变化是故意的：

```swift
// 6. 检测并修复 CGEvent 意外切换其他 display 的问题
// CGEvent Ctrl+Arrow 可能影响非目标 display 的 space
// 使用 intentionallySwitchedDisplays 集合跟踪所有 restore 过程中被故意切换的 display
if restored, !preRestoreDisplaySpaces.isEmpty {
    var accidentalSwitches: [String] = []
    for (disp, preVis) in preRestoreDisplaySpaces {
        if intentionallySwitchedDisplays.contains(disp) { continue }
        let currentVis = spaceController.displayVisibleSpace(displayIndex: disp)
        if let cur = currentVis, cur != preVis {
            accidentalSwitches.append("d\(disp):s\(preVis)->s\(cur)")
            log("[ToggleEngine] restore: display \(disp) was accidentally switched from space \(preVis) to \(cur), fixing", level: .warn, fields: [
                "traceID": trace,
                "display": String(disp),
                "preRestoreSpace": String(preVis),
                "currentSpace": String(cur),
                "intentionallySwitchedDisplays": intentionallySwitchedDisplays.sorted().map { "d\($0)" }.joined(separator: ",")
            ])
            _ = spaceController.switchDisplayToSpace(
                targetSpace: preVis,
                operationID: trace
            )
        }
    }
    if accidentalSwitches.isEmpty {
        log("[ToggleEngine] restore: no accidental display switches detected", level: .debug, fields: [
            "traceID": trace,
            "intentionallySwitchedDisplays": intentionallySwitchedDisplays.sorted().map { "d\($0)" }.joined(separator: ",")
        ])
    } else {
        log("[ToggleEngine] restore: fixed accidental switches", fields: [
            "traceID": trace,
            "accidentalSwitches": accidentalSwitches.joined(separator: ",")
        ])
    }
}
```

- [ ] **Step 4: 在 switchToOriginalSpace 中也跟踪故意切换的 display**

文件: `Sources/Toggle/ToggleEngine.swift:487-601`

修改 `switchToOriginalSpace` 方法签名，增加 `intentionallySwitchedDisplays` 参数：

```swift
private func switchToOriginalSpace(
    record: ToggleRecord,
    windowAX: AXUIElement,
    effectiveWindowID: UInt32,
    triggerSource: String,
    traceID: String,
    intentionallySwitchedDisplays: inout Set<Int>
) {
```

在 `switchDisplayToSpace` 调用前后，记录被影响的 display：

```swift
// 记录切换前的 display states
var preSwitchSpaces: [Int: Int] = [:]
for d in 1...3 {
    if let v = spaceController.displayVisibleSpace(displayIndex: d) {
        preSwitchSpaces[d] = v
    }
}

let switched = spaceController.switchDisplayToSpace(
    targetSpace: targetSpace,
    operationID: traceID
)

if switched {
    // 标记被 switchDisplayToSpace 影响的 display
    for d in 1...3 {
        let postVis = spaceController.displayVisibleSpace(displayIndex: d)
        if let pre = preSwitchSpaces[d], let post = postVis, pre != post {
            intentionallySwitchedDisplays.insert(d)
        }
    }
    // ... 现有的 poll 逻辑保持不变
}
```

同时修改调用方（step 5 的 else 分支 line 401-410）：

```swift
} else if restored {
    switchToOriginalSpace(
        record: record,
        windowAX: windowAX,
        effectiveWindowID: effectiveWindowID,
        triggerSource: triggerSource,
        traceID: trace,
        intentionallySwitchedDisplays: &intentionallySwitchedDisplays
    )
}
```

- [ ] **Step 5: 验证编译通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 6: 质量门禁检查**
Run: `swift build 2>&1 | grep -iE "error:|warning:" | head -20`
Expected:
  - Exit code: 0
  - 无 error 输出

**手工检查（AI 自行验证）：**
- [ ] 无遗留 debug 语句
- [ ] 无 TODO/FIXME
- [ ] 无未使用的变量
- [ ] `intentionallySwitchedDisplays` 在所有 switchDisplayToSpace 调用点都被更新

- [ ] **Step 7: 提交**
Run: `git add Sources/Toggle/ToggleEngine.swift && git commit -m "$(cat <<'EOF'
fix(restore): use intentionallySwitchedDisplays set instead of single display in accidental switch detection

The previous logic only excluded sourceYabaiDisp from accidental switch
checks, but switchDisplayToSpace via CGEvent can affect multiple displays.
This caused the target display's intentional space switch to be detected
as "accidental" and reversed, breaking the restore result (window lands on
wrong space like 2-1 instead of 2-2).

Now tracks ALL displays that were intentionally switched during restore
by comparing display states before/after each switchDisplayToSpace call.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

### Task 2: 修复 RestoreWatchdog — correction 时先 setWindowFloat 再 apply frame

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Toggle/RestoreWatchdog.swift:137-192` (applyCorrection 方法)

- [ ] **Step 1: 修改 applyCorrection — 在 AX frame apply 之前先 setWindowFloat**

文件: `Sources/Toggle/RestoreWatchdog.swift:137-192`

当前 applyCorrection 的执行顺序是：setWindowFloat → AX apply → check space → moveWindow。

但问题在于：yabai 在窗口到达新 space 的瞬间会把浮动窗口重新 tile。所以 setWindowFloat 可能在 AX apply 之后被 yabai 覆盖。

修复方案：在 AX apply 之后再执行一次 setWindowFloat，确保窗口保持浮动状态。同时改进 space correction 逻辑：

```swift
private func applyCorrection() {
    guard let t = target else { return }
    guard correctionsApplied < maxCorrections else {
        log("[RestoreWatchdog] max corrections reached, stopping", level: .warn, fields: [
            "traceID": t.traceID,
            "windowID": String(t.windowID),
            "maxCorrections": String(maxCorrections)
        ])
        stopMonitoring(reason: "max_corrections_reached")
        return
    }

    correctionsApplied += 1
    log("[RestoreWatchdog] applying correction #\(correctionsApplied)", fields: [
        "traceID": t.traceID,
        "windowID": String(t.windowID)
    ])

    let spaceController = SpaceController.shared
    let wm = WindowManager.shared

    // 1. 先确保窗口是浮动状态
    spaceController.setWindowFloat(t.windowID, operationID: "watchdog_\(t.traceID)")

    // 2. 检查并修正 space 位置（必须在 AX apply 之前！）
    // 如果窗口在错误 space 上，AX apply 只会把 frame 设到当前 space 上
    if let info = spaceController.queryWindow(windowID: t.windowID) {
        if let space = info.space, space != t.targetSpace {
            log("[RestoreWatchdog] space mismatch, moving window to target space", level: .warn, fields: [
                "traceID": t.traceID,
                "currentSpace": String(space),
                "targetSpace": String(t.targetSpace),
                "correction": String(correctionsApplied)
            ])
            let moved = spaceController.moveWindow(
                t.windowID,
                toSpaceIndex: t.targetSpace,
                focus: false,
                operationID: "watchdog_\(t.traceID)"
            )
            log("[RestoreWatchdog] space move result", level: .debug, fields: [
                "traceID": t.traceID,
                "moved": String(moved),
                "correction": String(correctionsApplied)
            ])
            // moveWindow 后等窗口到达目标 space
            if moved {
                usleep(100_000)
            }
        }
    }

    // 3. AX frame apply
    if let windowAX = wm.findWindowByPID(t.pid, windowID: t.windowID) {
        let applyResult = wm.apply(frame: t.targetFrame, to: windowAX, operationID: "watchdog_\(t.traceID)", stage: "watchdog_correction")
        log("[RestoreWatchdog] correction #\(correctionsApplied) AX apply result", level: .debug, fields: [
            "traceID": t.traceID,
            "success": String(applyResult)
        ])
    } else {
        log("[RestoreWatchdog] correction #\(correctionsApplied): window AX not found", level: .warn, fields: [
            "traceID": t.traceID,
            "windowID": String(t.windowID)
        ])
    }

    // 4. AX apply 后再设一次 float（yabai 可能在 AX apply 后重新 tile 窗口）
    spaceController.setWindowFloat(t.windowID, operationID: "watchdog_\(t.traceID)")
}
```

- [ ] **Step 2: 增加 maxCorrections 到 5**

文件: `Sources/Toggle/RestoreWatchdog.swift:29`

当前 `maxCorrections = 3`，但 3 次往往不够（yabai 可能在每次 correction 后都重新 tile）。增加到 5：

```swift
private let maxCorrections = 5
```

- [ ] **Step 3: 验证编译通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 4: 质量门禁检查**
Run: `swift build 2>&1 | grep -iE "error:|warning:" | head -20`
Expected:
  - Exit code: 0
  - 无 error 输出

- [ ] **Step 5: 提交**
Run: `git add Sources/Toggle/RestoreWatchdog.swift && git commit -m "$(cat <<'EOF'
fix(watchdog): reorder correction to setWindowFloat → space move → AX apply → re-float

Previous order (setWindowFloat → AX apply → space move) was wrong:
yabai would re-tile the window after AX apply, making the float status
irrelevant. Also, space move should happen before AX apply because
applying a frame on the wrong space is pointless.

New order: setWindowFloat → space move → AX apply → setWindowFloat again.
Increased maxCorrections from 3 to 5 to handle yabai's persistent re-tiling.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

### Task 3: 构建、部署并验证

**Depends on:** Task 1, Task 2
**Files:**
- None (build + deploy + verification)

- [ ] **Step 1: 使用 dev-build.sh 构建签名应用**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && bash scripts/dev-build.sh 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output contains: "Build Succeeded" or "copy"

- [ ] **Step 2: 部署到 /Applications 并重启**
Run: `rm -rf /Applications/VibeFocus.app && cp -R /Users/cc11001100/github/vibe-coding-labs/vibe-focus/.build/release/VibeFocus.app /Applications/ && killall VibeFocus 2>/dev/null; sleep 1; open /Applications/VibeFocus.app`
Expected:
  - Exit code: 0
  - VibeFocus process starts

- [ ] **Step 3: 验证应用运行**
Run: `sleep 3 && ps aux | grep VibeFocus | grep -v grep | head -3`
Expected:
  - Exit code: 0
  - Output contains: VibeFocus process

- [ ] **Step 4: 提交所有剩余变更（如有）**
Run: `git status --short`
Expected:
  - No uncommitted changes (or only unrelated files)
