# Bug Fix: restore 到错误工作区 — switchDisplayToSpace 虚假成功

**Symptom:** 从主屏幕按 ⌃Q 还原窗口时，窗口回到副屏的 visible space（space 4），而非 toggle record 记录的原始 space（space 5）
**Root Cause:** `switchDisplayToSpace` CGEvent fallback 即使没切到目标 space 也返回 `true`，导致 ToggleEngine 以为 space 已切好就执行 AX apply
**Impact:** 当目标 space 不是当前 visible space 时，还原必然失败。watchdog 5 次修正也无法修复。
**Scope:** Small
**Risk:** Medium（修改核心 space 切换逻辑）

**Risks:**
- 修改 `switchDisplayToSpace` 返回值可能影响其他调用方（需要 grep 确认所有调用方）
- CGEvent 重试可能增加 restore 延迟

---

### Task 1: 修复 switchDisplayToSpace CGEvent fallback 虚假返回 true

**Depends on:** None
**Files:**
- Modify: `Sources/Space/SpaceController+Switch.swift:79-89`

- [ ] **Step 1: 修改 switchDisplayToSpace CGEvent fallback 使其验证 space 真正切换后返回 true**

文件: `Sources/Space/SpaceController+Switch.swift:79-89`（替换整个 `if success` 块）

当前代码（79-89）：
```swift
if success {
    usleep(30_000)
    let postSwitchSpace = displayVisibleSpace(displayIndex: querySpaces()?.first(where: { $0.index == targetSpace })?.display)
    log("[SpaceController] switchDisplayToSpace: CGEvent succeeded", fields: [
        "op": op,
        "targetSpace": String(targetSpace),
        "steps": String(steps),
        "postSwitchSpace": String(describing: postSwitchSpace),
        "reachedTarget": String(postSwitchSpace == targetSpace)
    ])
    return true
}
```

替换为：
```swift
if success {
    usleep(100_000) // 从 30ms 增加到 100ms，给 macOS 动画更多时间
    let postSwitchSpace = displayVisibleSpace(displayIndex: querySpaces()?.first(where: { $0.index == targetSpace })?.display)
    let reachedTarget = postSwitchSpace == targetSpace
    log("[SpaceController] switchDisplayToSpace: CGEvent result", fields: [
        "op": op,
        "targetSpace": String(targetSpace),
        "steps": String(steps),
        "postSwitchSpace": String(describing: postSwitchSpace),
        "reachedTarget": String(reachedTarget)
    ])

    if reachedTarget {
        return true
    }

    // 第一次没到目标 space，重试一次（增加 200ms 等待后再次发送 CGEvent）
    log("[SpaceController] switchDisplayToSpace: CGEvent didn't reach target, retrying with delay", level: .info, fields: [
        "op": op,
        "targetSpace": String(targetSpace),
        "postSwitchSpace": String(describing: postSwitchSpace)
    ])
    usleep(200_000) // 200ms 额外等待

    // 重新移鼠标到目标 display 并重新发送 CGEvent
    if let center = displayCenterCG(spaceIndex: targetSpace) {
        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                    mouseCursorPosition: center, mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
        }
        usleep(50_000)
        // 点击激活 display
        if let downClick = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                    mouseCursorPosition: center, mouseButton: .left) {
            downClick.post(tap: .cghidEventTap)
        }
        usleep(20_000)
        if let upClick = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                  mouseCursorPosition: center, mouseButton: .left) {
            upClick.post(tap: .cghidEventTap)
        }
        usleep(100_000) // 100ms 等待 display 激活

        // 重新计算 steps（可能 space 布局变了）
        let retrySteps = calculateFocusSteps(targetSpaceIndex: targetSpace)
        if retrySteps != 0 {
            let retrySuccess = NativeSpaceBridge.focusSpace(steps: retrySteps, operationID: op)
            if retrySuccess {
                usleep(100_000)
                let retryPostSpace = displayVisibleSpace(displayIndex: querySpaces()?.first(where: { $0.index == targetSpace })?.display)
                let retryReached = retryPostSpace == targetSpace
                log("[SpaceController] switchDisplayToSpace: CGEvent retry result", fields: [
                    "op": op,
                    "targetSpace": String(targetSpace),
                    "retrySteps": String(retrySteps),
                    "retryPostSpace": String(describing: retryPostSpace),
                    "retryReached": String(retryReached)
                ])
                if retryReached {
                    return true
                }
            }
        }
    }

    log("[SpaceController] switchDisplayToSpace: CGEvent failed to reach target after retry", level: .warn, fields: [
        "op": op,
        "targetSpace": String(targetSpace),
        "finalSpace": String(describing: postSwitchSpace)
    ])
    return false
}
```

- [ ] **Step 2: 验证所有 switchDisplayToSpace 调用方**

Run: `grep -rn "switchDisplayToSpace" Sources/`
Expected:
  - Exit code: 0
  - 列出所有调用方，确认没有调用方依赖 "CGEvent 发了就返回 true" 的行为
  - 调用方应该都能接受 `false` 返回值

- [ ] **Step 3: 质量门禁检查**

Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - 无编译错误

- [ ] **Step 4: 提交**

Run: `git add Sources/Space/SpaceController+Switch.swift && git commit -m "fix(space): switchDisplayToSpace returns false when CGEvent doesn't reach target space"`

---

### Task 2: ToggleEngine.restore — space switch 失败时先切 visible space 再 AX apply

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Toggle/ToggleEngine.swift:276-332`

- [ ] **Step 1: 修改 ToggleEngine.restore 的 space switch 失败处理**

文件: `Sources/Toggle/ToggleEngine.swift:276-332`（替换 space switch 块）

当前代码（276-332）：
```swift
if let current = displayCurrentSpace, current != targetSpace {
    // 记录切换前的 display states...
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

    // 检测哪些 display 的 space 被改变了...
    if switched {
        // ... poll for space switch ...
    }
    log("[ToggleEngine] restore: display switched to target space", fields: [...])
}
```

替换为：
```swift
if let current = displayCurrentSpace, current != targetSpace {
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
    } else {
        // space switch 失败 — 目标 space 不可达
        // 切换到目标 display 的 visible space，确保 AX apply 至少把窗口放到正确的显示器上
        // 窗口会落在 visible space，后续 moveWindow fallback 会尝试移到正确 space
        let visibleSpace = spaceController.displayVisibleSpace(displayIndex: targetDisplay)
        log("[ToggleEngine] restore: space switch failed, switching to visible space on target display", level: .warn, fields: [
            "traceID": trace,
            "targetSpace": String(targetSpace),
            "visibleSpace": String(describing: visibleSpace),
            "targetDisplay": String(targetDisplay)
        ])
        if let vis = visibleSpace, vis != current {
            let visSwitched = spaceController.switchDisplayToSpace(
                targetSpace: vis,
                operationID: trace
            )
            if visSwitched {
                intentionallySwitchedDisplays.insert(targetDisplay)
            }
            log("[ToggleEngine] restore: visible space switch result", fields: [
                "traceID": trace,
                "switched": String(visSwitched),
                "visibleSpace": String(vis)
            ])
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

- [ ] **Step 2: 质量门禁检查**

Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0

- [ ] **Step 3: 提交**

Run: `git add Sources/Toggle/ToggleEngine.swift && git commit -m "fix(restore): handle space switch failure by falling back to visible space"`

---

### Task 3: 部署并验证

**Depends on:** Task 2
**Files:**
- None（验证 task）

- [ ] **Step 1: 构建签名 app bundle**

Run: `./scripts/build-sign.sh 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - 输出包含 "Signed" 或 "Build succeeded"

- [ ] **Step 2: 部署到本地应用**

Run: `./scripts/deploy.sh 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - VibeFocus app 重启

- [ ] **Step 3: 手动验证 — 测试从非 visible space restore**

测试步骤：
1. 在副屏创建 2 个 space（如已有则跳过）
2. 切到副屏的第 2 个 space（非 visible 状态）
3. 打开 iTerm2 窗口
4. 按 ⌃Q 把 iTerm2 移到主屏
5. 按 ⌃Q 还原
6. 观察：窗口是否回到副屏的第 2 个 space（而非第 1 个 visible space）

验证点：
- 日志中 `switchDisplayToSpace: CGEvent result` 的 `reachedTarget` 值
- 如果 reachedTarget=false，日志中应出现 `CGEvent retry result` 或 `space switch failed, switching to visible space`
- 窗口至少回到了副屏（即使 space 不对），而非留在主屏

Run: `tail -200 ~/Library/Logs/VibeFocus/vibefocus.log | grep -E "reachedTarget|space switch failed|visible space switch"`
Expected:
  - 日志显示新的处理逻辑在工作
